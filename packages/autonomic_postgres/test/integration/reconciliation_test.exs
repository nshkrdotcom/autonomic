defmodule Autonomic.Store.ReconciliationTest do
  use ExUnit.Case, async: false

  alias Autonomic.{AuthorityGovernor, Canonical, EffectBroker}
  alias Autonomic.Store.{Postgres, Repo}

  @moduletag :postgres
  @moduletag timeout: 60_000

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE effect_decisions, effects, capability_leases, observation_frames, checkpoints, recovery_records, episode_events, episodes RESTART IDENTITY CASCADE",
      []
    )

    root =
      Path.join(System.tmp_dir!(), "autonomic-reconcile-#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    state = Path.join(root, "state")
    File.mkdir_p!(repo)
    File.mkdir_p!(state)
    File.write!(Path.join(repo, "value.txt"), "old\n")
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["add", "."])

    git!(repo, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@localhost",
      "commit",
      "-m",
      "base"
    ])

    base = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

    target = %{
      "repo" => repo,
      "ref" => "refs/heads/main",
      "allowed_refs" => ["refs/heads/main"],
      "allowed_paths" => ["value.txt"],
      "forbidden_paths" => [],
      "verify_argv" => [["/bin/true"]]
    }

    old_targets = Application.get_env(:autonomic, :targets, %{})
    old_state = Application.fetch_env!(:autonomic, :state_dir)
    Application.put_env(:autonomic, :targets, %{"repo" => target})
    Application.put_env(:autonomic, :state_dir, state)

    on_exit(fn ->
      Application.put_env(:autonomic, :targets, old_targets)
      Application.put_env(:autonomic, :state_dir, old_state)
      File.rm_rf(root)
    end)

    {:ok, repo: repo, base: base, target: target}
  end

  test "external mutation survives broker crash and is reconciled from durable commit intent",
       ctx do
    {episode_id, lease} = episode_and_lease()
    patch = patch("old", "new")
    effect = prepared_effect(episode_id, lease.id, ctx.base, patch)
    ready = ready_with_bound_decisions(effect)

    assert {:ok, intent} =
             Postgres.begin_effect_commit(ready.id, [:deterministic, :semantic, :slow_verifier])

    assert intent.state == :commit_intent
    assert {:ok, committing} = Postgres.mark_committing(intent.id)

    assert {:ok, receipt} = Autonomic.Adapters.Git.commit(committing, trusted_target: ctx.target)
    assert is_binary(receipt.oid)

    # Simulated BEAM/broker crash point: no complete_effect call occurred.
    assert {:ok, durable} = Postgres.fetch_effect(effect.id)
    assert durable.state == :committing

    assert {:ok, reconciled} = EffectBroker.reconcile(effect.id)
    assert reconciled.state == :committed
    assert String.trim(git!(ctx.repo, ["show", "refs/heads/main:value.txt"])) == "new"
  end

  test "revision change invalidates old approvals and unresolved commit state cannot be blindly recommitted",
       ctx do
    {episode_id, lease} = episode_and_lease()
    effect = prepared_effect(episode_id, lease.id, ctx.base, patch("old", "new"))
    ready = ready_with_bound_decisions(effect)

    assert {:ok, revised} =
             Postgres.update_effect_revision(ready.id, %{
               payload_ref: ready.payload_ref,
               payload_digest: ready.payload_digest,
               target: ready.target
             })

    assert revised.revision == 2
    assert {:ok, evaluating} = Postgres.mark_effect_evaluating(revised.id)
    assert {:ok, ready2} = Postgres.mark_effect_ready(evaluating.id)

    assert {:error, {:missing_decisions, missing}} =
             Postgres.begin_effect_commit(ready2.id, [:deterministic, :semantic, :slow_verifier])

    assert Enum.sort(missing) == ["deterministic", "semantic", "slow_verifier"]

    # Rebind decisions, then cross the commit horizon and force an ambiguous external ref.
    ready2 = ready_with_bound_decisions(ready2)

    assert {:ok, intent} =
             Postgres.begin_effect_commit(ready2.id, [:deterministic, :semantic, :slow_verifier])

    assert {:ok, _} = Postgres.mark_committing(intent.id)

    File.write!(Path.join(ctx.repo, "other.txt"), "other\n")
    git!(ctx.repo, ["add", "other.txt"])

    git!(ctx.repo, [
      "-c",
      "user.name=Other",
      "-c",
      "user.email=other@localhost",
      "commit",
      "-m",
      "concurrent"
    ])

    assert {:ok, unknown} = EffectBroker.reconcile(effect.id)
    assert unknown.state == :commit_unknown
    assert {:error, _} = EffectBroker.commit(effect.id)
    assert {:error, :commit_horizon_crossed} = EffectBroker.abort(effect.id, :retry)
  end

  defp episode_and_lease do
    id = Canonical.id()

    policy = %{
      "id" => "git-policy",
      "version" => 1,
      "max_effect_class" => 3,
      "capabilities" => [
        %{"kind" => "git_commit", "scope" => %{"id" => "repo"}, "max_class" => 3}
      ]
    }

    cap = %{
      "kind" => "git_commit",
      "scope" => %{"id" => "repo"},
      "constraints" => %{"max_effect_class" => 3}
    }

    envelope = %{"max_effect_class" => 3, "capabilities" => [cap]}

    assert {:ok, _} =
             Postgres.create_episode(%{
               id: id,
               state: "running",
               current_epoch: 1,
               policy_id: policy["id"],
               policy_version: 1,
               policy: policy,
               hard_envelope: envelope,
               origin_intent_digest: Canonical.digest("git reconciliation"),
               trajectory_version: 0,
               trajectory_regime: :stable,
               metadata: %{}
             })

    start_supervised!(
      {AuthorityGovernor, episode_id: id, policy: policy, hard_envelope: envelope}
    )

    assert {:ok, lease} =
             AuthorityGovernor.issue(id, %{
               authority_source: :signed_policy,
               capabilities: [cap],
               max_effect_class: :class_3_authoritative_external_mutation,
               ttl_ms: 60_000,
               reason: "integration"
             })

    {id, lease}
  end

  defp prepared_effect(episode_id, lease_id, base, patch) do
    assert {:ok, effect} =
             EffectBroker.prepare(%{
               episode_id: episode_id,
               lease_id: lease_id,
               kind: :git_commit,
               target_id: "repo",
               target: %{
                 "base_ref" => base,
                 "ref" => "refs/heads/main",
                 "message" => "update value"
               },
               payload: patch
             })

    effect
  end

  defp ready_with_bound_decisions(%{state: :prepared} = effect) do
    assert {:ok, effect} = Postgres.mark_effect_evaluating(effect.id)
    bind_decisions(effect)
    assert {:ok, ready} = Postgres.mark_effect_ready(effect.id)
    ready
  end

  defp ready_with_bound_decisions(%{state: :ready} = effect) do
    # A revised ready row has no decisions for the new revision.
    bind_decisions(effect)
    effect
  end

  defp ready_with_bound_decisions(%{state: :evaluating} = effect) do
    bind_decisions(effect)
    assert {:ok, ready} = Postgres.mark_effect_ready(effect.id)
    ready
  end

  defp bind_decisions(effect) do
    for kind <- [:deterministic, :semantic, :slow_verifier] do
      assert {:ok, _} =
               Postgres.record_effect_decision(effect.id, %{
                 kind: kind,
                 decision: :allow,
                 source_ref: "#{kind}:#{effect.revision}",
                 effect_revision: effect.revision,
                 epoch: effect.epoch,
                 policy_version: effect.version_vector.policy_version,
                 trajectory_version: effect.version_vector.trajectory_version,
                 payload_digest: effect.payload_digest,
                 evidence_ref: "sha256:#{Canonical.digest([kind, effect.revision])}",
                 expires_at: Canonical.now() + 60_000
               })
    end
  end

  defp patch(old, new) do
    """
    diff --git a/value.txt b/value.txt
    --- a/value.txt
    +++ b/value.txt
    @@ -1 +1 @@
    -#{old}
    +#{new}
    """
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{out}"
    end
  end
end
