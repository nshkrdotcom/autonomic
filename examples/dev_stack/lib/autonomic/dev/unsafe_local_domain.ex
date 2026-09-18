defmodule Autonomic.Dev.UnsafeLocalDomain do
  @moduledoc """
  Deliberately unsafe local execution backend for examples.

  It provides no user/mount/PID/network namespaces, cgroups, seccomp, or secret boundary.
  It exists only to exercise kernel-plane authority/effect semantics on a laptop.
  """
  @behaviour Autonomic.ExecutionDomain
  require Logger

  alias Autonomic.{Canonical, ExecutionDomain}

  @impl true
  def create(%ExecutionDomain.Spec{} = spec) do
    warn_once()
    root = domain_root(spec.episode_id, spec.epoch, 1)
    File.rm_rf(root)
    File.mkdir_p!(root)
    copy_workspace(spec.workspace, root)

    {:ok,
     %ExecutionDomain.Domain{
       id: "unsafe-local-#{Canonical.id()}",
       episode_id: spec.episode_id,
       epoch: spec.epoch,
       generation: 1,
       backend: __MODULE__,
       os_ref: nil,
       metadata: %{workspace_path: root, trust: :unsafe_local, git_base_ref: workspace_base(spec.workspace)}
     }}
  rescue
    error -> {:error, {:unsafe_local_create_failed, error}}
  end

  @impl true
  def exec(%ExecutionDomain.Domain{} = domain, %ExecutionDomain.Command{} = command) do
    with :ok <- current_epoch?(domain),
         :ok <- validate_argv(command.argv),
         :ok <- validate_stdin(command.stdin),
         {:ok, cwd} <- resolve_cwd(domain, command.cwd) do
      [program | args] = command.argv
      started_at = Canonical.now()

      {output, status} =
        System.cmd(program, args,
          cd: cwd,
          env: Enum.map(command.env || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
          stderr_to_stdout: true
        )

      {:ok,
       %ExecutionDomain.Execution{
         id: Canonical.id(),
         domain_id: domain.id,
         started_at: started_at,
         exit_status: status,
         metadata: %{stdout: output, stderr: "", unsafe_local: true}
       }}
    end
  rescue
    error -> {:error, {:unsafe_local_exec_failed, error}}
  end

  @impl true
  def signal(%ExecutionDomain.Domain{} = domain, _signal), do: current_epoch?(domain)

  @impl true
  def checkpoint(%ExecutionDomain.Domain{} = domain) do
    with :ok <- current_epoch?(domain) do
      source = workspace_path(domain)
      destination = checkpoint_root(domain.episode_id, domain.epoch, domain.generation)
      File.rm_rf(destination)
      File.mkdir_p!(Path.dirname(destination))
      {:ok, _} = File.cp_r(source, destination)

      {:ok,
       %ExecutionDomain.CheckpointRef{
         ref: "unsafe-checkpoint-#{Canonical.id()}",
         episode_id: domain.episode_id,
         epoch: domain.epoch,
         domain_generation: domain.generation,
         digest: tree_digest(destination),
         metadata: %{checkpoint_path: destination, unsafe_local: true, environment_digest: Canonical.digest(%{})}
       }}
    end
  rescue
    error -> {:error, {:unsafe_local_checkpoint_failed, error}}
  end

  @impl true
  def restore(%ExecutionDomain.CheckpointRef{} = checkpoint) do
    source = Map.fetch!(checkpoint.metadata, :checkpoint_path)

    with true <- File.dir?(source),
         true <- tree_digest(source) == checkpoint.digest,
         {:ok, epoch} <- Autonomic.Dev.MemoryStore.current_epoch(checkpoint.episode_id) do
      generation = checkpoint.domain_generation + 1
      root = domain_root(checkpoint.episode_id, epoch, generation)
      File.rm_rf(root)
      {:ok, _} = File.cp_r(source, root)

      {:ok,
       %ExecutionDomain.Domain{
         id: "unsafe-local-#{Canonical.id()}",
         episode_id: checkpoint.episode_id,
         epoch: epoch,
         generation: generation,
         backend: __MODULE__,
         os_ref: nil,
         metadata: %{workspace_path: root, restored_from: checkpoint.ref, unsafe_local: true}
       }}
    else
      false -> {:error, :checkpoint_digest_mismatch}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:unsafe_local_restore_failed, error}}
  end

  @impl true
  def destroy(%ExecutionDomain.Domain{} = domain) do
    File.rm_rf(workspace_path(domain))
    {:ok, %{empty: not File.exists?(workspace_path(domain)), unsafe_local: true}}
  end

  @impl true
  def inspect_domain(%ExecutionDomain.Domain{} = domain) do
    with :ok <- current_epoch?(domain) do
      {:ok, %{id: domain.id, epoch: domain.epoch, generation: domain.generation, workspace: workspace_path(domain), unsafe_local: true}}
    end
  end

  defp current_epoch?(domain) do
    case Autonomic.Dev.MemoryStore.current_epoch(domain.episode_id) do
      {:ok, epoch} when epoch == domain.epoch -> :ok
      {:ok, _} -> {:error, :stale_generation}
      {:error, _} = error -> error
    end
  end

  defp validate_argv(argv) when is_list(argv) and argv != [] and length(argv) <= 256 do
    if Enum.all?(argv, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 16_384)), do: :ok, else: {:error, :invalid_argv}
  end
  defp validate_argv(_), do: {:error, :invalid_argv}

  defp validate_stdin(nil), do: :ok
  defp validate_stdin(_), do: {:error, :stdin_not_supported_by_unsafe_example_backend}

  defp resolve_cwd(domain, nil), do: {:ok, workspace_path(domain)}
  defp resolve_cwd(domain, "/workspace"), do: {:ok, workspace_path(domain)}
  defp resolve_cwd(domain, cwd) when is_binary(cwd) do
    base = workspace_path(domain)
    relative = String.trim_leading(cwd, "/workspace/")
    path = Path.expand(relative, base)
    if path == base or String.starts_with?(path, base <> "/"), do: {:ok, path}, else: {:error, :cwd_outside_workspace}
  end

  defp copy_workspace(workspace, destination) do
    source = Map.get(workspace, :lower) || Map.get(workspace, "lower") || Map.get(workspace, :path) || Map.get(workspace, "path")

    if is_binary(source) and File.dir?(source) do
      File.rm_rf!(destination)
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(source, destination)
    else
      :ok
    end
  end

  defp workspace_base(workspace), do: Map.get(workspace, :base_ref) || Map.get(workspace, "base_ref")
  defp workspace_path(domain), do: Map.fetch!(domain.metadata, :workspace_path)

  defp domain_root(episode_id, epoch, generation), do: Path.join([root(), "domains", episode_id, "e#{epoch}-g#{generation}"])
  defp checkpoint_root(episode_id, epoch, generation), do: Path.join([root(), "checkpoints", episode_id, "e#{epoch}-g#{generation}"])
  defp root, do: Application.get_env(:autonomic, :state_dir, Path.join(System.tmp_dir!(), "autonomic-examples"))

  defp tree_digest(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
    |> Canonical.digest()
  end

  defp warn_once do
    key = {__MODULE__, :warned}
    unless :persistent_term.get(key, false) do
      Logger.warning("AUTONOMIC EXAMPLE ONLY: UnsafeLocalDomain has NO namespaces, cgroups, seccomp, network isolation, or host-secret boundary. Never use it for untrusted code.")
      :persistent_term.put(key, true)
    end
  end
end
