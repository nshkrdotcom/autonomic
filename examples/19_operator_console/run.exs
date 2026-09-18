alias Autonomic.{EpisodeController, Homeostat}
alias Autonomic.Dev.{MemoryStore, Support}

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])
effect = Support.prepare!(spec, runtime, :http_read, "pending operator view")
{:ok, episode} = MemoryStore.fetch_episode(spec.id)
{:ok, effects} = MemoryStore.list_effects(spec.id)
homeostat = Homeostat.snapshot(spec.id)

IO.puts("AUTONOMIC OPERATOR VIEW")
IO.puts("episode=#{episode.id} state=#{episode.state} epoch=#{episode.current_epoch} regime=#{homeostat.regime}")
Enum.each(effects, fn e -> IO.puts("effect=#{e.id} class=#{e.class} state=#{e.state} kind=#{e.kind}") end)

Support.assert_equal!(effect.state, :prepared, "pending effect is visible")
EpisodeController.contain(spec.id, :operator_example)
contained = Support.await!(fn ->
  case EpisodeController.state(spec.id) do
    {:contained, data} -> {:ok, data}
    _ -> false
  end
end, "operator containment")
IO.inspect(contained, label: "contained")
Support.assert!(match?({:contained, _}, EpisodeController.state(spec.id)), "operator containment must reach terminal contained state")
IO.puts("ASSERTION PASSED: operator read paths expose authoritative state and containment is an explicit control action")
