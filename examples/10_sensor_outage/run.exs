alias Autonomic.{EffectBroker, SystemRegulator}
alias Autonomic.Dev.{ScriptedSensor, Support}

Support.reset!()

Support.install_adapter!(
  "http_mutation",
  :class_3_authoritative_external_mutation,
  %{"id" => "demo"}
)

{spec, runtime} =
  Support.start_episode!(
    max_class: :class_3_authoritative_external_mutation,
    kinds: ["http_mutation"]
  )

cases = [
  {:provider_unavailable, {:unavailable, :provider_down}},
  {:unknown_answer_tag, {:error, :unknown_answer_tag}},
  {:model_outside_allowlist, {:error, {:model_outside_allowlist, "unexpected-model"}}}
]

# Prepare every test effect while the semantic system is still healthy.
prepared_cases =
  Enum.map(cases, fn {label, sensor_result} ->
    effect =
      Support.prepare!(
        spec,
        runtime,
        :http_mutation,
        "sensitive #{label}"
      )

    {label, sensor_result, effect}
  end)

# Also prepare + fully authorize one Class 3 effect before the outage.
# After semantic health degrades, the commit gate must still stop it.
ready_before_outage =
  Support.prepare!(
    spec,
    runtime,
    :http_mutation,
    "ready before semantic outage"
  )

ScriptedSensor.script([ScriptedSensor.safe()])
ready_before_outage = Support.evaluate!(ready_before_outage)

Support.assert_equal!(
  ready_before_outage.state,
  :ready,
  "control effect reaches ready state before outage"
)

Enum.each(prepared_cases, fn {label, sensor_result, effect} ->
  ScriptedSensor.script([sensor_result])

  result = EffectBroker.evaluate(effect.id)

  IO.inspect(result, label: to_string(label))

  Support.assert!(
    match?({:error, {:semantic_unavailable, _}}, result),
    "#{label} must be represented as semantic unavailability"
  )
end)

regulator =
  Support.await!(
    fn ->
      snapshot = SystemRegulator.snapshot()

      if snapshot.health.semantic == :degraded do
        {:ok, snapshot}
      else
        false
      end
    end,
    "SystemRegulator to record degraded semantic health"
  )

IO.inspect(regulator, label: "regulator after semantic failures")

Support.assert_equal!(
  SystemRegulator.sensitive_commit_allowed?(),
  false,
  "sensitive commit gate after semantic degradation"
)

blocked_commit = EffectBroker.commit(ready_before_outage.id)
IO.inspect(blocked_commit, label: "already-ready Class 3 commit after outage")

Support.assert_equal!(
  blocked_commit,
  {:error, :sensitive_commits_paused},
  "already-authorized sensitive commit is still stopped after degradation"
)

blocked_prepare =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :http_mutation,
    target_id: "demo",
    target: %{},
    payload: "new sensitive work after outage",
    reversible?: true
  })

IO.inspect(blocked_prepare, label: "new Class 3 admission after outage")

Support.assert_equal!(
  blocked_prepare,
  {:error, :system_backpressure},
  "new sensitive work is not admitted after semantic degradation"
)

# WRONG:
#   fabricate an :allow decision or bypass semantic evaluation to recover throughput.
#
# Correct behavior is contraction: existing sensitive commits pause and new
# sensitive work is refused until health deliberately recovers.

IO.puts(
  "ASSERTION PASSED: semantic failure contracts admission and commit authority and never fabricates an allow"
)
