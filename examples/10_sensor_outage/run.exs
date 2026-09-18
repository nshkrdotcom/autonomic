alias Autonomic.{EffectBroker, SystemRegulator}
alias Autonomic.Dev.{ScriptedSensor, Support}

Support.reset!()
class = :class_3_authoritative_external_mutation
Support.install_adapter!("http_mutation", class, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: class, kinds: ["http_mutation"])

cases = [
  {:provider_unavailable, {:unavailable, :provider_down}},
  {:unknown_answer_tag, {:error, :unknown_answer_tag}},
  {:model_outside_allowlist, {:error, {:model_outside_allowlist, "unexpected-model"}}}
]

# Prepare every outage case while the regulator is healthy. Once semantic health
# degrades, new Class 3 proposals must be rejected instead of sneaking through.
prepared =
  Enum.map(cases, fn {label, sensor_result} ->
    {label, sensor_result, Support.prepare!(spec, runtime, :http_mutation, "sensitive #{label}")}
  end)

# Also create one fully-ready Class 3 effect before the outage so we can prove
# that the commit horizon closes after semantic degradation.
ScriptedSensor.script([ScriptedSensor.safe()])
ready_before_outage =
  Support.prepare!(spec, runtime, :http_mutation, "ready before outage")
  |> Support.evaluate!()

Enum.each(prepared, fn {label, sensor_result, effect} ->
  ScriptedSensor.script([sensor_result])
  result = EffectBroker.evaluate(effect.id)
  IO.inspect(result, label: to_string(label))

  Support.assert!(
    match?({:error, {:semantic_unavailable, _}}, result),
    "#{label} must become semantic unavailability"
  )
end)

snapshot =
  Support.await!(
    fn ->
      snapshot = SystemRegulator.snapshot()
      if snapshot.health.semantic == :degraded, do: {:ok, snapshot}, else: false
    end,
    "semantic health to become degraded"
  )

IO.inspect(snapshot, label: "regulator")

Support.assert_equal!(
  SystemRegulator.sensitive_commit_allowed?(),
  false,
  "sensitive commit gate after semantic degradation"
)

Support.assert_equal!(
  EffectBroker.commit(ready_before_outage.id),
  {:error, :sensitive_commits_paused},
  "already-ready Class 3 commit must stop at the degraded commit horizon"
)

blocked_prepare =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :http_mutation,
    target_id: "demo",
    target: %{},
    payload: "new proposal after outage"
  })

Support.assert_equal!(
  blocked_prepare,
  {:error, :system_backpressure},
  "new Class 3 proposal must be rejected after semantic degradation"
)

# WRONG: bypassing the semantic decision to restore throughput would violate the policy floor.
# Never add a fallback that records semantic :allow on provider failure.
IO.puts(
  "ASSERTION PASSED: semantic failure contracts capability, blocks new sensitive work, and closes the commit horizon"
)
