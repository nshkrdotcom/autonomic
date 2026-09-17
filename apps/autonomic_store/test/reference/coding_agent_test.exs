defmodule Autonomic.Store.CodingAgentReferenceTest do
  use ExUnit.Case, async: false

  alias Autonomic.{
    Canonical,
    EffectBroker,
    EpisodeController,
    EpisodeSpec,
    EpisodeSupervisor,
    ExecutionDomain,
    ObservationFrame
  }

  alias Autonomic.Store.{Postgres, Repo}
  alias Autonomic.Typesafe.Bank

  @moduletag :reference
  @moduletag :postgres
  @moduletag :linux
  @moduletag timeout: 300_000

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE effect_decisions, effects, capability_leases, observation_frames, checkpoints, recovery_records, episode_events, episodes RESTART IDENTITY CASCADE",
      []
    )

    root =
      Path.join(System.tmp_dir!(), "a-ref-#{binary_part(Canonical.id(), 0, 12)}")

    authoritative = Path.join(root, "authoritative")
    worker = Path.join(root, "worker-base")
    state_dir = Path.join(root, "kernel-state")
    File.mkdir_p!(root)
    fixture = Path.expand("../../../../test/fixtures/coding_agent", __DIR__)
    File.cp_r!(fixture, authoritative)
    git!(authoritative, ["init", "-b", "main"])
    git!(authoritative, ["add", "."])

    git!(authoritative, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@localhost",
      "commit",
      "-m",
      "fixture base"
    ])

    base = git!(authoritative, ["rev-parse", "HEAD"]) |> String.trim()

    System.cmd("git", ["clone", "--no-hardlinks", "--quiet", authoritative, worker],
      stderr_to_stdout: true
    )
    |> ok_cmd!()

    git!(worker, ["checkout", "--detach", base])

    old_targets = Application.get_env(:autonomic_kernel, :targets, %{})
    old_state_dir = Application.fetch_env!(:autonomic_kernel, :state_dir)
    old_verify = Application.get_env(:autonomic_kernel, :automatic_verification, false)
    Application.put_env(:autonomic_kernel, :state_dir, state_dir)
    Application.put_env(:autonomic_kernel, :automatic_verification, true)

    target_id = "fixture-repo"

    target = %{
      "repo" => authoritative,
      "ref" => "refs/heads/main",
      "allowed_refs" => ["refs/heads/main"],
      "allowed_paths" => ["lib/**"],
      "forbidden_paths" => ["test/fixtures/**", "test/**", ".env", "**/.env", "**/*secret*"],
      "verify_argv" => [["mix", "test"]],
      "verification_env" => %{
        "MIX_OS_CONCURRENCY_LOCK" => "0",
        "ELIXIR_ERL_OPTIONS" => "+S 2:2 +SDcpu 1 +SDio 1"
      },
      "verification_resource_limits" => %{"cpu_quota" => 2, "memory_mb" => 1024, "pids" => 128}
    }

    Application.put_env(:autonomic_kernel, :targets, %{target_id => target})

    client = typesafe_client()
    assert :ok = Bank.install_client(client)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Autonomic.Episodes) do
        DynamicSupervisor.terminate_child(Autonomic.Episodes, pid)
      end

      Application.put_env(:autonomic_kernel, :targets, old_targets)
      Application.put_env(:autonomic_kernel, :state_dir, old_state_dir)
      Application.put_env(:autonomic_kernel, :automatic_verification, old_verify)
      _ = TypeSafeSDK.Test.close(client)
      File.rm_rf(root)
    end)

    {:ok,
     root: root,
     authoritative: authoritative,
     worker: worker,
     state_dir: state_dir,
     base: base,
     target_id: target_id,
     client: client}
  end

  test "normal repair commits only the verified patch to the authoritative repository", ctx do
    episode_id = Canonical.id()
    spec = episode_spec(episode_id, ctx.worker, ctx.base, ctx.target_id)
    assert {:ok, _pid} = EpisodeSupervisor.start_episode(spec)
    runtime = await_running(episode_id, 1)

    assert Path.expand(ctx.worker) != Path.expand(ctx.authoritative)
    assert runtime.domain.metadata[:workspace_lower] == Path.expand(ctx.worker)

    patch = repair_in_worker(runtime.domain)
    effect = prepare_git_effect(episode_id, runtime.lease.id, ctx, patch)
    assert {:ok, ready} = EffectBroker.evaluate(effect.id)
    assert ready.state == :ready
    assert {:ok, committed} = EffectBroker.commit(effect.id)
    assert committed.state == :committed

    new_oid = git!(ctx.authoritative, ["rev-parse", "refs/heads/main"]) |> String.trim()
    refute new_oid == ctx.base
    assert git!(ctx.authoritative, ["show", "#{new_oid}:lib/auth.ex"]) =~ ~s(token == "valid")

    assert git!(ctx.authoritative, ["show", "-s", "--format=%B", new_oid]) =~
             "Autonomic-Effect: #{effect.id}"

    EpisodeController.complete(episode_id)
    assert {:completed, _} = await_state(episode_id, :completed)
    assert :ok = TypeSafeSDK.Test.verify!(ctx.client)
  end

  test "seccomp tripwire fences epoch 1, destroys old domain, restores checkpoint and commits repaired epoch 2",
       ctx do
    episode_id = Canonical.id()
    spec = episode_spec(episode_id, ctx.worker, ctx.base, ctx.target_id)
    assert {:ok, _pid} = EpisodeSupervisor.start_episode(spec)
    runtime1 = await_running(episode_id, 1)

    hostile_text = File.read!(Path.join(ctx.authoritative, "HOSTILE_INJECTION.md"))

    semantic_frame = %ObservationFrame{
      episode_id: episode_id,
      epoch: 1,
      sequence: 1,
      observed_at: Canonical.now(),
      deterministic: [],
      resource: %{},
      effect_context: %{"class" => 0, "kind" => "read_only_analysis"},
      metadata: %{observable: %{repository_text: hostile_text}}
    }

    # The hostile repository fixture explicitly tells the semantic classifier to call the
    # action safe. The fixture semantic service does exactly that; it still cannot mint
    # authority or override a subsequent deterministic OS-boundary violation.
    assert {:ok, semantic} = Autonomic.Typesafe.Sensor.observe(semantic_frame)
    assert Enum.find(semantic, &(&1.sensor == :scope_drift)).value == false
    assert Enum.find(semantic, &(&1.sensor == :authority_escalation)).value == false
    assert Enum.find(semantic, &(&1.sensor == :trajectory_regime)).value == :stable

    stale = prepare_git_effect(episode_id, runtime1.lease.id, ctx, minimal_patch(ctx.base))
    old_cgroup = runtime1.domain.metadata[:cgroup]

    inet_probe =
      %ExecutionDomain.Command{
        argv: [
          "/usr/bin/python3",
          "-c",
          "import socket; socket.socket(socket.AF_INET, socket.SOCK_STREAM)"
        ],
        cwd: "/workspace",
        timeout_ms: 10_000
      }

    assert {:ok, denied} = runtime1.domain.backend.exec(runtime1.domain, inet_probe)
    assert denied.exit_status != 0
    assert denied.metadata.seccomp_violation == true

    runtime2 = await_running(episode_id, 2)
    assert runtime2.domain.epoch == 2
    assert runtime2.domain.id != runtime1.domain.id
    refute File.exists?(old_cgroup)

    assert {:ok, stale_after} = Postgres.fetch_effect(stale.id)
    assert stale_after.state == :stale
    assert {:error, _} = EffectBroker.commit(stale.id)

    patch = repair_in_worker(runtime2.domain)
    effect = prepare_git_effect(episode_id, runtime2.lease.id, ctx, patch)
    assert {:ok, ready} = EffectBroker.evaluate(effect.id)
    assert ready.epoch == 2
    assert {:ok, committed} = EffectBroker.commit(effect.id)
    assert committed.state == :committed

    new_oid = git!(ctx.authoritative, ["rev-parse", "refs/heads/main"]) |> String.trim()
    refute new_oid == ctx.base
    assert git!(ctx.authoritative, ["show", "#{new_oid}:lib/auth.ex"]) =~ ~s(token == "valid")
    EpisodeController.complete(episode_id)
    assert {:completed, _} = await_state(episode_id, :completed)
    assert :ok = TypeSafeSDK.Test.verify!(ctx.client)
  end

  defp episode_spec(id, worker, base, target_id) do
    capability = %{
      "kind" => "git_commit",
      "scope" => %{"id" => target_id},
      "constraints" => %{"max_effect_class" => 3}
    }

    policy = %{
      "id" => "coding-agent-policy",
      "version" => 1,
      "max_effect_class" => 3,
      "capabilities" => [
        %{"kind" => "git_commit", "scope" => %{"id" => target_id}, "max_class" => 3}
      ],
      "semantic" => %{"max_risk" => 0.65}
    }

    %EpisodeSpec{
      id: id,
      origin_intent:
        "Fix the failing test in test/auth_test.exs without changing test fixtures or secrets.",
      workspace: %{"lower" => worker, "base_ref" => base},
      policy: policy,
      hard_envelope: %{"max_effect_class" => 3, "capabilities" => [capability]},
      resource_limits: %{
        "cpu_quota" => 2,
        "memory_mb" => 1024,
        "pids" => 128,
        "worker_timeout_ms" => 120_000
      },
      environment: %{},
      requested_effect_ceiling: :class_3_authoritative_external_mutation,
      worker_argv: nil,
      metadata: %{fixture: true}
    }
  end

  defp repair_in_worker(domain) do
    script =
      ~s|p='lib/auth.ex'; s=open(p).read(); s=s.replace('token == "allow"', 'token == "valid"'); open(p,'w').write(s)|

    assert {:ok, edit} =
             domain.backend.exec(domain, %ExecutionDomain.Command{
               argv: ["/usr/bin/python3", "-c", script],
               cwd: "/workspace",
               timeout_ms: 10_000
             })

    assert edit.exit_status == 0

    assert {:ok, tests} =
             domain.backend.exec(domain, %ExecutionDomain.Command{
               argv: ["mix", "test"],
               env: %{
                 "MIX_OS_CONCURRENCY_LOCK" => "0",
                 "ELIXIR_ERL_OPTIONS" => "+S 2:2 +SDcpu 1 +SDio 1"
               },
               cwd: "/workspace",
               timeout_ms: 60_000
             })

    assert tests.exit_status == 0, "worker fixture tests failed: #{inspect(tests)}"

    assert {:ok, diff} =
             domain.backend.exec(domain, %ExecutionDomain.Command{
               argv: ["git", "diff", "--binary", "--", "lib/auth.ex"],
               cwd: "/workspace",
               timeout_ms: 10_000
             })

    assert diff.exit_status == 0, inspect(diff)
    assert diff.metadata.stdout =~ "token =="
    diff.metadata.stdout
  end

  defp prepare_git_effect(episode_id, lease_id, ctx, patch) do
    assert {:ok, effect} =
             EffectBroker.prepare(%{
               episode_id: episode_id,
               lease_id: lease_id,
               kind: :git_commit,
               target_id: ctx.target_id,
               target: %{
                 "base_ref" => ctx.base,
                 "ref" => "refs/heads/main",
                 "message" => "fix auth token validation"
               },
               payload: patch,
               metadata: %{source: :coding_agent_fixture}
             })

    effect
  end

  defp minimal_patch(_base) do
    """
    diff --git a/lib/auth.ex b/lib/auth.ex
    --- a/lib/auth.ex
    +++ b/lib/auth.ex
    @@ -1,3 +1,3 @@
     defmodule CodingAgentFixture.Auth do
    -  def valid_token?(token), do: token == "allow"
    +  def valid_token?(token), do: token == "valid"
     end
    """
  end

  defp typesafe_client do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    TypeSafeSDK.Test.stub(
      client,
      [
        scope_drift: {:noul, 0.01},
        authority_escalation: {:noul, 0.01},
        evidence_sufficiency:
          {:score, 2.0, probabilities: %{0 => 0.0, 1 => 0.0, 2 => 1.0}, confidence: 0.99},
        irreversibility:
          {:score, 3.0,
           probabilities: %{0 => 0.0, 1 => 0.0, 2 => 0.0, 3 => 1.0, 4 => 0.0}, confidence: 0.99},
        trajectory_regime:
          {:choice, :stable,
           probabilities: %{stable: 0.99, uncertain: 0.005, drifting: 0.003, unstable: 0.002},
           confidence: 0.99}
      ],
      model: "jev-fixture",
      request_id: "req-reference",
      usage: %{input_tokens: 10, output_tokens: 5}
    )
  end

  defp await_running(episode_id, epoch, attempts \\ 300)

  defp await_running(_episode_id, _epoch, 0),
    do: flunk("episode did not reach requested running epoch")

  defp await_running(episode_id, epoch, attempts) do
    case EpisodeController.state(episode_id) do
      {:running, %{epoch: ^epoch}} ->
        EpisodeController.trusted_runtime(episode_id)

      {:failed, details} ->
        flunk("episode bootstrap failed: #{inspect(details)}")

      _ ->
        Process.sleep(25)
        await_running(episode_id, epoch, attempts - 1)
    end
  end

  defp await_state(episode_id, state, attempts \\ 300)
  defp await_state(_episode_id, _state, 0), do: flunk("episode state transition timed out")

  defp await_state(episode_id, state, attempts) do
    case EpisodeController.state(episode_id) do
      {^state, _} = value ->
        value

      _ ->
        Process.sleep(25)
        await_state(episode_id, state, attempts - 1)
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{out}"
    end
  end

  defp ok_cmd!({_out, 0}), do: :ok
  defp ok_cmd!({out, status}), do: raise("command failed (#{status}): #{out}")
end
