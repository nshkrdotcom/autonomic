defmodule Autonomic.Dev.MemoryAdapter do
  @moduledoc "Example-only adapter with explicit success/unknown/reconciliation modes."
  @behaviour Autonomic.EffectAdapter

  alias Autonomic.Dev.TargetStore

  @impl true
  def validate(effect, opts) do
    target = Keyword.fetch!(opts, :trusted_target)
    expected_id = Map.get(target, "id") || Map.get(target, :id)
    public_id = Map.get(effect.target, "id") || Map.get(effect.target, :id)
    if is_nil(expected_id) or expected_id == public_id, do: :ok, else: {:error, :target_scope_mismatch}
  end

  @impl true
  def commit(effect, opts) do
    target = Keyword.fetch!(opts, :trusted_target)
    key = key(effect, target)
    mode = Map.get(target, "mode", "success")

    case mode do
      "unknown_after_write" ->
        TargetStore.put(key, effect.payload_digest)
        {:unknown, :ack_lost_after_target_mutation}

      "unknown_without_evidence" ->
        {:unknown, :transport_ambiguous}

      "error_after_write" ->
        TargetStore.put(key, effect.payload_digest)
        {:error, :simulated_disconnect}

      _ ->
        case TargetStore.get(key) do
          nil ->
            TargetStore.put(key, effect.payload_digest)
            {:ok, receipt(effect, key, :created)}

          digest when digest == effect.payload_digest ->
            {:ok, receipt(effect, key, :idempotent_replay)}

          _ ->
            {:error, :conditional_write_conflict}
        end
    end
  end

  @impl true
  def reconcile(effect, opts) do
    target = Keyword.fetch!(opts, :trusted_target)
    key = key(effect, target)

    case TargetStore.get(key) do
      digest when digest == effect.payload_digest -> {:committed, receipt(effect, key, :reconciled)}
      nil -> if(Map.get(target, "reconcile_unknown", false), do: {:unknown, :authoritative_evidence_unavailable}, else: :not_committed)
      _ -> {:unknown, :target_contains_different_revision}
    end
  end

  defp key(effect, target), do: {Map.get(effect.target, "id"), Map.get(target, "object_key", effect.id)}
  defp receipt(effect, key, mode), do: %{receipt_ref: "memory:#{effect.id}", key: inspect(key), payload_digest: effect.payload_digest, mode: mode}
end
