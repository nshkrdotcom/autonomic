defmodule Autonomic.EffectState do
  @moduledoc "Closed effect lifecycle. Unknown outcomes never authorize another attempt."
  @edges %{
    proposed: [:prepared, :aborted, :expired, :stale, :failed],
    prepared: [:evaluating, :aborted, :expired, :stale, :failed],
    evaluating: [:ready, :aborted, :expired, :stale, :failed],
    ready: [:commit_intent, :aborted, :expired, :stale, :failed],
    commit_intent: [:committing, :commit_unknown],
    committing: [:committed, :commit_unknown, :failed],
    commit_unknown: [:committed, :failed], committed: [],
    aborted: [], expired: [], stale: [], failed: []
  }
  @classes [:class_0_local_replayable, :class_1_isolated_mutable,
    :class_2_external_observable_or_compensatable,
    :class_3_authoritative_external_mutation, :class_4_irreversible_high_impact]
  def allowed?(from, to), do: to in Map.get(@edges, from, [])
  def states, do: Map.keys(@edges)
  def parse_state(value), do: Enum.find(states(), &(Atom.to_string(&1) == value))
  def class(index) when index in 0..4, do: Enum.at(@classes, index)
  def rank(value), do: Enum.find_index(@classes, &(&1 == value))
  def uncommitted, do: [:proposed, :prepared, :evaluating, :ready]
  def in_flight, do: [:commit_intent, :committing, :commit_unknown]
  def in_flight?(state), do: state in in_flight()
end
