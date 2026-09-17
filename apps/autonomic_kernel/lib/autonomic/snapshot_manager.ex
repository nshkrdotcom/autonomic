defmodule Autonomic.SnapshotManager do
  @moduledoc "Trusted checkpoint coordinator binding backend snapshot evidence to durable metadata."

  alias Autonomic.{Canonical, EpisodeCheckpoint, ExecutionDomain, Homeostat, Runtime}

  def capture(episode_id, %ExecutionDomain.Domain{} = domain, opts \\ []) do
    store = Runtime.store()

    with {:ok, episode} <- store.fetch_episode(episode_id),
         %Autonomic.HomeostaticState{} = homeostat <- Homeostat.snapshot(episode_id),
         {:ok, backend_ref} <- domain.backend.checkpoint(domain),
         true <- backend_ref.episode_id == episode_id and backend_ref.epoch == domain.epoch,
         {:ok, effects} <- list_pending(store, episode_id) do
      checkpoint = %EpisodeCheckpoint{
        id: Canonical.id(),
        episode_id: episode_id,
        epoch: episode.current_epoch,
        domain_generation: domain.generation,
        filesystem_ref: backend_ref.ref,
        filesystem_digest: backend_ref.digest,
        git_base_ref: Keyword.get(opts, :git_base_ref) || workspace_base(domain),
        git_patch_digest: Keyword.get(opts, :git_patch_digest),
        trajectory_version: homeostat.trajectory_version,
        trajectory_ref: "trajectory:#{episode_id}:#{homeostat.trajectory_version}",
        policy_version: episode.policy_version,
        capability_state_ref: Keyword.get(opts, :capability_state_ref),
        environment_digest:
          Map.get(backend_ref.metadata, :environment_digest) ||
            Map.get(backend_ref.metadata, "environment_digest"),
        dependency_lock_digest: Keyword.get(opts, :dependency_lock_digest),
        parent_checkpoint_id: episode.current_checkpoint_id,
        trust_level: Keyword.get(opts, :trust_level, :stable),
        created_at: Canonical.now(),
        pending_effect_ids: Enum.map(effects, & &1.id),
        metadata:
          Map.merge(
            %{reason: Keyword.get(opts, :reason, :periodic), backend: inspect(domain.backend)},
            backend_ref.metadata
          )
      }

      store.put_checkpoint(checkpoint)
    else
      false -> {:error, :backend_checkpoint_identity_mismatch}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  def restore(%EpisodeCheckpoint{} = checkpoint) do
    ref = %ExecutionDomain.CheckpointRef{
      ref: checkpoint.filesystem_ref,
      episode_id: checkpoint.episode_id,
      epoch: checkpoint.epoch,
      domain_generation: checkpoint.domain_generation,
      digest: checkpoint.filesystem_digest,
      metadata: checkpoint.metadata || %{}
    }

    Runtime.domain().restore(ref)
  end

  def latest_stable(episode_id), do: Runtime.store().latest_stable_checkpoint(episode_id)

  defp list_pending(store, episode_id) do
    if function_exported?(store, :list_effects, 2),
      do: store.list_effects(episode_id, [:proposed, :prepared, :evaluating, :ready]),
      else: {:ok, []}
  end

  defp workspace_base(domain) do
    Map.get(domain.metadata, :git_base_ref) || Map.get(domain.metadata, "git_base_ref")
  end
end
