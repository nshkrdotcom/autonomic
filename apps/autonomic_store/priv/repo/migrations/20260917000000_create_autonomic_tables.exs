defmodule Autonomic.Store.Repo.Migrations.CreateAutonomicTables do
  use Ecto.Migration

  def change do
    create table(:episodes, primary_key: false) do
      add :id, :string, primary_key: true
      add :state, :string, null: false
      add :current_epoch, :bigint, null: false
      add :policy_id, :string
      add :policy_version, :bigint, null: false
      add :policy_digest, :string, null: false
      add :policy, :map, null: false
      add :hard_envelope, :map, null: false
      add :origin_intent_digest, :string
      add :current_checkpoint_id, :string
      add :domain_ref, :string
      add :domain_generation, :bigint
      add :domain_os_ref, :string
      add :domain_metadata, :map, null: false, default: %{}
      add :trajectory_version, :bigint, null: false, default: 0
      add :trajectory_regime, :string, null: false
      add :trajectory_state, :map
      add :owner_node, :string
      add :owner_lease_token, :string
      add :owner_lease_expires_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:episodes, :epoch_positive, check: "current_epoch >= 1")
    create constraint(:episodes, :trajectory_version_nonnegative, check: "trajectory_version >= 0")

    create table(:capability_leases, primary_key: false) do
      add :id, :string, primary_key: true
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :epoch, :bigint, null: false
      add :policy_version, :bigint, null: false
      add :capabilities, {:array, :map}, null: false
      add :max_effect_class, :string, null: false
      add :issued_at_ms, :bigint, null: false
      add :expires_at_ms, :bigint, null: false
      add :revoked_at_ms, :bigint
      add :authority_source, :string, null: false
      add :authority_ref, :string
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:capability_leases, [:episode_id, :epoch, :revoked_at_ms, :expires_at_ms], name: :leases_authority_lookup)

    create table(:checkpoints, primary_key: false) do
      add :id, :string, primary_key: true
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :epoch, :bigint, null: false
      add :domain_generation, :bigint, null: false
      add :parent_checkpoint_id, :string
      add :filesystem_ref, :text, null: false
      add :filesystem_digest, :string, null: false
      add :git_base_ref, :string
      add :git_patch_digest, :string
      add :trajectory_version, :bigint, null: false
      add :trajectory_ref, :string
      add :policy_version, :bigint, null: false
      add :capability_state_ref, :string
      add :environment_digest, :string
      add :dependency_lock_digest, :string
      add :trust_level, :string
      add :created_at_ms, :bigint, null: false
      add :pending_effect_ids, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:checkpoints, [:episode_id, :trust_level, :created_at_ms])

    create table(:effects, primary_key: false) do
      add :id, :string, primary_key: true
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :epoch, :bigint, null: false
      add :lease_id, references(:capability_leases, type: :string), null: false
      add :revision, :bigint, null: false
      add :class, :string, null: false
      add :kind, :string, null: false
      add :target, :map, null: false
      add :payload_ref, :text, null: false
      add :payload_digest, :string, null: false
      add :reversible, :boolean, null: false
      add :state, :string, null: false
      add :version_vector, :map, null: false
      add :idempotency_key, :string
      add :commit_attempt_id, :string
      add :version_vector_at_commit, :map
      add :commit_started_at_ms, :bigint
      add :expires_at_ms, :bigint
      add :committed_at_ms, :bigint
      add :external_receipt_ref, :string
      add :external_receipt, :map
      add :failure, :map
      add :created_at_ms, :bigint, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:effects, [:episode_id, :id])
    create unique_index(:effects, [:idempotency_key], where: "idempotency_key IS NOT NULL")
    create index(:effects, [:episode_id, :epoch, :state])
    create index(:effects, [:state, :commit_attempt_id])

    create table(:effect_decisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :effect_id, references(:effects, type: :string, on_delete: :delete_all), null: false
      add :effect_revision, :bigint, null: false
      add :kind, :string, null: false
      add :decision, :string, null: false
      add :source_ref, :string, null: false
      add :episode_id, :string, null: false
      add :epoch, :bigint, null: false
      add :policy_version, :bigint, null: false
      add :trajectory_version, :bigint, null: false
      add :snapshot_ref, :string
      add :expires_at_ms, :bigint
      add :payload_digest, :string, null: false
      add :evidence_ref, :string
      add :signature, :map
      add :created_at_ms, :bigint, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create unique_index(:effect_decisions, [:effect_id, :effect_revision, :kind, :source_ref], name: :effect_decision_identity)
    create index(:effect_decisions, [:effect_id, :effect_revision, :decision])

    create table(:episode_events) do
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :sequence, :bigint, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :previous_hash, :string
      add :entry_hash, :string, null: false
      add :created_at_ms, :bigint, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create unique_index(:episode_events, [:episode_id, :sequence])

    create table(:observation_frames) do
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :epoch, :bigint, null: false
      add :sequence, :bigint, null: false
      add :observed_at_ms, :bigint, null: false
      add :deterministic, {:array, :map}, null: false, default: []
      add :semantic, {:array, :map}, null: false, default: []
      add :resource, :map, null: false, default: %{}
      add :effect_context, :map
      add :dropped_low_priority_count, :integer, null: false, default: 0
      add :evidence_digest, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create unique_index(:observation_frames, [:episode_id, :epoch, :sequence])

    create table(:recovery_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :episode_id, references(:episodes, type: :string, on_delete: :delete_all), null: false
      add :from_epoch, :bigint, null: false
      add :to_epoch, :bigint, null: false
      add :checkpoint_id, :string
      add :old_domain_ref, :string
      add :new_domain_ref, :string
      add :reason, :text, null: false
      add :evidence_ref, :string
      add :created_at_ms, :bigint, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:recovery_records, [:episode_id, :created_at_ms])
  end
end
