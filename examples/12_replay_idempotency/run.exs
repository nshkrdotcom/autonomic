alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo", "object_key" => "stable-object"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

first = Support.prepare!(spec, runtime, :http_read, "same bytes") |> Support.evaluate!() |> Support.commit!()
second_prepared = Support.prepare!(spec, runtime, :http_read, "same bytes")
second = second_prepared |> Support.evaluate!() |> Support.commit!()

first_receipt = get_in(first.metadata, ["external_receipt"])
second_receipt = get_in(second.metadata, ["external_receipt"])
IO.inspect(%{first_id: first.id, second_id: second.id, digest: first.payload_digest, first_receipt: first_receipt, second_receipt: second_receipt}, label: "replay")

Support.assert!(first.id != second.id, "current broker models repeated proposals as distinct logical effects")
Support.assert_equal!(first.payload_digest, second.payload_digest, "content identity is digest-stable")
Support.assert_equal!(second_receipt["mode"] || second_receipt[:mode], "idempotent_replay", "target conditional write must identify replay")

# Now simulate a moved target by changing the trusted object to a different digest.
:ok = Autonomic.Dev.TargetStore.put({"demo", "stable-object"}, "sha256:moved")
third = Support.prepare!(spec, runtime, :http_read, "new bytes") |> Support.evaluate!()
result = Autonomic.EffectBroker.commit(third.id)
IO.inspect(result, label: "moved target commit")
Support.assert!(match?({:ok, %{state: :commit_unknown}}, result), "post-intent adapter conflict is conservatively commit_unknown")
IO.puts("ASSERTION PASSED: digest identity is stable; target replay is idempotent; ambiguous conflicts do not clobber")
