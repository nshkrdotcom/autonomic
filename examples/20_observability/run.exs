alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

handler = "autonomic-example-observability"
:telemetry.attach_many(handler, [[:autonomic, :example, :effect, :prepare], [:autonomic, :example, :effect, :evaluate], [:autonomic, :example, :effect, :commit]], fn event, measurements, metadata, pid ->
  send(pid, {:telemetry_event, event, measurements, metadata})
end, self())

measure = fn stage, fun ->
  started = System.monotonic_time()
  result = fun.()
  duration = System.monotonic_time() - started
  :telemetry.execute([:autonomic, :example, :effect, stage], %{duration: duration}, %{episode_id: spec.id})
  result
end

effect = measure.(:prepare, fn -> Support.prepare!(spec, runtime, :http_read, "observe") end)
ready = measure.(:evaluate, fn -> Support.evaluate!(effect) end)
committed = measure.(:commit, fn -> Support.commit!(ready) end)

events = for _ <- 1..3 do
  receive do message = {:telemetry_event, _, _, _} -> message after 1_000 -> raise "missing telemetry event" end
end
Enum.each(events, &IO.inspect/1)
:telemetry.detach(handler)
Support.assert_equal!(committed.state, :committed, "observed effect")
Support.assert_equal!(length(events), 3, "event vocabulary coverage")
Support.assert!(Enum.all?(events, fn {:telemetry_event, _, m, md} -> is_integer(m.duration) and md.episode_id == spec.id end), "events contain bounded identifiers and duration only")
IO.puts("ASSERTION PASSED: telemetry vocabulary can wrap prepare/evaluate/commit without logging payloads or credentials")
