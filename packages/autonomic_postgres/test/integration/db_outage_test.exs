defmodule Autonomic.Store.DatabaseOutageTest do
  use ExUnit.Case, async: false

  @moduletag :db_outage

  alias Autonomic.{AuthorityGovernor, Canonical, EffectBroker}
  alias Autonomic.Store.{Postgres, Repo}

  test "real PostgreSQL outage blocks authoritative effect preparation" do
    pgdata = System.fetch_env!("AUTONOMIC_EPHEMERAL_PGDATA")
    pg_ctl = System.fetch_env!("AUTONOMIC_PG_CTL")
    run_as = System.get_env("AUTONOMIC_PG_RUN_AS")

    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE recovery_records, observation_frames, episode_events, effect_decisions, effects, checkpoints, capability_leases, episodes RESTART IDENTITY CASCADE",
      []
    )

    episode_id = Canonical.id()
    target_id = "db-outage-target"

    policy = %{
      "id" => "db-outage",
      "version" => 1,
      "max_effect_class" => 3,
      "capabilities" => [
        %{"kind" => "git_commit", "scope" => %{"id" => target_id}, "max_class" => 3}
      ]
    }

    envelope = %{"max_effect_class" => 3, "capabilities" => policy["capabilities"]}

    assert {:ok, _} =
             Postgres.create_episode(%{
               id: episode_id,
               state: "running",
               current_epoch: 1,
               policy_id: "db-outage",
               policy_version: 1,
               policy: policy,
               hard_envelope: envelope,
               origin_intent_digest: Canonical.digest("db outage"),
               trajectory_version: 0,
               trajectory_regime: :stable
             })

    start_supervised!(
      {AuthorityGovernor, episode_id: episode_id, policy: policy, hard_envelope: envelope}
    )

    assert {:ok, lease} =
             AuthorityGovernor.issue(episode_id, %{
               authority_source: :signed_policy,
               capabilities: envelope["capabilities"],
               max_effect_class: :class_3_authoritative_external_mutation,
               ttl_ms: 60_000,
               reason: "db outage test"
             })

    assert {_, 0} = pg_control(pg_ctl, ["-D", pgdata, "stop", "-m", "immediate", "-w"], run_as)

    on_exit(fn ->
      _ = pg_control(pg_ctl, ["-D", pgdata, "start", "-w"], run_as)
    end)

    assert {:error, _reason} =
             EffectBroker.prepare(%{
               episode_id: episode_id,
               lease_id: lease.id,
               kind: :git_commit,
               target_id: target_id,
               target: %{"id" => target_id, "base_ref" => String.duplicate("a", 40)},
               payload: "diff --git a/a b/a\n"
             })
  end

  defp pg_control(pg_ctl, args, nil), do: System.cmd(pg_ctl, args, stderr_to_stdout: true)

  defp pg_control(pg_ctl, args, user),
    do: System.cmd("runuser", ["-u", user, "--", pg_ctl | args], stderr_to_stdout: true)
end
