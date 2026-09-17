defmodule Autonomic.Contracts do
  @moduledoc """
  Normative public contracts for the BEAM Autonomic Agent Runtime.

  This file is intentionally self-contained so an implementation agent can use it
  as the starting contract before splitting modules into their final files.
  """

  @type episode_id :: String.t()
  @type epoch :: non_neg_integer()
  @type policy_version :: non_neg_integer()
  @type trajectory_version :: non_neg_integer()
  @type effect_id :: String.t()
  @type lease_id :: String.t()
  @type snapshot_ref :: String.t()
  @type domain_ref :: String.t()

  @type trajectory_regime :: :stable | :uncertain | :drifting | :unstable | :containment

  @type semantic_exit_reason ::
          :trajectory_violation
          | :confidence_collapse
          | :authority_exhausted
          | :environment_mismatch
          | :irreversible_effect_risk

  @type semantic_exit :: {:semantic_exit, semantic_exit_reason(), evidence :: map()}

  @type effect_class ::
          :class_0_local_replayable
          | :class_1_isolated_mutable
          | :class_2_external_observable_or_compensatable
          | :class_3_authoritative_external_mutation
          | :class_4_irreversible_high_impact

  @type effect_state ::
          :proposed
          | :prepared
          | :evaluating
          | :ready
          | :commit_intent
          | :committing
          | :committed
          | :aborted
          | :expired
          | :stale
          | :commit_unknown
          | :failed
end


defmodule Autonomic.ExecutionDomain do
  @moduledoc """
  Backend-neutral isolation boundary for an untrusted episode worker.

  Implementations MUST treat `epoch` as fencing data and reject lifecycle or exec
  operations addressed to a stale domain generation.
  """

  alias Autonomic.Contracts

  defmodule Spec do
    @enforce_keys [:episode_id, :epoch, :workspace, :hard_envelope]
    defstruct [
      :episode_id,
      :epoch,
      :workspace,
      :hard_envelope,
      :resource_limits,
      :environment,
      :effect_socket,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            episode_id: Contracts.episode_id(),
            epoch: Contracts.epoch(),
            workspace: map(),
            hard_envelope: map(),
            resource_limits: map() | nil,
            environment: %{optional(String.t()) => String.t()} | nil,
            effect_socket: String.t() | nil,
            metadata: map()
          }
  end

  defmodule Domain do
    @enforce_keys [:id, :episode_id, :epoch, :generation, :backend]
    defstruct [:id, :episode_id, :epoch, :generation, :backend, :os_ref, metadata: %{}]

    @type t :: %__MODULE__{
            id: Contracts.domain_ref(),
            episode_id: Contracts.episode_id(),
            epoch: Contracts.epoch(),
            generation: non_neg_integer(),
            backend: module(),
            os_ref: term(),
            metadata: map()
          }
  end

  defmodule Command do
    @enforce_keys [:argv]
    defstruct [:argv, cwd: nil, env: %{}, stdin: nil, timeout_ms: 60_000, metadata: %{}]

    @type t :: %__MODULE__{
            argv: [String.t(), ...],
            cwd: String.t() | nil,
            env: %{optional(String.t()) => String.t()},
            stdin: iodata() | nil,
            timeout_ms: pos_integer(),
            metadata: map()
          }
  end

  defmodule Execution do
    @enforce_keys [:id, :domain_id, :started_at]
    defstruct [:id, :domain_id, :os_pid, :started_at, :exit_status, metadata: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            domain_id: Contracts.domain_ref(),
            os_pid: non_neg_integer() | nil,
            started_at: integer(),
            exit_status: integer() | nil,
            metadata: map()
          }
  end

  defmodule CheckpointRef do
    @enforce_keys [:ref, :episode_id, :epoch, :domain_generation, :digest]
    defstruct [:ref, :episode_id, :epoch, :domain_generation, :digest, metadata: %{}]

    @type t :: %__MODULE__{
            ref: Contracts.snapshot_ref(),
            episode_id: Contracts.episode_id(),
            epoch: Contracts.epoch(),
            domain_generation: non_neg_integer(),
            digest: String.t(),
            metadata: map()
          }
  end

  @type signal :: :sigterm | :sigkill | :sigint | :sigtstp | :sigcont

  @callback create(Spec.t()) :: {:ok, Domain.t()} | {:error, term()}
  @callback exec(Domain.t(), Command.t()) :: {:ok, Execution.t()} | {:error, term()}
  @callback signal(Domain.t(), signal()) :: :ok | {:error, term()}
  @callback checkpoint(Domain.t()) :: {:ok, CheckpointRef.t()} | {:error, term()}
  @callback restore(CheckpointRef.t()) :: {:ok, Domain.t()} | {:error, term()}
  @callback destroy(Domain.t()) :: :ok | {:error, term()}
  @callback inspect_domain(Domain.t()) :: {:ok, map()} | {:error, term()}
