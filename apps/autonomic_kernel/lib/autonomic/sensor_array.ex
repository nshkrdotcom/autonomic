defmodule Autonomic.SensorArray do
  @moduledoc "Demand-driven per-episode observation producer; deterministic violations are never dropped."
  use GenStage

  alias Autonomic.{ObservationFrame, Runtime, SystemRegulator}

  def start_link(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    GenStage.start_link(__MODULE__, opts, name: Runtime.via(episode_id, :sensor_array))
  end

  def publish(episode_id, %ObservationFrame{} = frame, priority \\ :normal) do
    GenStage.cast(Runtime.via(episode_id, :sensor_array), {:publish, frame, priority})
  end

  @impl true
  def init(opts) do
    max_queue =
      Keyword.get(opts, :max_queue, Application.get_env(:autonomic_kernel, :sensor_queue, 64))

    {:producer,
     %{
       episode_id: Keyword.fetch!(opts, :episode_id),
       queue: :queue.new(),
       demand: 0,
       max_queue: max_queue,
       dropped: 0
     }}
  end

  @impl true
  def handle_demand(incoming, state) when incoming > 0 do
    dispatch(%{state | demand: state.demand + incoming})
  end

  @impl true
  def handle_cast({:publish, frame, priority}, state) do
    state = enqueue(state, frame, priority)
    dispatch(state)
  end

  defp enqueue(state, frame, priority) do
    length = :queue.len(state.queue)
    hard? = hard_frame?(frame) or priority == :critical

    cond do
      length < state.max_queue ->
        %{state | queue: :queue.in({priority, frame}, state.queue)}

      hard? ->
        {queue, dropped?} = drop_one_low(state.queue)
        dropped = state.dropped + if(dropped?, do: 1, else: 0)
        SystemRegulator.report(:semantic_queue, min(1.0, (length + 1) / state.max_queue))
        %{state | queue: :queue.in_r({:critical, frame}, queue), dropped: dropped}

      true ->
        SystemRegulator.report(:semantic_queue, 1.0)
        %{state | dropped: state.dropped + 1}
    end
  end

  defp dispatch(%{demand: demand} = state) when demand <= 0, do: {:noreply, [], state}

  defp dispatch(state) do
    take = min(state.demand, :queue.len(state.queue))
    {events, queue} = take_queue(state.queue, take, [])
    pressure = if state.max_queue == 0, do: 0.0, else: :queue.len(queue) / state.max_queue
    SystemRegulator.report(:semantic_queue, pressure)
    {:noreply, Enum.reverse(events), %{state | queue: queue, demand: state.demand - take}}
  end

  defp take_queue(queue, 0, acc), do: {acc, queue}

  defp take_queue(queue, count, acc) do
    case :queue.out(queue) do
      {{:value, {_priority, frame}}, rest} -> take_queue(rest, count - 1, [frame | acc])
      {:empty, _} -> {acc, queue}
    end
  end

  defp drop_one_low(queue) do
    items = :queue.to_list(queue)

    case Enum.find_index(items, fn {priority, frame} ->
           priority != :critical and not hard_frame?(frame)
         end) do
      nil -> {queue, false}
      index -> {items |> List.delete_at(index) |> :queue.from_list(), true}
    end
  end

  defp hard_frame?(frame) do
    Enum.any?(frame.deterministic, fn fact ->
      type =
        Map.get(fact, :type) || Map.get(fact, "type") || Map.get(fact, :kind) ||
          Map.get(fact, "kind")

      type in [
        :boundary_violation,
        :direct_network_attempt,
        :forbidden_path_attempt,
        :forbidden_mount_attempt,
        :stale_epoch_request,
        :capability_misuse,
        :cgroup_escape,
        :forbidden_credential_access,
        :namespace_escape,
        :seccomp_violation,
        "boundary_violation",
        "direct_network_attempt",
        "forbidden_path_attempt",
        "forbidden_mount_attempt",
        "stale_epoch_request",
        "capability_misuse",
        "cgroup_escape",
        "forbidden_credential_access",
        "namespace_escape",
        "seccomp_violation"
      ]
    end)
  end
end

defmodule Autonomic.SensorConsumer do
  @moduledoc false
  use GenStage
  alias Autonomic.{Homeostat, Runtime}

  def start_link(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    GenStage.start_link(__MODULE__, opts, name: Runtime.via(episode_id, :sensor_consumer))
  end

  @impl true
  def init(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    producer = Runtime.via(episode_id, :sensor_array)

    {:consumer, %{episode_id: episode_id},
     subscribe_to: [{producer, max_demand: 8, min_demand: 2}]}
  end

  @impl true
  def handle_events(frames, _from, state) do
    Enum.each(frames, fn frame ->
      case Homeostat.observe(state.episode_id, frame) do
        {:ok, _, _} -> :ok
        _ -> :ok
      end
    end)

    {:noreply, [], state}
  end
end
