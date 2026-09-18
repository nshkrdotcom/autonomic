alias Autonomic.EffectBroker
alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

effect = Support.prepare!(spec, runtime, :http_read, "example payload") |> Support.print_effect("PREPARED")
ready = Support.evaluate!(effect) |> Support.print_effect("READY")
committed = Support.commit!(ready) |> Support.print_effect("COMMITTED")
second = EffectBroker.commit(committed.id)
IO.inspect(second, label: "second commit")

Support.assert_equal!(effect.version_vector, ready.version_vector, "version vector remains bound across evaluation")
Support.assert_equal!(committed.state, :committed, "first commit state")
Support.assert!(match?({:error, _}, second), "second commit must be rejected")
Support.complete_episode!(spec.id)
IO.puts("ASSERTION PASSED: one effect crossed the commit horizon exactly once")