end


defmodule Autonomic.EpisodeCheckpoint do
  alias Autonomic.Contracts

  @enforce_keys [
    :episode_id,
    :epoch,
    :domain_generation,
    :filesystem_ref,
    :filesystem_digest,
    :trajectory_version,
    :policy_version,
    :created_at
  ]
  defstruct [
    :id,
    :episode_id,
    :epoch,
    :domain_generation,
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
    :parent_checkpoint_id,
    :trust_level,
    :created_at,
    pending_effect_ids: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          domain_generation: non_neg_integer(),
          filesystem_ref: String.t(),
          filesystem_digest: String.t(),
          git_base_ref: String.t() | nil,
          git_patch_digest: String.t() | nil,
          trajectory_version: Contracts.trajectory_version(),
          trajectory_ref: String.t() | nil,
          policy_version: Contracts.policy_version(),
          capability_state_ref: String.t() | nil,
          environment_digest: String.t() | nil,
          dependency_lock_digest: String.t() | nil,
          parent_checkpoint_id: String.t() | nil,
          trust_level: :stable | :provisional | :quarantined | nil,
          created_at: integer(),
          pending_effect_ids: [Contracts.effect_id()],
          metadata: map()
        }
end


defmodule Autonomic.Capability do
  @enforce_keys [:kind, :scope]
  defstruct [:kind, :scope, constraints: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          scope: term(),
          constraints: map()
        }
end


defmodule Autonomic.CapabilityLease do
  alias Autonomic.Contracts

  @enforce_keys [
    :id,
    :episode_id,
    :epoch,
    :policy_version,
    :capabilities,
    :max_effect_class,
    :issued_at,
    :expires_at,
    :authority_source
  ]
  defstruct [
    :id,
    :episode_id,
    :epoch,
    :policy_version,
    :capabilities,
    :max_effect_class,
    :issued_at,
    :expires_at,
    :authority_source,
    :authority_ref,
    :reason,
    :revoked_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: Contracts.lease_id(),
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          policy_version: Contracts.policy_version(),
          capabilities: [Autonomic.Capability.t()],
          max_effect_class: Contracts.effect_class(),
          issued_at: integer(),
          expires_at: integer(),
          authority_source: :signed_policy | :slow_verifier | :human | :parent_capability,
          authority_ref: String.t() | nil,
          reason: String.t() | nil,
          revoked_at: integer() | nil,
          metadata: map()
        }
end


defmodule Autonomic.VersionVector do
  alias Autonomic.Contracts

  @enforce_keys [
    :episode_id,
    :epoch,
    :policy_version,
    :snapshot_ancestry,
    :trajectory_version,
    :trajectory_regime,
    :lease_id,
    :effect_revision
  ]
  defstruct [
    :episode_id,
    :epoch,
    :policy_version,
    :snapshot_ancestry,
    :trajectory_version,
    :trajectory_regime,
    :lease_id,
    :effect_revision
  ]

  @type t :: %__MODULE__{
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          policy_version: Contracts.policy_version(),
          snapshot_ancestry: [String.t()],
          trajectory_version: Contracts.trajectory_version(),
          trajectory_regime: Contracts.trajectory_regime(),
          lease_id: Contracts.lease_id(),
          effect_revision: non_neg_integer()
        }
