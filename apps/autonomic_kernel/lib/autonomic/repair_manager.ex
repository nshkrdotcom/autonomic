defmodule Autonomic.RepairManager do
  @moduledoc "Epoch-fenced rollback and reconstruction from trusted checkpoint/evidence."

  alias Autonomic.{AuthorityGovernor, Canonical, Homeostat, Runtime, SnapshotManager}

  def repair(episode_id, old_domain, spec, reason, evidence \\ %{}) do
    store = Runtime.store()
    from_epoch = old_domain.epoch

    with {:ok, to_epoch} <- AuthorityGovernor.advance_epoch(episode_id, reason),
         :ok <- destroy_proven(old_domain),
         {:ok, checkpoint} <- SnapshotManager.latest_stable(episode_id),
         {:ok, new_domain} <- SnapshotManager.restore(checkpoint),
         true <- new_domain.epoch == to_epoch,
         :ok <- Homeostat.rebase_epoch(episode_id, to_epoch),
         {:ok, lease} <- issue_repair_lease(episode_id, spec, reason),
         context <- repair_context(reason, evidence),
         {:ok, recovery_id} <-
           record_recovery(
             store,
             episode_id,
             {from_epoch, to_epoch},
             checkpoint,
             old_domain,
             new_domain,
             reason,
             context
           ) do
      Homeostat.repair_recorded(episode_id)

      {:ok,
       %{
         domain: new_domain,
         lease: lease,
         checkpoint: checkpoint,
         context: context,
         recovery_id: recovery_id
       }}
    else
      false -> {:error, :restore_epoch_mismatch}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  def repair_context(reason, evidence) do
    facts =
      evidence
      |> Map.get(:deterministic, Map.get(evidence, "deterministic", []))
      |> Enum.take(8)
      |> Enum.map(&safe_fact/1)

    %{
      instruction:
        "Continue from the last stable checkpoint within the original task and hard envelope.",
      boundary_reason: to_string(reason),
      concrete_violations: facts,
      constraints: [
        "Do not access host secrets.",
        "Do not use direct network access.",
        "Do not broaden scope or authority."
      ],
      scratchpad_replayed: false
    }
  end

  defp destroy_proven(domain) do
    case domain.backend.destroy(domain) do
      :ok ->
        :ok

      {:ok, evidence} ->
        if Map.get(evidence, :empty, Map.get(evidence, "empty", false)),
          do: :ok,
          else: {:error, :old_domain_not_proven_empty}

      {:error, _} = error ->
        error

      other ->
        {:error, {:invalid_destroy_result, other}}
    end
  end

  defp issue_repair_lease(episode_id, spec, reason) do
    capabilities = repair_capabilities(spec.hard_envelope)
    max_class = spec.requested_effect_ceiling || :class_1_isolated_mutable

    AuthorityGovernor.issue(episode_id, %{
      authority_source: :signed_policy,
      capabilities: capabilities,
      max_effect_class: max_class,
      ttl_ms: 30_000,
      reason: "repair after #{reason}",
      metadata: %{repair: true}
    })
  end

  defp repair_capabilities(envelope) do
    Map.get(envelope, "capabilities", Map.get(envelope, :capabilities, []))
    |> Enum.filter(fn cap ->
      kind = if is_map(cap), do: Map.get(cap, :kind, Map.get(cap, "kind")), else: nil
      kind not in [:network, :publish, :http_mutation, "network", "publish", "http_mutation"]
    end)
    |> Enum.map(&Autonomic.AuthorityGovernor.normalize_capability/1)
  end

  defp record_recovery(
         store,
         episode_id,
         {from_epoch, to_epoch},
         checkpoint,
         old_domain,
         new_domain,
         reason,
         context
       ) do
    store.record_recovery(%{
      episode_id: episode_id,
      from_epoch: from_epoch,
      to_epoch: to_epoch,
      checkpoint_id: checkpoint.id,
      old_domain_ref: old_domain.id,
      new_domain_ref: new_domain.id,
      reason: to_string(reason),
      evidence_ref: "sha256:#{Canonical.digest(context)}",
      metadata: %{repair_context_digest: Canonical.digest(context)}
    })
  end

  defp safe_fact(fact) when is_map(fact) do
    fact
    |> Map.drop([:secret, :value, :contents, "secret", "value", "contents"])
    |> Enum.take(8)
    |> Map.new()
  end

  defp safe_fact(other),
    do: %{type: :opaque_violation, value: inspect(other, limit: 10, printable_limit: 256)}
end
