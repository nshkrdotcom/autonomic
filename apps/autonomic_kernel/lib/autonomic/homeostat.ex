defmodule Autonomic.Homeostat do
  @moduledoc "Per-episode trajectory regulator with deny-dominant hard-violation handling and hysteresis."
  use GenServer

  alias Autonomic.{HomeostaticState, ObservationFrame, Runtime, SemanticObservation}

  @hard_violations MapSet.new([
                     :direct_network_attempt,
                     :forbidden_path_attempt,
                     :forbidden_mount_attempt,
                     :stale_epoch_request,
                     :capability_misuse,
                     :cgroup_escape,
                     :forbidden_credential_access,
                     :namespace_escape,
                     :seccomp_violation
                   ])
  @alpha 0.28
  @stable_frames_required 3

  def start_link(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    GenServer.start_link(__MODULE__, opts, name: Runtime.via(episode_id, :homeostat))
  end

  def observe(episode_id, %ObservationFrame{} = frame),
    do: GenServer.call(Runtime.via(episode_id, :homeostat), {:observe, frame}, 15_000)

  def snapshot(episode_id), do: GenServer.call(Runtime.via(episode_id, :homeostat), :snapshot)

  def repair_recorded(episode_id), do: GenServer.cast(Runtime.via(episode_id, :homeostat), :repair)
  def rebase_epoch(episode_id, epoch), do: GenServer.call(Runtime.via(episode_id, :homeostat), {:rebase_epoch, epoch})

  @impl true
  def init(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    epoch = Keyword.fetch!(opts, :epoch)
    now = System.system_time(:millisecond)

    state = %HomeostaticState{
      episode_id: episode_id,
      epoch: epoch,
      trajectory_version: 0,
      regime: :stable,
      regime_entered_at: now,
      metadata: %{stable_frames: 0}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:rebase_epoch, epoch}, _from, state) when is_integer(epoch) and epoch > state.epoch do
    next = %{state | epoch: epoch, trajectory_version: 0, regime: :stable, drift: 0.0, volatility: 0.0, uncertainty: 0.0, deterministic_violations: [], semantic_sensor_health: :healthy, regime_entered_at: System.system_time(:millisecond), metadata: %{stable_frames: 0}}
    {:reply, :ok, next}
  end

  def handle_call({:rebase_epoch, _epoch}, _from, state), do: {:reply, {:error, :non_monotonic_epoch}, state}

  def handle_call({:observe, %ObservationFrame{} = frame}, _from, state) do
    result = ingest(state, frame)
    {next, signal} = result

    _ = persist(frame, next)
    notify_controller(next.episode_id, signal)
    {:reply, {:ok, signal, next}, next}
  end

  @impl true
  def handle_cast(:repair, state) do
    next = %{state | repair_count: state.repair_count + 1, trajectory_version: state.trajectory_version + 1}
    {:noreply, next}
  end

  defp ingest(state, frame) do
    if frame.epoch != state.epoch do
      hard = %{type: :stale_epoch_request, frame_epoch: frame.epoch, current_epoch: state.epoch}
      next = hard_containment(state, [hard])
      {next, {:homeostat, :contain, :stale_epoch_observation, %{deterministic: [hard]}}}
    else
      hard = hard_violations(frame.deterministic)
      semantic = semantic_vector(frame.semantic)
      degraded? = semantic_degraded?(frame)

      next =
        state
        |> update_smoothed(semantic, frame)
        |> update_sensor_health(degraded?)
        |> Map.update!(:trajectory_version, &(&1 + 1))

      if hard != [] do
        contained = hard_containment(next, hard)
        {contained, {:homeostat, :contain, :deterministic_boundary_violation, %{deterministic: hard}}}
      else
        next = update_regime(next)
        {next, output(next, frame)}
      end
    end
  end

  defp hard_violations(facts) do
    Enum.filter(facts, fn fact ->
      type = Map.get(fact, :type) || Map.get(fact, "type") || Map.get(fact, :kind) || Map.get(fact, "kind")
      normalize_atom(type) in @hard_violations
    end)
  end

  defp update_smoothed(state, semantic, frame) do
    scope = Map.get(semantic, :scope_drift, 0.0)
    authority = Map.get(semantic, :authority_escalation, 0.0)
    destructive = Map.get(semantic, :irreversibility, 0.0)
    uncertainty = Map.get(semantic, :uncertainty, if(frame.semantic == [], do: 1.0, else: 0.0))

    previous = state.drift
    drift = ewma(previous, max(scope, Map.get(semantic, :regime_risk, 0.0)))
    volatility = ewma(state.volatility, abs(drift - previous))

    %{
      state
      | drift: drift,
        volatility: volatility,
        uncertainty: ewma(state.uncertainty, uncertainty),
        scope_pressure: ewma(state.scope_pressure, scope),
        authority_pressure: ewma(state.authority_pressure, authority),
        destructive_pressure: ewma(state.destructive_pressure, destructive),
        verification_pressure: ewma(state.verification_pressure, pressure(frame, :verification_pressure)),
        approval_pressure: ewma(state.approval_pressure, pressure(frame, :approval_pressure)),
        blast_radius_remaining:
          min(state.blast_radius_remaining, max(0.0, state.blast_radius_remaining - destructive * 0.05)),
        autonomy_balance:
          min(state.autonomy_balance, max(0.0, state.autonomy_balance - max(scope, authority) * 0.04))
    }
  end

  defp update_sensor_health(state, true), do: %{state | semantic_sensor_health: :degraded, uncertainty: max(state.uncertainty, 0.65)}
  defp update_sensor_health(state, false), do: %{state | semantic_sensor_health: :healthy}

  defp update_regime(state) do
    risk = Enum.max([state.drift, state.uncertainty, state.authority_pressure, state.destructive_pressure, state.volatility])

    candidate =
      cond do
        risk >= 0.82 -> :unstable
        max(state.drift, state.authority_pressure) >= 0.58 -> :drifting
        state.uncertainty >= 0.42 or state.semantic_sensor_health != :healthy -> :uncertain
        true -> :stable
      end

    stable_frames = Map.get(state.metadata, :stable_frames, 0)

    {regime, stable_frames} =
      cond do
        state.regime == :containment -> {:containment, stable_frames}
        candidate == :stable and state.regime in [:drifting, :unstable] and stable_frames + 1 < @stable_frames_required -> {state.regime, stable_frames + 1}
        candidate == :stable -> {:stable, min(stable_frames + 1, @stable_frames_required)}
        true -> {candidate, 0}
      end

    entered_at = if regime == state.regime, do: state.regime_entered_at, else: System.system_time(:millisecond)
    %{state | regime: regime, regime_entered_at: entered_at, metadata: Map.put(state.metadata, :stable_frames, stable_frames)}
  end

  defp hard_containment(state, hard) do
    %{
      state
      | regime: :containment,
        deterministic_violations: Enum.take(hard ++ state.deterministic_violations, 32),
        regime_entered_at: System.system_time(:millisecond),
        autonomy_balance: 0.0
    }
  end

  defp output(%{regime: :unstable} = state, _frame) do
    {:homeostat, :preempt,
     {:semantic_exit, :trajectory_violation,
      %{trajectory_version: state.trajectory_version, regime: state.regime}}}
  end

  defp output(%{regime: :drifting} = state, _frame) do
    {:homeostat, :narrow,
     %{max_effect_class: :class_1_isolated_mutable},
     %{trajectory_version: state.trajectory_version, drift: state.drift}}
  end

  defp output(%{regime: :uncertain} = state, _frame) do
    {:homeostat, :yield, :insufficient_semantic_evidence,
     %{trajectory_version: state.trajectory_version, uncertainty: state.uncertainty}}
  end

  defp output(state, _frame), do: {:homeostat, :continue, %{trajectory_version: state.trajectory_version}}

  defp semantic_vector(observations) do
    Enum.reduce(observations, %{}, fn %SemanticObservation{} = observation, acc ->
      risk = semantic_risk(observation)

      case observation.sensor do
        :scope_drift -> Map.put(acc, :scope_drift, risk)
        :authority_escalation -> Map.put(acc, :authority_escalation, risk)
        :irreversibility -> Map.put(acc, :irreversibility, risk)
        :effect_class -> Map.put(acc, :irreversibility, risk)
        :evidence_sufficiency -> Map.put(acc, :uncertainty, evidence_uncertainty(observation, risk))
        :trajectory_regime -> Map.put(acc, :regime_risk, regime_risk(observation.value))
        :regime -> Map.put(acc, :regime_risk, regime_risk(observation.value))
        _ -> acc
      end
    end)
  end

  defp evidence_uncertainty(%SemanticObservation{metadata: metadata, value: value}, fallback_risk) do
    normalized = Map.get(metadata || %{}, :normalized, Map.get(metadata || %{}, "normalized"))

    cond do
      is_number(normalized) -> 1.0 - clamp(normalized * 1.0)
      value in [:sufficient, "Sufficient", "sufficient"] -> 0.0
      value in [:partial, "Partial", "partial"] -> 0.5
      value in [:insufficient, "Insufficient", "insufficient"] -> 1.0
      true -> 1.0 - fallback_risk
    end
  end

  defp semantic_risk(%SemanticObservation{value: value, confidence: confidence}) do
    base =
      cond do
        is_boolean(value) -> if(value, do: 1.0, else: 0.0)
        is_number(value) -> clamp(value * 1.0)
        value in [:high, :authoritative, :high_impact, :unstable] -> 1.0
        value in [:medium, :external, :drifting] -> 0.65
        value in [:low, :local, :stable] -> 0.0
        true -> 0.5
      end

    case confidence do
      c when is_number(c) -> clamp(base * c + 0.5 * (1.0 - c))
      _ -> base
    end
  end

  defp regime_risk(:stable), do: 0.0
  defp regime_risk("stable"), do: 0.0
  defp regime_risk(:uncertain), do: 0.45
  defp regime_risk("uncertain"), do: 0.45
  defp regime_risk(:drifting), do: 0.7
  defp regime_risk("drifting"), do: 0.7
  defp regime_risk(:unstable), do: 1.0
  defp regime_risk("unstable"), do: 1.0
  defp regime_risk(_), do: 0.5

  defp semantic_degraded?(frame) do
    frame.semantic == [] or
      Enum.any?(frame.semantic, fn observation ->
        Map.get(observation.metadata, :degraded, false) or is_nil(observation.confidence)
      end)
  end

  defp pressure(frame, key) do
    value = Map.get(frame.resource, key, Map.get(frame.resource, to_string(key), 0.0))
    if is_number(value), do: clamp(value * 1.0), else: 0.0
  end

  defp persist(frame, state) do
    store = Runtime.store()
    _ = if function_exported?(store, :record_observation, 1), do: store.record_observation(frame), else: :ok
    _ = if function_exported?(store, :update_trajectory, 2), do: store.update_trajectory(frame.episode_id, state), else: :ok
    :ok
  end

  defp notify_controller(episode_id, signal) do
    case Registry.lookup(Autonomic.Registry, {episode_id, :controller}) do
      [{pid, _}] -> :gen_statem.cast(pid, signal)
      [] -> :ok
    end
  end

  defp ewma(old, sample), do: clamp((1.0 - @alpha) * old + @alpha * sample)
  defp clamp(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom(value) when is_binary(value) do
    case value do
      "direct_network_attempt" -> :direct_network_attempt
      "forbidden_path_attempt" -> :forbidden_path_attempt
      "forbidden_mount_attempt" -> :forbidden_mount_attempt
      "stale_epoch_request" -> :stale_epoch_request
      "capability_misuse" -> :capability_misuse
      "cgroup_escape" -> :cgroup_escape
      "forbidden_credential_access" -> :forbidden_credential_access
      "namespace_escape" -> :namespace_escape
      "seccomp_violation" -> :seccomp_violation
      _ -> :unknown
    end
  end
  defp normalize_atom(_), do: :unknown
end