end


defmodule Autonomic.ProposedEffect do
  alias Autonomic.Contracts

  @enforce_keys [
    :id,
    :episode_id,
    :epoch,
    :lease_id,
    :class,
    :kind,
    :target,
    :payload_ref,
    :reversible?,
    :state,
    :version_vector,
    :created_at
  ]
  defstruct [
    :id,
    :episode_id,
    :epoch,
    :lease_id,
    :class,
    :kind,
    :target,
    :payload_ref,
    :payload_digest,
    :revision,
    :reversible?,
    :state,
    :version_vector,
    :expires_at,
    :idempotency_key,
    :commit_attempt_id,
    :committed_at,
    :external_receipt_ref,
    :failure,
    :created_at,
    approvals: [],
    verifications: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: Contracts.effect_id(),
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          lease_id: Contracts.lease_id(),
          class: Contracts.effect_class(),
          kind: atom(),
          target: map(),
          payload_ref: String.t(),
          reversible?: boolean(),
          state: Contracts.effect_state(),
          version_vector: Autonomic.VersionVector.t(),
          expires_at: integer() | nil,
          idempotency_key: String.t() | nil,
          commit_attempt_id: String.t() | nil,
          committed_at: integer() | nil,
          external_receipt_ref: String.t() | nil,
          failure: term() | nil,
          created_at: integer(),
          approvals: [map()],
          verifications: [map()],
          metadata: map()
        }
end


defmodule Autonomic.HomeostaticState do
  alias Autonomic.Contracts

  @enforce_keys [:episode_id, :epoch, :trajectory_version, :regime]
  defstruct [
    :episode_id,
    :epoch,
    :trajectory_version,
    :regime,
    drift: 0.0,
    volatility: 0.0,
    uncertainty: 0.0,
    scope_pressure: 0.0,
    authority_pressure: 0.0,
    destructive_pressure: 0.0,
    blast_radius_remaining: 1.0,
    autonomy_balance: 1.0,
    approval_pressure: 0.0,
    verification_pressure: 0.0,
    repair_count: 0,
    restart_count: 0,
    deterministic_violations: [],
    semantic_sensor_health: :healthy,
    regime_entered_at: nil,
    last_stable_checkpoint_id: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          trajectory_version: Contracts.trajectory_version(),
          regime: Contracts.trajectory_regime(),
          drift: float(),
          volatility: float(),
          uncertainty: float(),
          scope_pressure: float(),
          authority_pressure: float(),
          destructive_pressure: float(),
          blast_radius_remaining: float(),
          autonomy_balance: float(),
          approval_pressure: float(),
          verification_pressure: float(),
          repair_count: non_neg_integer(),
          restart_count: non_neg_integer(),
          deterministic_violations: [map()],
          semantic_sensor_health: :healthy | :degraded | :unavailable,
          regime_entered_at: integer() | nil,
          last_stable_checkpoint_id: String.t() | nil,
          metadata: map()
        }
end


defmodule Autonomic.SemanticObservation do
  @moduledoc "Normalized semantic evidence plus reproducibility/provenance metadata; never authority."

  @enforce_keys [:sensor, :value, :observed_at]
  defstruct [
    :sensor,
    :value,
    :confidence,
    :probabilities,
    :model,
    :requested_model,
    :request_id,
    :sdk_version,
    :sensor_bank_version,
    :semantic_contract_id,
    :usage,
    :retries,
    :latency_ms,
    :observed_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          sensor: atom(),
          value: term(),
          confidence: number() | nil,
          probabilities: map() | nil,
          model: String.t() | nil,
          requested_model: String.t() | nil,
          request_id: String.t() | nil,
          sdk_version: String.t() | nil,
          sensor_bank_version: String.t() | nil,
          semantic_contract_id: String.t() | nil,
          usage: map() | nil,
          retries: non_neg_integer() | nil,
          latency_ms: number() | nil,
          observed_at: integer(),
          metadata: map()
        }
