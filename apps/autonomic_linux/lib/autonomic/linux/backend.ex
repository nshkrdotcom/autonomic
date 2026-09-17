defmodule Autonomic.Linux.Backend do
  @moduledoc "Real Linux namespace/cgroup/seccomp/overlay backend through the external launcher."
  @behaviour Autonomic.ExecutionDomain

  alias Autonomic.{Canonical, ExecutionDomain, Runtime, SensorArray}
  alias Autonomic.Linux.Launcher

  @impl true
  def create(%ExecutionDomain.Spec{} = spec) do
    fields = %{
      "episode_id" => spec.episode_id,
      "epoch" => spec.epoch,
      "workspace" => plain(spec.workspace),
      "hard_envelope" => plain(spec.hard_envelope),
      "resource_limits" => plain(spec.resource_limits || %{}),
      "environment" => plain(spec.environment || %{}),
      "effect_socket" => spec.effect_socket,
      "rootfs" => rootfs(),
      "state_root" => state_root()
    }

    with {:ok, result} <- Launcher.request("create_domain", fields, 90_000) do
      {:ok, domain_from_result(spec.episode_id, spec.epoch, result)}
    end
  end

  @impl true
  def exec(%ExecutionDomain.Domain{} = domain, %ExecutionDomain.Command{} = command) do
    with :ok <- current?(domain),
         :ok <- validate_and_observe(domain, command),
         {:ok, result} <- Launcher.request("exec", %{
           "domain_id" => domain.id,
           "episode_id" => domain.episode_id,
           "epoch" => domain.epoch,
           "argv" => command.argv,
           "cwd" => command.cwd || "/workspace",
           "env" => command.env,
           "stdin_b64" => if(is_binary(command.stdin), do: Base.encode64(command.stdin), else: nil),
           "timeout_ms" => command.timeout_ms,
           "state_root" => state_root()
         }, command.timeout_ms + 10_000) do
      execution = %ExecutionDomain.Execution{
        id: Map.get(result, "execution_id", Canonical.id()),
        domain_id: domain.id,
        os_pid: result["pid"],
        started_at: result["started_at_ms"] || Canonical.now(),
        exit_status: result["exit_status"],
        metadata: %{
          stdout: result["stdout"],
          stderr: result["stderr"],
          stdout_truncated: result["stdout_truncated"],
          stderr_truncated: result["stderr_truncated"],
          termination_signal: result["termination_signal"],
          seccomp_violation: result["seccomp_violation"] == true
        }
      }

      maybe_observe_execution(domain, execution)
      {:ok, execution}
    end
  end

  @impl true
  def signal(domain, signal) do
    with :ok <- current?(domain),
         {:ok, _} <- Launcher.request("signal", identity(domain) |> Map.put("signal", to_string(signal))) do
      :ok
    end
  end

  def freeze(domain), do: lifecycle(domain, "freeze")
  def thaw(domain), do: lifecycle(domain, "thaw")

  @impl true
  def checkpoint(domain) do
    with :ok <- current?(domain),
         {:ok, result} <- Launcher.request("checkpoint_fs", identity(domain), 120_000) do
      {:ok, %ExecutionDomain.CheckpointRef{
        ref: result["checkpoint_ref"],
        episode_id: domain.episode_id,
        epoch: domain.epoch,
        domain_generation: domain.generation,
        digest: result["digest"],
        metadata: %{backend: __MODULE__, rootfs: rootfs(), workspace_lower: result["workspace_lower"], effect_socket: result["effect_socket"] || domain.metadata[:effect_socket], resource_limits: result["resource_limits"], state_root: state_root(), environment_digest: result["environment_digest"]}
      }}
    end
  end

  @impl true
  def restore(%ExecutionDomain.CheckpointRef{} = checkpoint) do
    with {:ok, epoch} <- Runtime.store().current_epoch(checkpoint.episode_id),
         true <- epoch > checkpoint.epoch,
         {:ok, result} <- Launcher.request("restore_domain", %{
           "episode_id" => checkpoint.episode_id,
           "epoch" => epoch,
           "checkpoint_ref" => checkpoint.ref,
           "checkpoint_digest" => checkpoint.digest,
           "rootfs" => Map.get(checkpoint.metadata, :rootfs) || rootfs(),
           "workspace_lower" => Map.get(checkpoint.metadata, :workspace_lower) || Map.get(checkpoint.metadata, "workspace_lower"),
           "effect_socket" => Map.get(checkpoint.metadata, :effect_socket) || Map.get(checkpoint.metadata, "effect_socket") || Path.join([Runtime.root(), "sockets", checkpoint.episode_id <> ".sock"]),
           "resource_limits" => Map.get(checkpoint.metadata, :resource_limits) || Map.get(checkpoint.metadata, "resource_limits") || %{},
           "state_root" => state_root()
         }, 120_000) do
      {:ok, domain_from_result(checkpoint.episode_id, epoch, result)}
    else
      false -> {:error, :restore_requires_newer_epoch}
      {:error, _} = error -> error
    end
  end

  @impl true
  def destroy(domain) do
    case Launcher.request("destroy_domain", identity(domain), 90_000) do
      {:ok, result} ->
        if result["empty"] == true, do: {:ok, atomize_evidence(result)}, else: {:error, {:destruction_not_proven, result}}
      error -> error
    end
  end

  @impl true
  def inspect_domain(domain), do: Launcher.request("inspect_domain", identity(domain))

  defp lifecycle(domain, action) do
    with :ok <- current?(domain), {:ok, _} <- Launcher.request(action, identity(domain)) do
      :ok
    end
  end

  defp current?(domain) do
    case Runtime.store().current_epoch(domain.episode_id) do
      {:ok, epoch} when epoch == domain.epoch -> :ok
      {:ok, _} -> {:error, :stale_authority}
      {:error, _} = error -> error
    end
  end

  defp validate_and_observe(domain, %ExecutionDomain.Command{} = command) do
    case validate_command(command) do
      :ok ->
        :ok

      {:error, {:deterministic_boundary_violation, fact}} = error ->
        publish_hard_fact(domain, fact)
        error

      {:error, _} = error ->
        error
    end
  end

  defp validate_command(%ExecutionDomain.Command{argv: argv, env: env}) do
    cond do
      not is_list(argv) or argv == [] or Enum.any?(argv, &(not is_binary(&1) or byte_size(&1) > 16_384)) ->
        {:error, :invalid_argv}

      map_size(env) > 128 ->
        {:error, :too_many_env_vars}

      Enum.any?(env, fn {k, v} ->
        not is_binary(k) or not is_binary(v) or byte_size(k) + byte_size(v) > 32_768
      end) ->
        {:error, :invalid_environment}

      forbidden_host_path_attempt?(argv) ->
        {:error,
         {:deterministic_boundary_violation,
          %{type: :forbidden_path_attempt, source: :execution_domain, severity: :critical}}}

      true ->
        :ok
    end
  end

  @forbidden_host_path_markers [
    "/root/.env",
    "~/.env",
    "/home/",
    "/root/.ssh",
    "/.aws/",
    "/.config/gcloud",
    "/var/run/docker.sock",
    "/run/docker.sock",
    "/proc/1/root",
    "/host/"
  ]

  defp forbidden_host_path_attempt?(argv) do
    Enum.any?(argv, fn arg ->
      Enum.any?(@forbidden_host_path_markers, &String.contains?(arg, &1))
    end)
  end

  defp maybe_observe_execution(domain, %ExecutionDomain.Execution{metadata: %{seccomp_violation: true}} = execution) do
    publish_hard_fact(domain, %{
      type: :seccomp_violation,
      source: :linux_launcher,
      severity: :critical,
      termination_signal: execution.metadata.termination_signal
    })
  end

  defp maybe_observe_execution(_domain, _execution), do: :ok

  defp publish_hard_fact(domain, fact) do
    frame = %Autonomic.ObservationFrame{
      episode_id: domain.episode_id,
      epoch: domain.epoch,
      sequence: System.unique_integer([:positive, :monotonic]),
      observed_at: Canonical.now(),
      deterministic: [fact],
      semantic: [],
      resource: %{}
    }

    case Registry.lookup(Autonomic.Registry, {domain.episode_id, :sensor_array}) do
      [{_pid, _}] -> SensorArray.publish(domain.episode_id, frame, :critical)
      [] -> :ok
    end
  end

  defp domain_from_result(episode_id, epoch, result) do
    %ExecutionDomain.Domain{
      id: result["domain_id"],
      episode_id: episode_id,
      epoch: epoch,
      generation: result["generation"],
      backend: __MODULE__,
      os_ref: result["keeper_pid"],
      metadata: %{cgroup: result["cgroup"], workspace_lower: result["workspace_lower"], git_base_ref: result["git_base_ref"], effect_socket: result["effect_socket"], resource_limits: result["resource_limits"], destruction_proof_required: true}
    }
  end

  defp identity(domain), do: %{"domain_id" => domain.id, "episode_id" => domain.episode_id, "epoch" => domain.epoch, "state_root" => state_root()}
  defp rootfs, do: Application.get_env(:autonomic_linux, :rootfs, "/var/lib/autonomic/rootfs")
  defp state_root, do: Application.get_env(:autonomic_linux, :state_root, "/var/lib/autonomic")
  defp plain(value), do: Jason.decode!(Jason.encode!(value))
  defp atomize_evidence(result), do: %{empty: result["empty"], killed: result["killed"], cgroup_removed: result["cgroup_removed"], domain_id: result["domain_id"]}
end
