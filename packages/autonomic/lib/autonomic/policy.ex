defmodule Autonomic.Policy do
  @moduledoc "Deterministic policy verification and a deny-dominant precedence lattice."

  alias Autonomic.{Canonical, EffectState}

  @precedence [
    "kernel_denial",
    "capability_violation",
    "deterministic_invariant",
    "signed_policy",
    "human",
    "semantic"
  ]

  def sign(document, key_id, private, domain) do
    %{
      "document" => document,
      "key_id" => key_id,
      "signature" =>
        Base.encode64(
          :crypto.sign(:eddsa, :none, signing_bytes(domain, document), [private, :ed25519])
        )
    }
  end

  def verify(%{"document" => doc, "key_id" => id, "signature" => signature}, keys, domain) do
    with {:ok, encoded} <- Map.fetch(keys, id),
         {:ok, public} <- Base.decode64(encoded),
         {:ok, signature} <- Base.decode64(signature),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             signing_bytes(domain, doc),
             signature,
             [public, :ed25519]
           ) do
      {:ok, doc}
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  def verify(_, _, _), do: {:error, :invalid_signature}

  def precedence(observations) when is_list(observations) do
    case Enum.find(@precedence, fn source ->
           denied_by?(observations, source)
         end) do
      nil -> :no_denial
      source -> {:deny, source}
    end
  end

  defp denied_by?(observations, source) do
    Enum.any?(observations, fn observation ->
      Map.get(observation, "source") == source and Map.get(observation, "decision") == "deny"
    end)
  end

  def contraction?(old, new, old_class, new_class) do
    class_rank(new_class) <= class_rank(old_class) and Enum.all?(new, &(&1 in old))
  end

  def permits?(policy, kind, target, class) when is_map(policy) do
    requested_rank = class_rank(class)
    max_rank = class_rank(Map.fetch!(policy, "max_effect_class"))

    requested_rank <= max_rank and
      Enum.any?(Map.fetch!(policy, "capabilities"), fn capability ->
        capability["kind"] == to_string(kind) and
          scope_matches?(capability["scope"], target) and
          requested_rank <= class_rank(Map.get(capability, "max_class", max_rank))
      end)
  end

  def required_decisions(policy, class) do
    rank = class_rank(class)

    floor =
      case rank do
        n when n <= 1 -> ["deterministic"]
        2 -> ["deterministic"]
        3 -> ["deterministic", "semantic", "slow_verifier"]
        4 -> ["deterministic", "semantic", "slow_verifier", "human"]
      end

    configured = get_in(policy, ["required_decisions", Integer.to_string(rank)]) || []
    Enum.uniq(floor ++ configured)
  end

  def class_rank(value) when is_integer(value) and value in 0..4, do: value

  def class_rank(value) when is_atom(value) do
    case EffectState.rank(value) do
      nil -> raise ArgumentError, "unknown effect class: #{inspect(value)}"
      rank -> rank
    end
  end

  def class_rank(value) when is_binary(value) do
    case Integer.parse(value) do
      {rank, ""} when rank in 0..4 ->
        rank

      _ ->
        value
        |> String.to_existing_atom()
        |> class_rank()
    end
  rescue
    ArgumentError ->
      reraise ArgumentError, [message: "unknown effect class: #{inspect(value)}"], __STACKTRACE__
  end

  def trusted_sign(document, role) do
    signer = Application.fetch_env!(:autonomic, :signer)

    private =
      signer
      |> Map.fetch!("private_key_file")
      |> File.read!()
      |> String.trim()
      |> Base.decode64!()

    sign(document, Map.fetch!(signer, "key_id"), private, "decision." <> role)
  end

  defp signing_bytes(domain, document),
    do: "autonomic." <> domain <> ".v1\n" <> Canonical.json(document)

  defp scope_matches?(scope, target) when is_map(scope) and is_map(target) do
    Enum.all?(scope, fn {key, value} ->
      Map.get(target, key) == value or Map.get(target, to_string(key)) == value
    end)
  end

  defp scope_matches?(scope, target), do: scope == target
end
