alias Autonomic.{EffectBroker, SystemRegulator}
alias Autonomic.Dev.{ScriptedSensor, Support}

Support.reset!()
Support.install_adapter!("http_mutation", :class_3_authoritative_external_mutation, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_3_authoritative_external_mutation, kinds: ["http_mutation"])

cases = [
  {:provider_unavailable, {:unavailable, :provider_down}},
  {:unknown_answer_tag, {:error, :unknown_answer_tag}},
  {:model_outside_allowlist, {:error, {:model_outside_allowlist, "unexpected-model"}}}
]

Enum.each(cases, fn {label, sensor_result} ->
  ScriptedSensor.script([sensor_result])
  effect = Support.prepare!(spec, runtime, :http_mutation, "sensitive #{label}")
  result = EffectBroker.evaluate(effect.id)
  IO.inspect(result, label: to_string(label))
  Support.assert!(match?({:error, {:semantic_unavailable, _}}, result), "#{label} must be semantic unavailability")
end)

Process.sleep(20)
IO.inspect(SystemRegulator.snapshot(), label: "regulator")
Support.assert_equal!(SystemRegulator.sensitive_commit_allowed?(), false, "sensitive commit gate after semantic degradation")

# WRONG: bypassing the semantic decision to restore throughput would violate the policy floor.
# Never add a fallback that records semantic :allow on provider failure.
IO.puts("ASSERTION PASSED: semantic failure contracts capability and never fabricates an allow")
