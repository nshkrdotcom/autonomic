defmodule Autonomic.Store.Schema.Episode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "episodes" do
    field(:state, :string)
    field(:current_epoch, :integer)
    field(:policy_id, :string)
    field(:policy_version, :integer)
    field(:policy_digest, :string)
    field(:policy, :map)
    field(:hard_envelope, :map)
    field(:origin_intent_digest, :string)
    field(:current_checkpoint_id, :string)
    field(:domain_ref, :string)
    field(:domain_generation, :integer)
    field(:domain_os_ref, :string)
    field(:domain_metadata, :map, default: %{})
    field(:trajectory_version, :integer)
    field(:trajectory_regime, :string)
    field(:trajectory_state, :map)
    field(:owner_node, :string)
    field(:owner_lease_token, :string)
    field(:owner_lease_expires_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :state,
      :current_epoch,
      :policy_id,
      :policy_version,
      :policy_digest,
      :policy,
      :hard_envelope,
      :origin_intent_digest,
      :current_checkpoint_id,
      :domain_ref,
      :domain_generation,
      :domain_os_ref,
      :domain_metadata,
      :trajectory_version,
      :trajectory_regime,
      :trajectory_state,
      :owner_node,
      :owner_lease_token,
      :owner_lease_expires_at,
      :metadata
    ])
    |> validate_required([
      :id,
      :state,
      :current_epoch,
      :policy_version,
      :policy_digest,
      :policy,
      :hard_envelope,
      :trajectory_version,
      :trajectory_regime
    ])
    |> validate_number(:current_epoch, greater_than_or_equal_to: 1)
    |> validate_number(:trajectory_version, greater_than_or_equal_to: 0)
  end
end

defmodule Autonomic.Store.Schema.CapabilityLease do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "capability_leases" do
    field(:episode_id, :string)
    field(:epoch, :integer)
    field(:policy_version, :integer)
    field(:capabilities, {:array, :map})
    field(:max_effect_class, :string)
    field(:issued_at_ms, :integer)
    field(:expires_at_ms, :integer)
    field(:revoked_at_ms, :integer)
    field(:authority_source, :string)
    field(:authority_ref, :string)
    field(:reason, :string)
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :episode_id,
      :epoch,
      :policy_version,
      :capabilities,
      :max_effect_class,
      :issued_at_ms,
      :expires_at_ms,
      :revoked_at_ms,
      :authority_source,
      :authority_ref,
      :reason,
      :metadata
    ])
    |> validate_required([
      :id,
      :episode_id,
      :epoch,
      :policy_version,
      :capabilities,
      :max_effect_class,
      :issued_at_ms,
      :expires_at_ms,
      :authority_source
    ])
  end
end

defmodule Autonomic.Store.Schema.Checkpoint do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "checkpoints" do
    field(:episode_id, :string)
    field(:epoch, :integer)
    field(:domain_generation, :integer)
    field(:parent_checkpoint_id, :string)
    field(:filesystem_ref, :string)
    field(:filesystem_digest, :string)
    field(:git_base_ref, :string)
    field(:git_patch_digest, :string)
    field(:trajectory_version, :integer)
    field(:trajectory_ref, :string)
    field(:policy_version, :integer)
    field(:capability_state_ref, :string)
    field(:environment_digest, :string)
    field(:dependency_lock_digest, :string)
    field(:trust_level, :string)
    field(:created_at_ms, :integer)
    field(:pending_effect_ids, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :episode_id,
      :epoch,
      :domain_generation,
      :parent_checkpoint_id,
      :filesystem_ref,
      :filesystem_digest,
      :git_base_ref,
      :git_patch_digest,
      :trajectory_version,
      :trajectory_ref,
      :policy_version,
      :capability_state_ref,
      :environment_digest,
      :dependency_lock_digest,
      :trust_level,
      :created_at_ms,
      :pending_effect_ids,
      :metadata
    ])
    |> validate_required([
      :id,
      :episode_id,
      :epoch,
      :domain_generation,
      :filesystem_ref,
      :filesystem_digest,
      :trajectory_version,
      :policy_version,
      :created_at_ms
    ])
  end
end

