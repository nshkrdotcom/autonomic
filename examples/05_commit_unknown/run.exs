alias Autonomic.EffectBroker
alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo", "mode" => "unknown_after_write", "object_key" => "artifact-a"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

ambiguous = Support.prepare!(spec, runtime, :http_read, "mutation happened") |> Support.evaluate!()
{:ok, unknown} = EffectBroker.commit(ambiguous.id)
retry = EffectBroker.commit(ambiguous.id)
{:ok, reconciled} = EffectBroker.reconcile(ambiguous.id)

Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo", "mode" => "unknown_without_evidence", "object_key" => "artifact-b", "reconcile_unknown" => true})
indeterminate = Support.prepare!(spec, runtime, :http_read, "no evidence") |> Support.evaluate!()
{:ok, still_unknown} = EffectBroker.commit(indeterminate.id)
{:ok, still_unknown} = EffectBroker.reconcile(indeterminate.id)

IO.inspect({unknown.state, retry, reconciled.state}, label: "mutated target path")
IO.inspect(still_unknown.state, label: "indeterminate reconciliation")
Support.assert_equal!(unknown.state, :commit_unknown, "ambiguous commit state")
Support.assert!(match?({:error, _}, retry), "automatic/blind retry must be rejected")
Support.assert_equal!(reconciled.state, :committed, "authoritative evidence resolves committed")
Support.assert_equal!(still_unknown.state, :commit_unknown, "unprovable outcome remains unknown")
IO.puts("ASSERTION PASSED: commit_unknown is reconciled, never guessed or blindly retried")
