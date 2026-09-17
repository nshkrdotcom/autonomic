defmodule Autonomic.EpisodeController do
  @moduledoc "Durable episode lifecycle state machine coordinating sandbox creation, preemption, repair, and completion."
  @behaviour :gen_statem

  alias Autonomic.{AuthorityGovernor, Canonical, EffectSocket, ExecutionDomain, RepairManager, Runtime, SnapshotManager}

  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)
    :gen_statem.start_link(Runtime.via(spec.id, :controller), __MODULE__, opts, [])
  end

  def state(episode_id), do: :gen_statem.call(Runtime.via(episode_id, :controller), :state)

  @doc false
  def trusted_runtime(episode_id), do: :gen_statem.call(Runtime.via(episode_id, :controller), :trusted_runtime)

  def complete(episode_id), do: :gen_statem.cast(Runtime.via(episode_id, :controller), :complete)
  def resume(episode_id), do: :gen_statem.cast(Runtime.via(episode_id, :controller), :resume)
  def contain(episode_id, reason), do: :gen_statem.cast(Runtime.via(episode_id, :controller), {:contain, reason})

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(opts) do
    spec = Keyword.fetch!(opts, :spec)
    {:ok, episode} = Runtime.store().fetch_episode(spec.id)
    epoch = episode.current_epoch
    recovered_domain = reconstruct_domain(episode)
    data = %{spec: spec, episode_id: spec.id, epoch: epoch, domain: recovered_domain, lease: nil, checkpoint: nil, repairs: 0, last_signal: nil, worker_ref: nil}

    action =
      if recovered_domain && episode.state not in [:completed, :contained, :failed] do
        {:next_event, :internal, {:recover_controller, recovered_domain}}
      else
        {:next_event, :internal, :bootstrap}
      end

    {:ok, :bootstrapping, data, [action]}
  end

  def bootstrapping(:internal, :bootstrap, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :bootstrapping)

    with {:ok, socket} <- effect_socket(data.episode_id),
         {:ok, domain} <- Runtime.domain().create(domain_spec(data.spec, data.epoch, socket)),
         :ok <- Runtime.store().set_episode_domain(data.episode_id, domain),
         {:ok, lease} <- issue_initial_lease(data),
         {:ok, checkpoint} <- SnapshotManager.capture(data.episode_id, domain, reason: :bootstrap, trust_level: :stable, git_base_ref: workspace_base(data.spec.workspace)),
         :ok <- Runtime.store().set_episode_state(data.episode_id, :running) do
      next = %{data | domain: domain, lease: lease, checkpoint: checkpoint}
      {:next_state, :running, next, [{:next_event, :internal, :launch_worker}]}
    else
      {:error, reason} -> fail(data, {:bootstrap_failed, reason})
      other -> fail(data, {:bootstrap_failed, other})
    end
  end
  def bootstrapping(:internal, {:recover_controller, old_domain}, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :repairing, %{reason: :controller_restart})

    with {:ok, result} <- RepairManager.repair(data.episode_id, old_domain, data.spec, :controller_restart, %{deterministic: [%{type: :controller_restart}]}),
         :ok <- Runtime.store().set_episode_domain(data.episode_id, result.domain),
         :ok <- Runtime.store().set_episode_state(data.episode_id, :running, %{recovery_id: result.recovery_id}) do
      next = %{data | epoch: result.domain.epoch, domain: result.domain, lease: result.lease, checkpoint: result.checkpoint, repairs: data.repairs + 1, last_signal: nil}
      {:next_state, :running, next, [{:next_event, :internal, :launch_worker}]}
    else
      {:error, reason} -> fail(data, {:controller_recovery_failed, reason})
      other -> fail(data, {:controller_recovery_failed, other})
    end
  end

  def bootstrapping({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:bootstrapping, public(data)}}]}
  def bootstrapping(_type, _event, _data), do: :keep_state_and_data

  def running(:internal, :launch_worker, data) do
    case start_worker(data) do
      {:ok, ref} -> {:keep_state, %{data | worker_ref: ref}}
      :disabled -> :keep_state_and_data
      {:error, reason} -> {:next_state, :preempting, %{data | last_signal: {:worker_start_failed, reason}}, [{:next_event, :internal, {:repair, :environment_mismatch, %{worker_start_failed: inspect(reason)}}}]}
    end
  end

  def running({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:running, public(data)}}]}
  def running({:call, from}, :trusted_runtime, data), do: {:keep_state_and_data, [{:reply, from, %{domain: data.domain, lease: data.lease, checkpoint: data.checkpoint, epoch: data.epoch}}]}
  def running(:cast, {:homeostat, :continue, _ref}, _data), do: :keep_state_and_data

  def running(:cast, {:homeostat, :narrow, delta, evidence}, data) do
    _ = maybe_narrow(data, delta, evidence)
    {:keep_state, %{data | last_signal: {:narrow, evidence}}}
  end

  def running(:cast, {:homeostat, :yield, reason, evidence}, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :yielding, %{reason: reason, evidence: evidence})
    {:next_state, :yielding, %{data | last_signal: {:yield, reason, evidence}}}
  end

  def running(:cast, {:homeostat, :preempt, {:semantic_exit, reason, evidence}}, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :preempting, %{reason: reason})
    {:next_state, :preempting, %{data | last_signal: {reason, evidence}}, [{:next_event, :internal, {:repair, reason, evidence}}]}
  end

  def running(:cast, {:homeostat, :contain, reason, evidence}, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :preempting, %{reason: reason})
    {:next_state, :preempting, %{data | last_signal: {reason, evidence}}, [{:next_event, :internal, {:repair, reason, evidence}}]}
  end

  def running(:cast, {:contain, reason}, data) do
    {:next_state, :containing, %{data | last_signal: {:operator_contain, reason}}, [{:next_event, :internal, {:contain, reason}}]}
  end

  def running(:cast, :complete, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :completing)
    {:next_state, :completing, data, [{:next_event, :internal, :finalize}]}
  end

  def running(:info, {:worker_exit, status}, data) do
    if privileged_in_flight?(data.episode_id) do
      {:next_state, :preempting, data, [{:next_event, :internal, {:repair, :environment_mismatch, %{worker_exit: status}}}]}
    else
      _ = Runtime.store().append_event(data.episode_id, :worker_exit, %{status: status})
      :keep_state_and_data
    end
  end
  def running(_type, _event, _data), do: :keep_state_and_data

  def yielding({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:yielding, public(data)}}]}
  def yielding(:cast, :resume, data) do
    _ = Runtime.store().set_episode_state(data.episode_id, :running)
    {:next_state, :running, %{data | last_signal: nil}}
  end
  def yielding(:cast, {:homeostat, :preempt, {:semantic_exit, reason, evidence}}, data),
    do: {:next_state, :preempting, data, [{:next_event, :internal, {:repair, reason, evidence}}]}
  def yielding(:cast, {:contain, reason}, data), do: {:next_state, :containing, data, [{:next_event, :internal, {:contain, reason}}]}
  def yielding(_type, _event, _data), do: :keep_state_and_data

  def preempting(:internal, {:repair, reason, evidence}, data) do
    max_repairs = Application.get_env(:autonomic_kernel, :max_repairs, 3)

    if data.repairs >= max_repairs do
      {:next_state, :containing, data, [{:next_event, :internal, {:contain, :repair_budget_exhausted}}]}
    else
      _ = Runtime.store().set_episode_state(data.episode_id, :repairing, %{reason: reason})
      {:next_state, :repairing, data, [{:next_event, :internal, {:repair, reason, evidence}}]}
    end
  end
  def preempting({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:preempting, public(data)}}]}
  def preempting(_type, _event, _data), do: :keep_state_and_data

  def repairing(:internal, {:repair, reason, evidence}, data) do
    with {:ok, result} <- RepairManager.repair(data.episode_id, data.domain, data.spec, reason, evidence),
         :ok <- Runtime.store().set_episode_domain(data.episode_id, result.domain),
         :ok <- Runtime.store().set_episode_state(data.episode_id, :running, %{recovery_id: result.recovery_id}) do
      next = %{data | epoch: result.domain.epoch, domain: result.domain, lease: result.lease, checkpoint: result.checkpoint, repairs: data.repairs + 1, last_signal: nil, worker_ref: nil}
      {:next_state, :running, next, [{:next_event, :internal, :launch_worker}]}
    else
      {:error, reason} -> {:next_state, :containing, data, [{:next_event, :internal, {:contain, {:repair_failed, reason}}}]}
    end
  end
  def repairing({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:repairing, public(data)}}]}
  def repairing(_type, _event, _data), do: :keep_state_and_data

  def containing(:internal, {:contain, reason}, data) do
    _ = ensure_epoch_fence(data, reason)
    destroy = if data.domain, do: data.domain.backend.destroy(data.domain), else: :ok

    case destroy do
      :ok ->
        _ = Runtime.store().set_episode_domain(data.episode_id, nil)
        _ = Runtime.store().set_episode_state(data.episode_id, :contained, %{reason: inspect(reason), destruction_proven: true})
        {:next_state, :contained, %{data | domain: nil, lease: nil, last_signal: reason}}
      {:ok, evidence} when is_map(evidence) ->
        if Map.get(evidence, :empty, Map.get(evidence, "empty", false)) do
          _ = Runtime.store().set_episode_domain(data.episode_id, nil)
          _ = Runtime.store().set_episode_state(data.episode_id, :contained, %{reason: inspect(reason), destruction: evidence})
          {:next_state, :contained, %{data | domain: nil, lease: nil, last_signal: reason}}
        else
          fail(data, {:destruction_not_proven, evidence})
        end
      {:error, destroy_reason} -> fail(data, {:containment_failed, destroy_reason})
    end
  end
  def containing({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:containing, public(data)}}]}
  def containing(_type, _event, _data), do: :keep_state_and_data

  def contained({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:contained, public(data)}}]}
  def contained(_type, _event, _data), do: :keep_state_and_data

  def completing(:internal, :finalize, data) do
    with false <- privileged_in_flight?(data.episode_id),
         :ok <- destroy_for_completion(data.domain),
         :ok <- Runtime.store().set_episode_domain(data.episode_id, nil),
         :ok <- Runtime.store().set_episode_state(data.episode_id, :completed, %{completed_at: Canonical.now()}) do
      {:next_state, :completed, %{data | domain: nil, lease: nil}}
    else
      true -> {:next_state, :yielding, %{data | last_signal: :pending_privileged_effects}}
      {:error, reason} -> fail(data, {:completion_failed, reason})
    end
  end
  def completing({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:completing, public(data)}}]}
  def completing(_type, _event, _data), do: :keep_state_and_data

  def completed({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:completed, public(data)}}]}
  def completed(_type, _event, _data), do: :keep_state_and_data

  def failed({:call, from}, :state, data), do: {:keep_state_and_data, [{:reply, from, {:failed, public(data)}}]}
  def failed(_type, _event, _data), do: :keep_state_and_data

  defp issue_initial_lease(data) do
    capabilities = Map.get(data.spec.hard_envelope, "capabilities", Map.get(data.spec.hard_envelope, :capabilities, []))
    ceiling = data.spec.requested_effect_ceiling || Map.get(data.spec.hard_envelope, "max_effect_class", :class_1_isolated_mutable)

    AuthorityGovernor.issue(data.episode_id, %{
      authority_source: :signed_policy,
      capabilities: capabilities,
      max_effect_class: ceiling,
      ttl_ms: 60_000,
      reason: "episode bootstrap"
    })
  end

  defp maybe_narrow(%{lease: nil}, _delta, _evidence), do: :ok
  defp maybe_narrow(data, delta, evidence) do
    max_class = Map.get(delta, :max_effect_class, :class_1_isolated_mutable)
    capabilities = data.lease.capabilities
    _ = AuthorityGovernor.revoke(data.episode_id, data.lease.id, :homeostat_narrowing)
    AuthorityGovernor.issue(data.episode_id, %{authority_source: :signed_policy, capabilities: capabilities, max_effect_class: max_class, ttl_ms: 20_000, reason: "homeostat narrowing", metadata: %{evidence: evidence}})
  end

  defp effect_socket(episode_id) do
    try do
      {:ok, EffectSocket.path(episode_id)}
    catch
      :exit, reason -> {:error, {:effect_socket_unavailable, reason}}
    end
  end

  defp domain_spec(spec, epoch, socket) do
    %ExecutionDomain.Spec{
      episode_id: spec.id,
      epoch: epoch,
      workspace: spec.workspace,
      hard_envelope: spec.hard_envelope,
      resource_limits: spec.resource_limits || %{},
      environment: spec.environment || %{},
      effect_socket: socket,
      metadata: %{origin_intent_digest: Canonical.digest(spec.origin_intent), worker_argv: spec.worker_argv || []}
    }
  end

  defp ensure_epoch_fence(data, reason) do
    case Runtime.store().current_epoch(data.episode_id) do
      {:ok, epoch} when epoch == data.epoch -> AuthorityGovernor.advance_epoch(data.episode_id, {:contain, reason})
      {:ok, _newer} -> :ok
      error -> error
    end
  end

  defp privileged_in_flight?(episode_id) do
    case Runtime.store().list_effects(episode_id, [:commit_intent, :committing, :commit_unknown]) do
      {:ok, []} -> false
      {:ok, _} -> true
      _ -> true
    end
  end

  defp destroy_for_completion(nil), do: :ok
  defp destroy_for_completion(domain) do
    case domain.backend.destroy(domain) do
      :ok -> :ok
      {:ok, evidence} -> if(Map.get(evidence, :empty, Map.get(evidence, "empty", false)), do: :ok, else: {:error, :domain_not_empty})
      {:error, _} = error -> error
    end
  end

  defp workspace_base(workspace), do: Map.get(workspace, "base_ref") || Map.get(workspace, :base_ref)
  defp resource_limit(limits, key, default), do: Map.get(limits, key, Map.get(limits, to_string(key), default))

  defp fail(data, reason) do
    _ = Runtime.store().set_episode_state(data.episode_id, :failed, %{reason: inspect(reason)})
    {:next_state, :failed, %{data | last_signal: reason}}
  end

  defp start_worker(%{spec: %{worker_argv: argv}}) when not is_list(argv) or argv == [], do: :disabled
  defp start_worker(data) do
    controller = self()
    command = %ExecutionDomain.Command{
      argv: data.spec.worker_argv,
      cwd: "/workspace",
      env: data.spec.environment || %{},
      timeout_ms: resource_limit(data.spec.resource_limits || %{}, :worker_timeout_ms, 3_600_000)
    }

    case Task.Supervisor.start_child(Autonomic.Tasks, fn ->
           result = data.domain.backend.exec(data.domain, command)
           status = case result do
             {:ok, execution} -> execution.exit_status
             {:error, reason} -> {:error, reason}
           end
           send(controller, {:worker_exit, status})
         end) do
      {:ok, pid} -> {:ok, Process.monitor(pid)}
      {:error, _} = error -> error
    end
  end

  defp reconstruct_domain(%{domain_ref: ref} = episode) when is_binary(ref) do
    os_ref =
      case Integer.parse(to_string(episode.domain_os_ref || "")) do
        {value, ""} -> value
        _ -> episode.domain_os_ref
      end

    %ExecutionDomain.Domain{
      id: ref,
      episode_id: episode.id,
      epoch: episode.current_epoch,
      generation: episode.domain_generation || 0,
      backend: Runtime.domain(),
      os_ref: os_ref,
      metadata: episode.domain_metadata || %{}
    }
  end

  defp reconstruct_domain(_), do: nil

  defp public(data), do: Map.take(data, [:episode_id, :epoch, :lease, :checkpoint, :repairs, :last_signal]) |> Map.put(:domain, if(data.domain, do: %{id: data.domain.id, epoch: data.domain.epoch, generation: data.domain.generation}, else: nil))
end
