alias Autonomic.{AuthorityGovernor, EffectBroker}
alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])

old = Support.prepare!(spec, runtime, :http_read, "old epoch") |> Support.evaluate!()
{:ok, new_epoch} = AuthorityGovernor.advance_epoch(spec.id, :example_epoch_fence)
{:ok, stale} = Autonomic.Dev.MemoryStore.fetch_effect(old.id)
stale_commit = EffectBroker.commit(old.id)
IO.inspect({stale.state, stale_commit}, label: "old effect after epoch advance")

{:ok, lease} = AuthorityGovernor.issue(spec.id, %{
  authority_source: :signed_policy,
  capabilities: runtime.lease.capabilities,
  max_effect_class: :class_2_external_observable_or_compensatable,
  ttl_ms: 30_000,
  reason: "new epoch example"
})
new_runtime = %{runtime | lease: lease, epoch: new_epoch}
fresh = Support.prepare!(spec, new_runtime, :http_read, "new epoch") |> Support.evaluate!() |> Support.commit!()

Support.assert_equal!(stale.state, :stale, "old prepared effect must be marked stale")
Support.assert_equal!(stale_commit, {:error, :stale_authority}, "stale commit denial")
Support.assert_equal!(fresh.epoch, new_epoch, "fresh effect epoch")
Support.assert_equal!(fresh.state, :committed, "fresh effect commits")
IO.puts("ASSERTION PASSED: stale authority cannot cross an epoch fence")
