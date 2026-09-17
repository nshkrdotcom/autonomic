defmodule Autonomic.Adapters.HTTP do
  @moduledoc "Trusted broker-owned HTTP adapter with strict allowlists, TLS, body limits, and credential injection."
  @behaviour Autonomic.EffectAdapter

  alias Autonomic.{Payloads, RateLimiter}

  @impl true
  def validate(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         {:ok, uri, method} <- resolved_request(effect, target),
         true <- uri.scheme == "https" or Map.get(target, "allow_http", false),
         true <- is_nil(uri.userinfo),
         true <- uri.host == Map.fetch!(target, "host"),
         true <- String.starts_with?(uri.path || "/", Map.get(target, "path_prefix", "/")),
         true <- method in Enum.map(Map.get(target, "methods", ["GET"]), &String.upcase/1) do
      :ok
    else
      false -> {:error, :http_target_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_http_target}
    end
  end

  @impl true
  def commit(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         :ok <- validate(effect, opts),
         {:ok, uri, method} <- resolved_request(effect, target),
         :ok <- rate_limit(effect, target),
         {:ok, body} <- request_body(effect, method, target),
         {:ok, headers} <- headers(effect, target),
         request <- request_tuple(uri, method, headers, body),
         {:ok, response} <- request(effect, method, request, target) do
      {:ok, response}
    else
      {:error, {:transport, reason}} -> {:unknown, reason}
      {:error, _} = error -> error
    end
  end

  @impl true
  def reconcile(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         url when is_binary(url) <- Map.get(target, "reconcile_url"),
         uri <- URI.parse(url),
         true <- uri.scheme == "https" or Map.get(target, "allow_http", false),
         true <- is_nil(uri.userinfo),
         true <- uri.host == Map.get(target, "host"),
         true <- String.starts_with?(uri.path || "/", Map.get(target, "path_prefix", "/")),
         {:ok, headers} <- headers(effect, target),
         {:ok, {{_, status, _}, _response_headers, body}} <- :httpc.request(:get, {String.to_charlist(url), headers}, http_options(target), body_format: :binary) do
      cond do
        status in 200..299 and String.contains?(body, effect.idempotency_key || effect.id) -> {:committed, %{status: status, reconciliation: true}}
        status == 404 -> :not_committed
        true -> {:unknown, {:reconcile_status, status}}
      end
    else
      _ -> {:unknown, :target_has_no_reconciliation_contract}
    end
  end

  defp resolved_request(effect, target) do
    base = Map.fetch!(target, "base_url")
    path = Map.get(effect.target, "path", "/")
    method = String.upcase(to_string(Map.get(effect.target, "method", if(effect.kind == :http_read, do: "GET", else: "POST"))))
    uri = URI.merge(base, path)
    {:ok, uri, method}
  rescue
    error -> {:error, {:invalid_url, error}}
  end

  defp request_body(_effect, method, _target) when method in ["GET", "HEAD", "DELETE"], do: {:ok, ""}
  defp request_body(effect, _method, target) do
    with {:ok, body} <- Payloads.get(effect.episode_id, effect.payload_ref),
         true <- byte_size(body) <= Map.get(target, "max_body_bytes", 1_048_576) do
      {:ok, body}
    else
      false -> {:error, :http_body_too_large}
      error -> error
    end
  end

  defp headers(effect, target) do
    base = [{~c"accept", ~c"application/json"}]

    base =
      if effect.class in [:class_3_authoritative_external_mutation, :class_4_irreversible_high_impact],
        do: [{~c"idempotency-key", String.to_charlist(effect.idempotency_key || effect.id)} | base],
        else: base

    case Map.get(target, "credential_env") do
      nil -> {:ok, base}
      env ->
        case System.get_env(env) do
          nil -> if(Map.get(target, "credential_required", true), do: {:error, :trusted_credential_unavailable}, else: {:ok, base})
          value -> {:ok, [{~c"authorization", String.to_charlist("Bearer " <> value)} | base]}
        end
    end
  end

  defp request_tuple(uri, method, headers, body) do
    url = uri |> URI.to_string() |> String.to_charlist()
    if method in ["GET", "HEAD", "DELETE"], do: {url, headers}, else: {url, headers, ~c"application/octet-stream", body}
  end

  defp request(effect, method, request, target) do
    :inets.start()
    :ssl.start()
    with {:ok, atom} <- http_method(method) do
      case :httpc.request(atom, request, http_options(target), body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, body}} when status in 200..299 ->
        max = Map.get(target, "max_response_bytes", 1_048_576)
        if byte_size(body) <= max do
          digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

          with {:ok, response_ref} <- Payloads.put(effect.episode_id, body, max) do
            {:ok, %{status: status, headers: safe_headers(response_headers), body_digest: digest, body_bytes: byte_size(body), response_ref: response_ref, receipt_ref: response_ref}}
          end
        else
          {:error, :http_response_too_large}
        end
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:http_status, status, %{body_digest: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower), body_bytes: byte_size(body)}}}
        {:error, reason} -> {:error, {:transport, reason}}
      end
    end
  end

  defp http_method("GET"), do: {:ok, :get}
  defp http_method("HEAD"), do: {:ok, :head}
  defp http_method("DELETE"), do: {:ok, :delete}
  defp http_method("POST"), do: {:ok, :post}
  defp http_method("PUT"), do: {:ok, :put}
  defp http_method("PATCH"), do: {:ok, :patch}
  defp http_method("OPTIONS"), do: {:ok, :options}
  defp http_method(_), do: {:error, :unsupported_http_method}

  defp rate_limit(effect, target) do
    limit = Map.get(target, "rate_limit", 60)
    window_ms = Map.get(target, "rate_window_ms", 60_000)
    target_id = Map.get(effect.target, "id", Map.get(effect.target, :id, "http"))
    RateLimiter.check({:http, target_id}, limit, window_ms)
  end

  defp http_options(target) do
    [
      timeout: Map.get(target, "timeout_ms", 10_000),
      connect_timeout: Map.get(target, "connect_timeout_ms", 5_000),
      autoredirect: false,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
    ]
  end

  defp safe_headers(headers) do
    headers
    |> Enum.reject(fn {name, _} -> String.downcase(to_string(name)) in ["authorization", "set-cookie", "cookie"] end)
    |> Enum.take(64)
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value) |> String.slice(0, 512)} end)
  end

  defp trusted_target(opts) do
    case Keyword.get(opts, :trusted_target) do
      target when is_map(target) -> {:ok, target}
      _ -> {:error, :trusted_target_required}
    end
  end
end
