alias Autonomic.{Canonical, EffectBroker, ObservationFrame, Runtime, SensorArray}
alias Autonomic.Dev.Support

Support.reset!()

defmodule SlowExampleAdapter do
  @behaviour Autonomic.EffectAdapter
  def validate(_effect, _opts), do: (Process.sleep(400); :ok)
  def commit(effect, _opts), do: {:ok, %{receipt_ref: "slow:#{effect.id}"}}
  def reconcile(_effect, _opts), do: :not_committed
end

Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"}, SlowExampleAdapter)
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read"])
attrs = %{episode_id: spec.id, lease_id: runtime.lease.id, kind: :http_read, target_id: "demo", target: %{}, payload: "one"}
first = Task.async(fn -> EffectBroker.prepare(attrs) end)
Support.await!(fn -> if EffectBroker.stats().active == 1, do: {:ok, true}, else: false end, "first broker task to occupy the only slot")
second = EffectBroker.prepare(%{attrs | payload: "two"})
first_result = Task.await(first, 2_000)
IO.inspect({first_result, second}, label: "broker saturation")
Support.assert!(match?({:ok, _}, first_result), "first broker job must run")
Support.assert_equal!(second, {:error, :effect_broker_saturated}, "bounded broker saturation")

standalone = Canonical.id()
{:ok, _pid} = SensorArray.start_link(episode_id: standalone, max_queue: 2)
for seq <- 1..3 do
  SensorArray.publish(standalone, %ObservationFrame{episode_id: standalone, epoch: 1, sequence: seq, observed_at: System.system_time(:millisecond), semantic: [], deterministic: []}, :normal)
end
critical = %ObservationFrame{episode_id: standalone, epoch: 1, sequence: 99, observed_at: System.system_time(:millisecond), semantic: [], deterministic: [%{type: :direct_network_attempt}]}
SensorArray.publish(standalone, critical, :critical)
Process.sleep(20)
state = :sys.get_state(Runtime.via(standalone, :sensor_array))
queued = :queue.to_list(state.queue)
IO.inspect(%{dropped: state.dropped, queued_sequences: Enum.map(queued, fn {_p, f} -> f.sequence end)}, label: "sensor queue")
Support.assert!(state.dropped >= 1, "low-priority frames must shed under saturation")
Support.assert!(Enum.any?(queued, fn {_p, f} -> f.sequence == 99 end), "critical deterministic frame must survive")
IO.puts("ASSERTION PASSED: bounded pressure rejects/sheds instead of growing unbounded, while hard facts survive")
