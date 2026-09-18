alias Autonomic.{Canonical, EffectBroker, ObservationFrame, Runtime, SensorArray}
alias Autonomic.Dev.Support

Support.reset!()

restart_broker = fn limit ->
  Application.put_env(:autonomic, :effect_concurrency, limit)

  :ok =
    Supervisor.terminate_child(
      Autonomic.Supervisor,
      Autonomic.EffectBroker
    )

  {:ok, _pid} =
    Supervisor.restart_child(
      Autonomic.Supervisor,
      Autonomic.EffectBroker
    )

  :ok
end

# First create a real prepared effect without putting the regulator under
# saturation pressure.
restart_broker.(8)

Support.install_adapter!(
  "http_read",
  :class_2_external_observable_or_compensatable,
  %{"id" => "demo"}
)

{spec, runtime} =
  Support.start_episode!(
    max_class: :class_2_external_observable_or_compensatable,
    kinds: ["http_read"]
  )

prepared =
  Support.prepare!(
    spec,
    runtime,
    :http_read,
    "prepared before saturation"
  )

defmodule BlockingExampleAdapter do
  @behaviour Autonomic.EffectAdapter

  @impl true
  def validate(_effect, _opts) do
    coordinator =
      Process.whereis(:autonomic_backpressure_example) ||
        raise "backpressure example coordinator missing"

    send(coordinator, {:adapter_validate_entered, self()})

    receive do
      :release_validate ->
        :ok
    after
      5_000 ->
        {:error, :example_release_timeout}
    end
  end

  @impl true
  def commit(effect, _opts),
    do: {:ok, %{receipt_ref: "blocking:#{effect.id}"}}

  @impl true
  def reconcile(_effect, _opts), do: :not_committed
end

Process.register(self(), :autonomic_backpressure_example)

# Evaluation resolves the adapter at execution time, so replace the normal
# adapter with the blocking one after preparation.
Support.install_adapter!(
  "http_read",
  :class_2_external_observable_or_compensatable,
  %{"id" => "demo"},
  BlockingExampleAdapter
)

# Now make the real broker capacity exactly one.
restart_broker.(1)

first =
  Task.async(fn ->
    EffectBroker.evaluate(prepared.id)
  end)

worker =
  receive do
    {:adapter_validate_entered, pid} ->
      pid
  after
    2_000 ->
      raise "timed out waiting for evaluation to occupy the broker slot"
  end

stats = EffectBroker.stats()

Support.assert_equal!(
  stats.active,
  1,
  "one broker worker occupies the only slot"
)

second =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :http_read,
    target_id: "demo",
    target: %{},
    payload: "must be rejected at saturation"
  })

IO.inspect(second, label: "prepare while broker slot is occupied")

Support.assert_equal!(
  second,
  {:error, :effect_broker_saturated},
  "bounded broker saturation"
)

send(worker, :release_validate)

first_result = Task.await(first, 2_000)
IO.inspect(first_result, label: "blocked evaluation after release")

Support.assert!(
  match?({:ok, %{state: :ready}}, first_result),
  "occupied broker job must complete after release"
)

Process.unregister(:autonomic_backpressure_example)

# ---------------------------------------------------------------------
# SensorArray pressure: low-priority work sheds, critical hard facts stay.
# ---------------------------------------------------------------------

standalone = Canonical.id()

{:ok, _pid} =
  SensorArray.start_link(
    episode_id: standalone,
    max_queue: 2
  )

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
      stage =
        :sys.get_state(Runtime.via(standalone, :sensor_array))

      state = Map.fetch!(stage, :state)
      queued = :queue.to_list(state.queue)

      critical_present? =
        Enum.any?(queued, fn {_priority, frame} ->
          frame.sequence == 99
        end)

      if state.dropped >= 1 and critical_present? do
        {:ok, state}
      else
        false
      end
    end,
    "sensor queue to shed low-priority work while retaining the critical frame"
  )

queued = :queue.to_list(state.queue)

IO.inspect(
  %{
    dropped: state.dropped,
    queued_sequences:
      Enum.map(queued, fn {_priority, frame} ->
        frame.sequence
      end)
  },
  label: "sensor queue"
)

Support.assert!(
  state.dropped >= 1,
  "low-priority frames must shed under saturation"
)

Support.assert!(
  Enum.any?(queued, fn {_priority, frame} ->
    frame.sequence == 99
  end),
  "critical deterministic frame must survive"
)

IO.puts(
  "ASSERTION PASSED: bounded pressure rejects/sheds instead of growing unbounded, while hard facts survive"
)
