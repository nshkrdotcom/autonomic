defmodule Autonomic.Dev.StoreCase do
  @moduledoc "Small runnable conformance probe for store implementations used by examples."

  alias Autonomic.{Canonical, CapabilityLease, ProposedEffect, VersionVector}
  alias Autonomic.Dev.Support

  def verify_epoch_fencing!(store, episode_id) do
    {:ok, epoch1} = store.current_epoch(episode_id)
    now = Canonical.now()

    lease = %CapabilityLease{
      id: Canonical.id(),
      episode_id: episode_id,
      epoch: epoch1,
      policy_version: 1,
      capabilities: [],
      max_effect_class: :class_2_external_observable_or_compensatable,
      issued_at: now,
      expires_at: now + 60_000,
      authority_source: :signed_policy
    }

    :ok = store.put_lease(lease)

    effect = %ProposedEffect{
      id: Canonical.id(),
      episode_id: episode_id,
      epoch: epoch1,
      lease_id: lease.id,
      class: :class_2_external_observable_or_compensatable,
      kind: :http_read,
      target: %{"id" => "demo"},
      payload_ref: "sha256:example",
      payload_digest: String.duplicate("a", 64),
      revision: 1,
      reversible?: true,
      state: :prepared,
      version_vector: %VersionVector{
        episode_id: episode_id,
        epoch: epoch1,
        policy_version: 1,
        snapshot_ancestry: [],
        trajectory_version: 0,
        trajectory_regime: :stable,
        lease_id: lease.id,
        effect_revision: 1
      },
      created_at: now
    }

    :ok = store.put_effect(effect)
    {:ok, epoch2} = store.advance_epoch(episode_id, %{reason: :conformance})
    Support.assert_equal!(epoch2, epoch1 + 1, "epoch must advance monotonically")
    {:ok, old_lease} = store.fetch_lease(lease.id)
    {:ok, old_effect} = store.fetch_effect(effect.id)

    Support.assert!(
      not is_nil(old_lease.revoked_at),
      "old lease must be revoked by epoch advance"
    )

    Support.assert_equal!(old_effect.state, :stale, "old prepared effect must become stale")
    :ok
  end
end
