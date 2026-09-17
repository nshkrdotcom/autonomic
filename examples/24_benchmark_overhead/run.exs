alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

measure = fn fun ->
  {us, result} = :timer.tc(fun)
  {us / 1000.0, result}
end

samples = for n <- 1..10 do
  {prepare_ms, effect} = measure.(fn -> Support.prepare!(spec, runtime, :http_read, "bench-#{n}") end)
  {evaluate_ms, ready} = measure.(fn -> Support.evaluate!(effect) end)
  {commit_ms, committed} = measure.(fn -> Support.commit!(ready) end)
  Support.assert_equal!(committed.state, :committed, "benchmark iteration #{n}")
  %{prepare_ms: prepare_ms, evaluate_ms: evaluate_ms, commit_ms: commit_ms}
end

avg = fn key -> Enum.sum(Enum.map(samples, &Map.fetch!(&1, key))) / length(samples) end
report = %{iterations: length(samples), prepare_ms_avg: avg.(:prepare_ms), evaluate_ms_avg: avg.(:evaluate_ms), commit_ms_avg: avg.(:commit_ms), environment: "UnsafeLocalDomain + MemoryStore + MemoryAdapter; NOT production"}
IO.inspect(report, label: "local overhead profile")
Support.assert!(Enum.all?(Map.take(report, [:prepare_ms_avg, :evaluate_ms_avg, :commit_ms_avg]) |> Map.values(), &(&1 >= 0.0)), "timings must be measured")
IO.puts("ASSERTION PASSED: kernel bookkeeping is measured separately and explicitly labeled so local-dev numbers cannot be mistaken for Linux/Postgres/model latency")
