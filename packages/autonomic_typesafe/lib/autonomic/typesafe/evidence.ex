defmodule Autonomic.Typesafe.Evidence do
  @moduledoc "Redacts and bounds observable semantic state before crossing the SDK boundary."

  alias Autonomic.Canonical

  @secret_keys ~w(api_key token password secret authorization cookie private_key access_key credential credentials)
  @secret_patterns [
    ~r/(?i)bearer\s+[A-Za-z0-9._~+\/-]{8,}/,
    ~r/(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  def bounded(frame, limit) when is_integer(limit) and limit >= 1_024 do
    observable = %{
      "episode_id" => frame.episode_id,
      "epoch" => frame.epoch,
      "sequence" => frame.sequence,
      "observed_at" => frame.observed_at,
      "deterministic" => sanitize(frame.deterministic, 0),
      "resource" => sanitize(frame.resource, 0),
      "effect_context" => sanitize(frame.effect_context, 0),
      "visible_state" =>
        sanitize(
          Map.get(frame.metadata, :observable, Map.get(frame.metadata, "observable", %{})),
          0
        )
    }

    encoded = Jason.encode!(observable)

    if byte_size(encoded) <= limit do
      {:ok, observable,
       %{
         truncated: false,
         original_bytes: byte_size(encoded),
         sent_bytes: byte_size(encoded),
         digest: Canonical.hash(encoded)
       }}
    else
      compact = %{
        "episode_id" => frame.episode_id,
        "epoch" => frame.epoch,
        "sequence" => frame.sequence,
        "deterministic" => observable["deterministic"] |> List.wrap() |> Enum.take(32),
        "resource" => observable["resource"],
        "effect_context" => shrink(observable["effect_context"], 4_096),
        "visible_state" => shrink(observable["visible_state"], max(1_024, limit - 12_000)),
        "truncated" => true,
        "full_redacted_digest" => Canonical.hash(encoded)
      }

      final = Jason.encode!(compact)

      if byte_size(final) <= limit,
        do:
          {:ok, compact,
           %{
             truncated: true,
             original_bytes: byte_size(encoded),
             sent_bytes: byte_size(final),
             digest: Canonical.hash(final)
           }},
        else: {:error, :semantic_state_budget_exceeded}
    end
  end

  defp sanitize(nil, _depth), do: nil
  defp sanitize(value, _depth) when is_boolean(value) or is_number(value), do: value
  defp sanitize(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value, _depth) when is_binary(value), do: redact(value) |> String.slice(0, 16_384)
  defp sanitize(_value, depth) when depth >= 8, do: "[depth-truncated]"

  defp sanitize(value, depth) when is_list(value),
    do: value |> Enum.take(128) |> Enum.map(&sanitize(&1, depth + 1))

  defp sanitize(value, depth) when is_map(value) do
    value
    |> Enum.take(128)
    |> Map.new(fn {key, item} ->
      key = to_string(key)
      if secret_key?(key), do: {key, "[REDACTED]"}, else: {key, sanitize(item, depth + 1)}
    end)
  end

  defp sanitize(value, _depth), do: inspect(value, limit: 10, printable_limit: 512)

  defp redact(text) do
    Enum.reduce(@secret_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  defp secret_key?(key) do
    key = String.downcase(key)
    Enum.any?(@secret_keys, &(key == &1 or String.contains?(key, &1)))
  end

  defp shrink(nil, _), do: nil

  defp shrink(value, max_bytes) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) <= max_bytes,
      do: value,
      else: %{
        "truncated_json" => String.slice(encoded, 0, max_bytes),
        "digest" => Canonical.hash(encoded)
      }
  end
end
