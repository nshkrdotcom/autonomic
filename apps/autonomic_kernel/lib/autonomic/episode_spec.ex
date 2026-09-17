defmodule Autonomic.EpisodeSpec do
  @moduledoc "Immutable episode bootstrap specification accepted only from trusted callers."

  @enforce_keys [:id, :origin_intent, :workspace, :policy, :hard_envelope]
  defstruct [
    :id,
    :origin_intent,
    :workspace,
    :policy,
    :hard_envelope,
    :resource_limits,
    :environment,
    :requested_effect_ceiling,
    :worker_argv,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          origin_intent: term(),
          workspace: map(),
          policy: map(),
          hard_envelope: map(),
          resource_limits: map() | nil,
          environment: map() | nil,
          requested_effect_ceiling: Autonomic.Contracts.effect_class() | nil,
          worker_argv: [String.t()] | nil,
          metadata: map()
        }
end
