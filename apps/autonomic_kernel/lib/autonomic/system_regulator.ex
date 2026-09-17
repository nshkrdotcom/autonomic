defmodule Autonomic.SystemRegulator do
  @moduledoc "Node-wide pressure aggregation, hysteretic autonomy modes, and semantic/store circuit breakers."
  use GenServer

  alias Autonomic.Policy

  @type mode ::
          :normal | :constrained | :read_only_autonomy | :no_sensitive_commits | :admission_closed

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def report(source, value) when is_atom(source) and is_number(value),
    do: GenServer.cast(__MODULE__, {:pressure, source, clamp(value)})

  def health(source, status)
      when source in [:semantic, :store, :launcher] and
             status in [:healthy, :degraded, :unavailable],
      do: GenServer.cast(__MODULE__, {:health, source, status})

  def semantic_health(status), do: health(:semantic, status)
  def mode, do: GenServer.call(__MODULE__, :mode)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def admit?(class \\ :class_0_local_replayable), do: GenServer.call(__MODULE__, {:admit?, class})
  def sensitive_commit_allowed?, do: GenServer.call(__MODULE__, :sensitive_commit_allowed?)

  @impl true
  def init(_) do
    Process.send_after(self(), :recalculate, 250)

    {:ok,
     %{
       pressures: %{},
       health: %{semantic: :healthy, store: :healthy, launcher: :healthy},
       mode: :normal,
       candidate: :normal,
       candidate_count: 0,
       updated_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_info(:recalculate, state) do
    Process.send_after(self(), :recalculate, 250)
    {:noreply, recalculate(state)}
  end

  @impl true
  def handle_cast({:pressure, source, value}, state),
    do: {:noreply, state |> put_in([:pressures, source], value) |> recalculate()}

  def handle_cast({:health, source, status}, state),
    do: {:noreply, state |> put_in([:health, source], status) |> recalculate()}

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:sensitive_commit_allowed?, _from, state) do
    allowed =
      state.mode in [:normal, :constrained] and state.health.store == :healthy and
        state.health.semantic == :healthy

    {:reply, allowed, state}
  end

  def handle_call({:admit?, class}, _from, state) do
    rank = Policy.class_rank(class)

    allowed =
      case state.mode do
        :normal -> true
        :constrained -> rank <= 2
        :read_only_autonomy -> rank == 0
        :no_sensitive_commits -> rank <= 2
        :admission_closed -> false
      end

    {:reply, allowed, state}
  end

  defp recalculate(state) do
    pressure = state.pressures |> Map.values() |> Enum.max(fn -> 0.0 end)

    target = target_mode(state.health, pressure)

    {mode, candidate, count} =
      hysteresis(state.mode, state.candidate, state.candidate_count, target)

    %{
      state
      | mode: mode,
        candidate: candidate,
        candidate_count: count,
        updated_at: System.monotonic_time(:millisecond)
    }
  end

  defp target_mode(health, pressure) do
    cond do
      health.store == :unavailable -> :no_sensitive_commits
      health.launcher == :unavailable -> :admission_closed
      pressure >= 0.95 -> :admission_closed
      health.semantic == :unavailable -> :no_sensitive_commits
      pressure >= 0.85 -> :no_sensitive_commits
      pressure >= 0.72 -> :read_only_autonomy
      constrained?(health, pressure) -> :constrained
      true -> :normal
    end
  end

  defp constrained?(health, pressure), do: health.semantic == :degraded or pressure >= 0.52

  # Degradation takes effect immediately; recovery requires three consecutive recalculations.
  defp hysteresis(current, _candidate, _count, target) when target == current,
    do: {current, current, 0}

  defp hysteresis(current, candidate, count, target) do
    if severity(target) > severity(current) do
      {target, target, 0}
    else
      next_count = if candidate == target, do: count + 1, else: 1
      if next_count >= 3, do: {target, target, 0}, else: {current, target, next_count}
    end
  end

  defp severity(:normal), do: 0
  defp severity(:constrained), do: 1
  defp severity(:read_only_autonomy), do: 2
  defp severity(:no_sensitive_commits), do: 3
  defp severity(:admission_closed), do: 4

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
