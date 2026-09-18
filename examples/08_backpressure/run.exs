alias Autonomic.{Canonical, EffectBroker, ObservationFrame, Runtime, SensorArray}
alias Autonomic.Dev.{MemoryAdapter, Support}

Support.reset!()

defmodule BlockingExampleAdapter do
  @behaviour Autonomic.EffectAdapter

  @impl true
  def validate(_effect, _opts) do
    owner = Process.whereis(:autonomic_backpressure_example)
    send(owner, {:adapter_validate_entered, self()})

    receive do
      :release_adapter_validate -> :ok
    after
      5_000 -> {:error, :blocking_example_timeout}
    end
  end

  @impl true
  def commit(effect, _opts), do: {:ok, %{receipt_ref: "blocking:#{effect.id}"}}

  @impl true
  def reconcile(_effect, _opts), do: :not_committed
end

Process.register(self(), :autonomic_backpressure_example)

class = :class_2_external_observable_or_compensatable
Support.install_adapter!("http_read", class, %{"id" => "demo"}, MemoryAdapter)
{spec, runtime} = Support.start_episode!(max_class: class, kinds: ["http_read"])

# Prepare before inducing pressure. Evaluation revalidates the already-prepared
# effect through the adapter, which lets us occupy one real broker work slot
# without having admission control short-circuit the demonstration.
effect = Support.prepare!(spec, runtime, :http_read, "first")
Support.install_adapter!("http_read", class, %{"id" => "demo"}, BlockingExampleAdapter)

previous_limit = Application.get_env(:autonomic, :effect_concurrency, 8)
Application.put_env(:autonomic, :effect_concurrency, 1)
:ok = Supervisor.terminate_child(Autonomic.Supervisor, EffectBroker)

case Supervisor.restart_child(Autonomic.Supervisor, EffectBroker) do
  {:ok, _pid} -> :ok
  {:ok, _pid, _info} -> :ok
end

first = Task.async(fn -> EffectBroker.evaluate(effect.id) end)

worker =
  receive do
    {:adapter_validate_entered, pid} -> pid
  after
    2_000 -> raise "timed out waiting for first broker worker to enter adapter validation"
  end

second =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :http_read,
    target_id: "demo",
    target: %{},
    payload: "second"
  })

send(worker, :release_adapter_validate)
first_result = Task.await(first, 5_000)
Application.put_env(:autonomic, :effect_concurrency, previous_limit)

IO.inspect({first_result, second}, label: "broker saturation")
Support.assert!(match?({:ok, _}, first_result), "first broker job must run")
Support.assert_equal!(second, {:error, :effect_broker_saturated}, "bounded broker saturation")

standalone = Canonical.id()
{:ok, _pid} = SensorArray.start_link(episode_id: standalone, max_queue: 2)

for seq <- 1..3 do
  SensorArray.publish(
    standalone,
    %ObservationFrame{
      episode_id: standalone,
      epoch: 1,
      sequence: seq,
      observed_at: System.system_time(:millisecond),
      semantic: [],
      deterministic: []
    },
    :normal
  )
end

critical = %ObservationFrame{
  episode_id: standalone,
  epoch: 1,
  sequence: 99,
  observed_at: System.system_time(:millisecond),
  semantic: [],
  deterministic: [%{type: :direct_network_attempt}]
}

SensorArray.publish(standalone, critical, :critical)

state =
  Support.await!(
    fn ->
      stage = :sys.get_state(Runtime.via(standalone, :sensor_array))
      state = Map.fetch!(stage, :state)
      if state.dropped >= 1, do: {:ok, state}, else: false
    end,
    "sensor queue to shed a low-priority frame"
  )

queued = :queue.to_list(state.queue)

IO.inspect(
  %{
    dropped: state.dropped,
    queued_sequences: Enum.map(queued, fn {_priority, frame} -> frame.sequence end)
  },
  label: "sensor queue"
)

Support.assert!(state.dropped >= 1, "low-priority frames must shed under saturation")

Support.assert!(
  Enum.any?(queued, fn {_priority, frame} -> frame.sequence == 99 end),
  "critical deterministic frame must survive"
)

IO.puts(
  "ASSERTION PASSED: bounded pressure rejects/sheds instead of growing unbounded, while hard facts survive"
)
