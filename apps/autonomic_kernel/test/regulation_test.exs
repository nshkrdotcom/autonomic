defmodule Autonomic.RegulationTest do
  use ExUnit.Case, async: false

  alias Autonomic.{Canonical, ObservationFrame, SensorArray, SystemRegulator}

  defmodule Probe do
    use GenStage

    def start_link(test_pid), do: GenStage.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:consumer, test_pid}

    def handle_events(events, _from, test_pid) do
      send(test_pid, {:probe_events, events})
      {:noreply, [], test_pid}
    end
  end

  setup do
    for source <- [:semantic, :store, :launcher], do: SystemRegulator.health(source, :healthy)

    for source <- [:semantic_queue, :effect_queue, :verifier_queue],
        do: SystemRegulator.report(source, 0.0)

    # Recovery is deliberately hysteretic; three recalculations return to normal.
    SystemRegulator.report(:semantic_queue, 0.0)
    SystemRegulator.report(:semantic_queue, 0.0)
    SystemRegulator.report(:semantic_queue, 0.0)
    :ok
  end

  test "semantic saturation propagates to admission and sensitive commit pressure" do
    SystemRegulator.report(:semantic_queue, 0.90)
    Process.sleep(10)
    assert SystemRegulator.mode() == :no_sensitive_commits
    refute SystemRegulator.sensitive_commit_allowed?()
    refute SystemRegulator.admit?(:class_3_authoritative_external_mutation)
    assert SystemRegulator.admit?(:class_1_isolated_mutable)
  end

  test "deterministic critical observations survive a full sensor queue" do
    episode_id = String.duplicate("b", 32)
    start_supervised!({SensorArray, episode_id: episode_id, max_queue: 2})

    low = frame(episode_id, 1, [])
    hard = frame(episode_id, 3, [%{type: :direct_network_attempt}])
    :ok = SensorArray.publish(episode_id, low, :normal)
    :ok = SensorArray.publish(episode_id, %{low | sequence: 2}, :normal)
    :ok = SensorArray.publish(episode_id, hard, :critical)

    {:ok, probe} = Probe.start_link(self())

    GenStage.sync_subscribe(probe,
      to: Autonomic.Runtime.via(episode_id, :sensor_array),
      max_demand: 3,
      min_demand: 0
    )

    assert_receive {:probe_events, events}, 1_000

    assert Enum.any?(events, fn event ->
             Enum.any?(event.deterministic, fn fact -> fact[:type] == :direct_network_attempt end)
           end)
  end

  defp frame(episode_id, sequence, deterministic) do
    %ObservationFrame{
      episode_id: episode_id,
      epoch: 1,
      sequence: sequence,
      observed_at: Canonical.now(),
      deterministic: deterministic,
      semantic: [],
      resource: %{}
    }
  end
end
