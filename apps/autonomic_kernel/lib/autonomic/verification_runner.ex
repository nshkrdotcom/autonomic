defmodule Autonomic.VerificationRunner do
  @moduledoc "Trusted exact-payload Git verification in a separate disposable execution domain."

  alias Autonomic.{Canonical, EffectSocket, ExecutionDomain, Runtime}

  @spec verify_git(Autonomic.ProposedEffect.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify_git(effect, target) do
    with {:ok, repo} <- repo_path(target),
         {:ok, base} <- base_ref(effect),
         :ok <- assert_base(repo, base),
         {:ok, snapshot, cleanup} <- export_snapshot(repo, base, effect) do
      try do
        run_snapshot(effect, target, snapshot)
      after
        cleanup.()
      end
    end
  rescue
    error -> {:error, {:verification_runner_failed, error}}
  end

  defp run_snapshot(effect, target, snapshot) do
    socket = EffectSocket.path(effect.episode_id)

    spec = %ExecutionDomain.Spec{
      episode_id: effect.episode_id,
      epoch: effect.epoch,
      workspace: %{lower: snapshot, base_ref: base_ref!(effect)},
      hard_envelope: %{max_effect_class: :class_1_isolated_mutable, capabilities: []},
      resource_limits: Map.get(target, "verification_resource_limits", %{cpu_quota: 2, memory_mb: 2048, pids: 192}),
      environment: %{},
      effect_socket: socket,
      metadata: %{purpose: :trusted_slow_verification, effect_id: effect.id, effect_revision: effect.revision}
    }

    domain_backend = Runtime.domain()

    with {:ok, domain} <- domain_backend.create(spec) do
      try do
        commands = [["git", "apply", "--check", "--whitespace=error", ".autonomic-effect.patch"], ["git", "apply", "--whitespace=error", ".autonomic-effect.patch"]] ++ verification_commands(target)

        case run_commands(domain, commands, verification_env(target), []) do
          {:ok, evidence} ->
            case destroy_proven(domain) do
              :ok ->
                {:ok, %{effect_id: effect.id, effect_revision: effect.revision, payload_digest: effect.payload_digest, base_ref: base_ref!(effect), passed: true, commands: evidence, verified_at: Canonical.now()}}

              {:error, reason} ->
                {:error, {:verification_domain_teardown_failed, reason}}
            end

          {:error, reason} ->
            _ = destroy_proven(domain)
            {:error, reason}
        end
      rescue
        error ->
          _ = destroy_proven(domain)
          {:error, {:verification_execution_failed, error}}
      end
    end
  end

  defp run_commands(_domain, [], _env, evidence), do: {:ok, Enum.reverse(evidence)}

  defp run_commands(domain, [argv | rest], env, evidence) do
    command = %ExecutionDomain.Command{
      argv: argv,
      cwd: "/workspace",
      env: env,
      timeout_ms: verification_timeout()
    }

    case domain.backend.exec(domain, command) do
      {:ok, execution} when execution.exit_status == 0 ->
        item = %{
          argv_digest: Canonical.digest(argv),
          exit_status: execution.exit_status,
          stdout_digest: Canonical.hash(execution.metadata[:stdout] || ""),
          stderr_digest: Canonical.hash(execution.metadata[:stderr] || ""),
          stdout_truncated: execution.metadata[:stdout_truncated] || false,
          stderr_truncated: execution.metadata[:stderr_truncated] || false
        }

        run_commands(domain, rest, env, [item | evidence])

      {:ok, execution} ->
        {:error, {:verification_command_failed, Canonical.digest(argv), execution.exit_status, Canonical.hash(execution.metadata[:stdout] || ""), Canonical.hash(execution.metadata[:stderr] || "")}}

      {:error, _} = error ->
        error
    end
  end

  defp export_snapshot(repo, base, effect) do
    root = Path.join([Runtime.root(), "verification", effect.episode_id, effect.id <> "-" <> Integer.to_string(effect.revision)])
    snapshot = Path.join(root, "snapshot")
    archive = Path.join(root, "base.tar")
    File.rm_rf(root)
    File.mkdir_p!(snapshot)
    File.chmod!(root, 0o700)
    File.chmod!(snapshot, 0o700)

    cleanup = fn -> File.rm_rf(root); :ok end

    result =
      with {_, 0} <- System.cmd("git", ["archive", "--format=tar", "--output=#{archive}", base], cd: repo, stderr_to_stdout: true),
           {_, 0} <- System.cmd("tar", ["--no-same-owner", "--no-same-permissions", "-xf", archive, "-C", snapshot], stderr_to_stdout: true),
           {:ok, patch} <- Autonomic.Payloads.get(effect.episode_id, effect.payload_ref),
           :ok <- File.write(Path.join(snapshot, ".autonomic-effect.patch"), patch, [:binary, :exclusive]) do
        {:ok, snapshot, cleanup}
      else
        {output, status} -> {:error, {:snapshot_export_failed, status, Canonical.hash(output)}}
        {:error, _} = error -> error
      end

    if match?({:error, _}, result), do: cleanup.()
    result
  rescue
    error ->
      File.rm_rf(root)
      {:error, {:snapshot_export_failed, error}}
  end

  defp verification_commands(target) do
    case Map.get(target, "verify_argv") do
      commands when is_list(commands) and commands != [] ->
        if Enum.all?(commands, &is_binary/1), do: [validate_argv!(commands)], else: Enum.map(commands, &validate_argv!/1)

      _ ->
        raise ArgumentError, "trusted Git target requires verify_argv for Class 3 verification"
    end
  end

  defp validate_argv!(argv) when is_list(argv) and argv != [] do
    if length(argv) <= 256 and Enum.all?(argv, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 16_384)), do: argv, else: raise(ArgumentError, "invalid verify_argv")
  end
  defp validate_argv!(_), do: raise(ArgumentError, "invalid verify_argv")

  defp verification_env(target) do
    case Map.get(target, "verification_env", %{}) do
      env when is_map(env) ->
        Map.new(env, fn {key, value} ->
          key = to_string(key)
          value = to_string(value)
          lowered = String.downcase(key)
          if byte_size(key) + byte_size(value) > 32_768, do: raise(ArgumentError, "verification environment entry too large")
          if Enum.any?(["token", "secret", "password", "credential", "api_key", "authorization"], &String.contains?(lowered, &1)), do: raise(ArgumentError, "verification environment may not contain credentials")
          {key, value}
        end)
      _ -> raise ArgumentError, "verification_env must be a map"
    end
  end

  defp destroy_proven(domain) do
    case domain.backend.destroy(domain) do
      :ok -> :ok
      {:ok, evidence} -> if(Map.get(evidence, :empty, Map.get(evidence, "empty", false)), do: :ok, else: {:error, :verification_domain_not_empty})
      {:error, _} = error -> error
      other -> {:error, {:invalid_destroy_result, other}}
    end
  end

  defp repo_path(target) do
    case Map.get(target, "repo") do
      path when is_binary(path) ->
        path = Path.expand(path)
        if File.dir?(path), do: {:ok, path}, else: {:error, :trusted_repo_missing}
      _ -> {:error, :trusted_repo_not_configured}
    end
  end

  defp base_ref(effect) do
    case Map.get(effect.target, "base_ref") || Map.get(effect.target, :base_ref) do
      base when is_binary(base) -> {:ok, base}
      _ -> {:error, :base_ref_required}
    end
  end

  defp base_ref!(effect), do: elem(base_ref(effect), 1)

  defp assert_base(repo, base) do
    case System.cmd("git", ["rev-parse", "--verify", "#{base}^{commit}"], cd: repo, stderr_to_stdout: true) do
      {oid, 0} -> if(String.trim(oid) == base, do: :ok, else: {:error, :base_ref_not_exact_oid})
      {output, status} -> {:error, {:base_ref_unavailable, status, Canonical.hash(output)}}
    end
  end

  defp verification_timeout, do: Application.get_env(:autonomic_kernel, :verification_timeout_ms, 120_000)
end
