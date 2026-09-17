defmodule Autonomic.Store.HomeostatTrajectoryTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias Autonomic.{Canonical, Homeostat, ObservationFrame, SemanticObservation}
  alias Autonomic.Store.{Postgres, Repo}

  setup do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE recovery_records, observation_frames, episode_events, effect_decisions, effects, checkpoints, capability_leases, episodes RESTART IDENTITY CASCADE", [])
    episode_id = Canonical.id()
    policy = %{"id" => "trajectory", "version" => 1, "max_effect_class" => 4, "capabilities" => []}

    assert {:ok, _} =
             Postgres.create_episode(%{
               id: episode_id,
               state: "running",
               current_epoch: 1,
               policy_id: "trajectory",
               policy_version: 1,
               policy: policy,
               hard_envelope: %{"max_effect_class" => 4, "capabilities" => []},
               origin_intent_digest: Canonical.digest("trajectory"),
               trajectory_version: 0,
               trajectory_regime: :stable
             })

    start_supervised!({Homeostat, episode_id: episode_id, epoch: 1})
    %{episode_id: episode_id}
  end

  test "hard deterministic violation dominates semantic safe evidence and persists containment", %{episode_id: episode_id} do
    safe_semantic = [
      observation(:scope_drift, false, 0.99),
      observation(:authority_escalation, false, 0.99),
      observation(:evidence_sufficiency, "Sufficient", 0.99, %{normalized: 1.0}),
      observation(:trajectory_regime, :stable, 0.99)
    ]

    frame = %ObservationFrame{
      episode_id: episode_id,
      epoch: 1,
      sequence: 1,
      observed_at: Canonical.now(),
      deterministic: [%{type: :seccomp_violation, source: :linux_launcher}],
      semantic: safe_semantic,
      resource: %{}
    }

    assert {:ok, {:homeostat, :contain, :deterministic_boundary_violation, _}, state} =
             Homeostat.observe(episode_id, frame)
    assert state.regime == :containment
    assert state.autonomy_balance == 0.0
    assert {:ok, episode} = Postgres.fetch_episode(episode_id)
    assert episode.trajectory_regime == :containment
    assert episode.trajectory_version == 1
  end

  test "semantic uncertainty is smoothed and does not expand deterministic authority", %{episode_id: episode_id} do
    uncertain = [
      observation(:scope_drift, false, 0.7),
      observation(:authority_escalation, false, 0.7),
      observation(:evidence_sufficiency, "Insufficient", 0.95, %{normalized: 0.0}),
      observation(:trajectory_regime, :uncertain, 0.95)
    ]

    assert {:ok, signal, state} =
             Homeostat.observe(episode_id, %ObservationFrame{
               episode_id: episode_id,
               epoch: 1,
               sequence: 1,
               observed_at: Canonical.now(),
               deterministic: [],
               semantic: uncertain,
               resource: %{}
             })

    assert elem(signal, 1) in [:continue, :yield, :narrow, :preempt]
    assert state.trajectory_version == 1
    assert state.regime in [:stable, :uncertain]
  end

  defp observation(sensor, value, confidence, metadata \\ %{}) do
    %SemanticObservation{
      sensor: sensor,
      value: value,
      confidence: confidence,
      model: "jev-fixture",
      requested_model: "jev-fixture",
      request_id: "req-trajectory",
      sdk_version: "0.2.0",
      sensor_bank_version: "coding-v1",
      semantic_contract_id: "sha256:test",
      observed_at: Canonical.now(),
      metadata: metadata
    }
  end
end
