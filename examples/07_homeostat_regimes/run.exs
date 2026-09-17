alias Autonomic.{Canonical, Homeostat, ObservationFrame, SemanticObservation}
alias Autonomic.Dev.{MemoryStore, Support}

Support.reset!()
id = Canonical.id()
policy = Support.default_policy(:class_2_external_observable_or_compensatable, ["http_read"])
hard = Support.hard_envelope(:class_2_external_observable_or_compensatable, [:http_read])
{:ok, _} = MemoryStore.create_episode(%{id: id, state: :running, current_epoch: 1, policy: policy, policy_version: 1, hard_envelope: hard, origin_intent_digest: Canonical.digest("homeostat"), trajectory_version: 0, trajectory_regime: :stable})
{:ok, _pid} = Homeostat.start_link(episode_id: id, epoch: 1)

obs = fn seq, sensor, value ->
  frame = %ObservationFrame{episode_id: id, epoch: 1, sequence: seq, observed_at: System.system_time(:millisecond), semantic: [%SemanticObservation{sensor: sensor, value: value, confidence: 1.0, observed_at: System.system_time(:millisecond)}]}
  {:ok, signal, state} = Homeostat.observe(id, frame)
  IO.puts("#{seq}: regime=#{state.regime} drift=#{Float.round(state.drift, 3)} uncertainty=#{Float.round(state.uncertainty, 3)} volatility=#{Float.round(state.volatility, 3)} -> #{inspect(signal)}")
  state
end

s1 = obs.(1, :evidence_sufficiency, :sufficient)
s2 = obs.(2, :evidence_sufficiency, :insufficient)
s3 = Enum.reduce(3..6, s2, fn seq, _ -> obs.(seq, :scope_drift, 1.0) end)
s4 = Enum.reduce(7..10, s3, fn seq, _ -> obs.(seq, :trajectory_regime, :unstable) end)

Support.assert_equal!(s1.regime, :stable, "initial stable regime")
Support.assert!(s2.regime in [:stable, :uncertain], "insufficient evidence raises uncertainty")
Support.assert!(s3.regime in [:drifting, :unstable], "sustained drift leaves stable regime")
Support.assert_equal!(s4.regime, :unstable, "sustained severe risk becomes unstable")

# Separate hysteresis probe: a drifting state does not recover on one benign frame.
id2 = Canonical.id()
{:ok, _} = MemoryStore.create_episode(%{id: id2, state: :running, current_epoch: 1, policy: policy, policy_version: 1, hard_envelope: hard, origin_intent_digest: Canonical.digest("hysteresis"), trajectory_version: 0, trajectory_regime: :stable})
{:ok, _} = Homeostat.start_link(episode_id: id2, epoch: 1)
for seq <- 1..5 do
  frame = %ObservationFrame{episode_id: id2, epoch: 1, sequence: seq, observed_at: System.system_time(:millisecond), semantic: [%SemanticObservation{sensor: :scope_drift, value: 1.0, confidence: 1.0, observed_at: System.system_time(:millisecond)}]}
  {:ok, _, _} = Homeostat.observe(id2, frame)
end
before = Homeostat.snapshot(id2)
frame = %ObservationFrame{episode_id: id2, epoch: 1, sequence: 6, observed_at: System.system_time(:millisecond), semantic: [%SemanticObservation{sensor: :scope_drift, value: 0.0, confidence: 1.0, observed_at: System.system_time(:millisecond)}, %SemanticObservation{sensor: :evidence_sufficiency, value: :sufficient, confidence: 1.0, observed_at: System.system_time(:millisecond)}]}
{:ok, _, after_one} = Homeostat.observe(id2, frame)
Support.assert!(before.regime in [:drifting, :unstable], "probe must first enter risky regime")
Support.assert!(after_one.regime != :stable, "one good frame must not erase sustained drift")
IO.puts("ASSERTION PASSED: trajectory regulation is temporal and recovery is hysteretic")
