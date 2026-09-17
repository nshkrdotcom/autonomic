defmodule Autonomic.Store.PostgresAuthorityTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias Autonomic.{CapabilityLease, Canonical, ProposedEffect, VersionVector}
  alias Autonomic.Store.{Postgres, Repo}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE recovery_records, observation_frames, episode_events, effect_decisions, effects, checkpoints, capability_leases, episodes RESTART IDENTITY CASCADE", [])
    :ok
  end

  test "concurrent epoch advances serialize monotonically under the episode row lock" do
    episode = episode!()
    parent = self()
    barrier = :atomics.new(1, signed: false)

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, index})
          wait_barrier(barrier)
          Postgres.advance_epoch(episode.id, %{racer: index})
        end)
      end

    for _ <- 1..8 do
      assert_receive {:ready, _}, 2_000
    end

    :atomics.put(barrier, 1, 1)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.sort(for {:ok, epoch} <- results, do: epoch) == Enum.to_list(2..9)
    assert {:ok, 9} = Postgres.current_epoch(episode.id)
  end

  test "durable epoch bump revokes old lease and stales prepared effect" do
    episode = episode!()
    lease = lease!(episode.id, 1)
    effect = proposed_effect(episode, lease)
    assert :ok = Postgres.put_effect(effect)
    assert {:ok, %{state: :prepared}} = Postgres.prepare_existing_effect(effect.id)

    assert {:ok, 2} = Postgres.advance_epoch(episode.id, %{reason: :test_fence})
    assert {:ok, revoked} = Postgres.fetch_lease(lease.id)
    assert is_integer(revoked.revoked_at)
    assert {:ok, %{state: :stale}} = Postgres.fetch_effect(effect.id)
  end

  test "commit intent is durable before epoch advancement and remains reconciliation work" do
    episode = episode!()
    lease = lease!(episode.id, 1)
    effect = proposed_effect(episode, lease)
    assert :ok = Postgres.put_effect(effect)
    assert {:ok, _} = Postgres.prepare_existing_effect(effect.id)
    assert {:ok, _} = Postgres.mark_effect_evaluating(effect.id)
    assert {:ok, _} = Postgres.mark_effect_ready(effect.id)

    assert {:ok, intent} = Postgres.begin_effect_commit(effect.id, [])
    assert intent.state == :commit_intent
    assert is_binary(intent.commit_attempt_id)

    assert {:ok, 2} = Postgres.advance_epoch(episode.id, %{reason: :race_after_intent})
    assert {:ok, %{state: :commit_intent}} = Postgres.fetch_effect(effect.id)
    assert {:ok, pending} = Postgres.pending_reconciliation()
    assert Enum.any?(pending, &(&1.id == effect.id))
  end

  test "epoch that wins before commit horizon mechanically rejects the stale effect" do
    episode = episode!()
    lease = lease!(episode.id, 1)
    effect = proposed_effect(episode, lease)
    assert :ok = Postgres.put_effect(effect)
    assert {:ok, _} = Postgres.prepare_existing_effect(effect.id)
    assert {:ok, _} = Postgres.mark_effect_evaluating(effect.id)
    assert {:ok, _} = Postgres.mark_effect_ready(effect.id)
    assert {:ok, 2} = Postgres.advance_epoch(episode.id, %{reason: :race_before_intent})
    assert {:error, :stale_authority} = Postgres.begin_effect_commit(effect.id, [])
  end

  defp episode! do
    id = Canonical.id()
    policy = %{"id" => "test", "version" => 1, "max_effect_class" => 4, "capabilities" => []}

    assert {:ok, episode} =
             Postgres.create_episode(%{
               id: id,
               state: "running",
               current_epoch: 1,
               policy_id: "test",
               policy_version: 1,
               policy: policy,
               hard_envelope: %{"max_effect_class" => 4, "capabilities" => []},
               origin_intent_digest: Canonical.digest("test"),
               trajectory_version: 0,
               trajectory_regime: :stable
             })

    %{id: episode.id, policy_version: episode.policy_version, trajectory_version: episode.trajectory_version}
  end

  defp lease!(episode_id, epoch) do
    now = Canonical.now()
    lease = %CapabilityLease{
      id: Canonical.id(),
      episode_id: episode_id,
      epoch: epoch,
      policy_version: 1,
      capabilities: [],
      max_effect_class: :class_4_irreversible_high_impact,
      issued_at: now,
      expires_at: now + 120_000,
      authority_source: :signed_policy
    }
    assert :ok = Postgres.put_lease(lease)
    lease
  end

  defp proposed_effect(episode, lease) do
    payload = Canonical.hash("payload")
    vector = %VersionVector{
      episode_id: episode.id,
      epoch: 1,
      policy_version: episode.policy_version,
      snapshot_ancestry: [],
      trajectory_version: episode.trajectory_version,
      trajectory_regime: :stable,
      lease_id: lease.id,
      effect_revision: 1
    }

    %ProposedEffect{
      id: Canonical.id(), episode_id: episode.id, epoch: 1, lease_id: lease.id,
      class: :class_3_authoritative_external_mutation, kind: :git_commit,
      target: %{"id" => "fixture", "base_ref" => String.duplicate("a", 40)},
      payload_ref: payload, payload_digest: payload, revision: 1, reversible?: false,
      state: :proposed, version_vector: vector, created_at: Canonical.now()
    }
  end

  defp wait_barrier(barrier) do
    if :atomics.get(barrier, 1) == 1 do
      :ok
    else
      Process.sleep(1)
      wait_barrier(barrier)
    end
  end
end