end


defmodule Autonomic.ObservationFrame do
  alias Autonomic.Contracts

  @enforce_keys [:episode_id, :epoch, :sequence, :observed_at]
  defstruct [
    :episode_id,
    :epoch,
    :sequence,
    :observed_at,
    deterministic: [],
    semantic: [],
    resource: %{},
    effect_context: nil,
    dropped_low_priority_count: 0,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          sequence: non_neg_integer(),
          observed_at: integer(),
          deterministic: [map()],
          semantic: [Autonomic.SemanticObservation.t()],
          resource: map(),
          effect_context: map() | nil,
          dropped_low_priority_count: non_neg_integer(),
          metadata: map()
        }
end


defmodule Autonomic.Trajectory do
  alias Autonomic.Contracts

  @enforce_keys [:episode_id, :epoch, :version, :regime, :state_vector]
  defstruct [
    :episode_id,
    :epoch,
    :version,
    :regime,
    :state_vector,
    :deltas,
    :evidence_refs,
    :updated_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          version: Contracts.trajectory_version(),
          regime: Contracts.trajectory_regime(),
          state_vector: %{optional(atom()) => number()},
          deltas: %{optional(atom()) => number()} | nil,
          evidence_refs: [String.t()] | nil,
          updated_at: integer() | nil,
          metadata: map()
        }
end


defmodule Autonomic.TrajectoryAlert do
  alias Autonomic.Contracts

  @enforce_keys [:episode_id, :epoch, :kind, :severity, :evidence]
  defstruct [:episode_id, :epoch, :kind, :severity, :previous_regime, :new_regime, :evidence, :at]

  @type t :: %__MODULE__{
          episode_id: Contracts.episode_id(),
          epoch: Contracts.epoch(),
          kind: atom(),
          severity: number(),
          previous_regime: Contracts.trajectory_regime() | nil,
          new_regime: Contracts.trajectory_regime() | nil,
          evidence: map(),
          at: integer() | nil
        }
end


defmodule Autonomic.EffectAdapter do
  @moduledoc "Trusted adapter contract. Untrusted workers never call an adapter directly."

  @callback validate(Autonomic.ProposedEffect.t(), keyword()) :: :ok | {:error, term()}
  @callback commit(Autonomic.ProposedEffect.t(), keyword()) ::
              {:ok, receipt :: map()} | {:error, term()} | {:unknown, term()}
  @callback reconcile(Autonomic.ProposedEffect.t(), keyword()) ::
              {:committed, receipt :: map()} | :not_committed | {:unknown, term()}
end


defmodule Autonomic.SemanticSensor do
  @moduledoc "Semantic sensor contract; implementations provide evidence, never authority."

  @callback observe(Autonomic.ObservationFrame.t(), keyword()) ::
              {:ok, [Autonomic.SemanticObservation.t()]} | {:error, term()}
end


defmodule Autonomic.Store do
  @moduledoc "Authoritative persistence contract for episode, epoch, lease and effect state."

  @callback current_epoch(Autonomic.Contracts.episode_id()) ::
              {:ok, Autonomic.Contracts.epoch()} | {:error, term()}

  @callback advance_epoch(Autonomic.Contracts.episode_id(), map()) ::
              {:ok, Autonomic.Contracts.epoch()} | {:error, term()}

  @callback put_lease(Autonomic.CapabilityLease.t()) :: :ok | {:error, term()}
  @callback fetch_lease(Autonomic.Contracts.lease_id()) ::
              {:ok, Autonomic.CapabilityLease.t()} | :not_found | {:error, term()}

  @callback put_effect(Autonomic.ProposedEffect.t()) :: :ok | {:error, term()}
  @callback fetch_effect(Autonomic.Contracts.effect_id()) ::
              {:ok, Autonomic.ProposedEffect.t()} | :not_found | {:error, term()}

  @callback append_event(Autonomic.Contracts.episode_id(), atom(), map()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
