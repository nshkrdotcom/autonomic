alias Autonomic.{ObservationFrame, Policy, SemanticObservation}
alias Autonomic.Dev.Support

Support.reset!()
rows = [
  {"semantic allow only", [%{"source" => "semantic", "decision" => "allow"}], :no_denial},
  {"semantic deny", [%{"source" => "semantic", "decision" => "deny"}], {:deny, "semantic"}},
  {"human allow + semantic deny", [%{"source" => "human", "decision" => "allow"}, %{"source" => "semantic", "decision" => "deny"}], {:deny, "semantic"}},
  {"policy deny + semantic allow", [%{"source" => "signed_policy", "decision" => "deny"}, %{"source" => "semantic", "decision" => "allow"}], {:deny, "signed_policy"}},
  {"capability deny + human allow", [%{"source" => "capability_violation", "decision" => "deny"}, %{"source" => "human", "decision" => "allow"}], {:deny, "capability_violation"}},
  {"kernel deny + everything allow", [%{"source" => "kernel_denial", "decision" => "deny"}, %{"source" => "signed_policy", "decision" => "allow"}, %{"source" => "human", "decision" => "allow"}, %{"source" => "semantic", "decision" => "allow"}], {:deny, "kernel_denial"}}
]
Enum.each(rows, fn {label, observations, expected} ->
  actual = Policy.precedence(observations)
  IO.puts("#{String.pad_trailing(label, 31)} => #{inspect(actual)}")
  Support.assert_equal!(actual, expected, label)
end)

# Semantic risk may contract control, but it is not an authority source for expansion.
{spec, _runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])
expansion = Autonomic.AuthorityGovernor.issue(spec.id, %{authority_source: :semantic, capabilities: [], max_effect_class: :class_2_external_observable_or_compensatable})
Support.assert_equal!(expansion, {:error, :semantic_cannot_expand_authority}, "semantic authority expansion")

signal = Enum.reduce(1..3, nil, fn seq, _last ->
  frame = %ObservationFrame{episode_id: spec.id, epoch: 1, sequence: seq, observed_at: System.system_time(:millisecond), semantic: [%SemanticObservation{sensor: :scope_drift, value: 1.0, confidence: 1.0, observed_at: System.system_time(:millisecond)}]}
  {:ok, signal, _state} = Autonomic.Homeostat.observe(spec.id, frame)
  signal
end)
IO.inspect(signal, label: "sustained drift signal")
Support.assert!(match?({:homeostat, action, _, _} when action in [:narrow, :preempt, :yield], signal), "sustained semantic drift must only contract or pause authority")
IO.puts("ASSERTION PASSED: higher-precedence denial wins and semantics cannot expand hard authority")