defmodule Autonomic.Store.Schema.Effect do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "effects" do
    field(:episode_id, :string)
    field(:epoch, :integer)
    field(:lease_id, :string)
    field(:revision, :integer)
    field(:class, :string)
    field(:kind, :string)
    field(:target, :map)
    field(:payload_ref, :string)
    field(:payload_digest, :string)
    field(:reversible, :boolean)
    field(:state, :string)
    field(:version_vector, :map)
    field(:idempotency_key, :string)
    field(:commit_attempt_id, :string)
    field(:version_vector_at_commit, :map)
    field(:commit_started_at_ms, :integer)
    field(:expires_at_ms, :integer)
    field(:committed_at_ms, :integer)
    field(:external_receipt_ref, :string)
    field(:external_receipt, :map)
    field(:failure, :map)
    field(:created_at_ms, :integer)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :episode_id,
      :epoch,
      :lease_id,
      :revision,
      :class,
      :kind,
      :target,
      :payload_ref,
      :payload_digest,
      :reversible,
      :state,
      :version_vector,
      :idempotency_key,
      :commit_attempt_id,
      :version_vector_at_commit,
      :commit_started_at_ms,
      :expires_at_ms,
      :committed_at_ms,
      :external_receipt_ref,
      :external_receipt,
      :failure,
      :created_at_ms,
      :metadata
    ])
    |> validate_required([
      :id,
      :episode_id,
      :epoch,
      :lease_id,
      :revision,
      :class,
      :kind,
      :target,
      :payload_ref,
      :payload_digest,
      :reversible,
      :state,
      :version_vector,
      :created_at_ms
    ])
    |> unique_constraint([:episode_id, :id])
  end
end

defmodule Autonomic.Store.Schema.EffectDecision do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "effect_decisions" do
    field(:effect_id, :string)
    field(:effect_revision, :integer)
    field(:kind, :string)
    field(:decision, :string)
    field(:source_ref, :string)
    field(:episode_id, :string)
    field(:epoch, :integer)
    field(:policy_version, :integer)
    field(:trajectory_version, :integer)
    field(:snapshot_ref, :string)
    field(:expires_at_ms, :integer)
    field(:payload_digest, :string)
    field(:evidence_ref, :string)
    field(:signature, :map)
    field(:created_at_ms, :integer)
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :effect_id,
      :effect_revision,
      :kind,
      :decision,
      :source_ref,
      :episode_id,
      :epoch,
      :policy_version,
      :trajectory_version,
      :snapshot_ref,
      :expires_at_ms,
      :payload_digest,
      :evidence_ref,
      :signature,
      :created_at_ms,
      :metadata
    ])
    |> validate_required([
      :id,
      :effect_id,
      :effect_revision,
      :kind,
      :decision,
      :source_ref,
      :episode_id,
      :epoch,
      :policy_version,
      :trajectory_version,
      :payload_digest,
      :created_at_ms
    ])
    |> unique_constraint([:effect_id, :effect_revision, :kind, :source_ref])
  end
end

defmodule Autonomic.Store.Schema.EpisodeEvent do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "episode_events" do
    field(:episode_id, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:payload, :map)
    field(:previous_hash, :string)
    field(:entry_hash, :string)
    field(:created_at_ms, :integer)
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :episode_id,
      :sequence,
      :kind,
      :payload,
      :previous_hash,
      :entry_hash,
      :created_at_ms
    ])
    |> validate_required([:episode_id, :sequence, :kind, :payload, :entry_hash, :created_at_ms])
    |> unique_constraint([:episode_id, :sequence])
  end
end

defmodule Autonomic.Store.Schema.ObservationFrame do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "observation_frames" do
    field(:episode_id, :string)
    field(:epoch, :integer)
    field(:sequence, :integer)
    field(:observed_at_ms, :integer)
    field(:deterministic, {:array, :map}, default: [])
    field(:semantic, {:array, :map}, default: [])
    field(:resource, :map, default: %{})
    field(:effect_context, :map)
    field(:dropped_low_priority_count, :integer, default: 0)
    field(:evidence_digest, :string)
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :episode_id,
      :epoch,
      :sequence,
      :observed_at_ms,
      :deterministic,
      :semantic,
      :resource,
      :effect_context,
      :dropped_low_priority_count,
      :evidence_digest,
      :metadata
    ])
    |> validate_required([:episode_id, :epoch, :sequence, :observed_at_ms, :evidence_digest])
    |> unique_constraint([:episode_id, :epoch, :sequence])
  end
end

defmodule Autonomic.Store.Schema.RecoveryRecord do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "recovery_records" do
    field(:episode_id, :string)
    field(:from_epoch, :integer)
    field(:to_epoch, :integer)
    field(:checkpoint_id, :string)
    field(:old_domain_ref, :string)
    field(:new_domain_ref, :string)
    field(:reason, :string)
    field(:evidence_ref, :string)
    field(:created_at_ms, :integer)
    field(:metadata, :map, default: %{})
    timestamps(updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :episode_id,
      :from_epoch,
      :to_epoch,
      :checkpoint_id,
      :old_domain_ref,
      :new_domain_ref,
      :reason,
      :evidence_ref,
      :created_at_ms,
      :metadata
    ])
    |> validate_required([:id, :episode_id, :from_epoch, :to_epoch, :reason, :created_at_ms])
  end
end
