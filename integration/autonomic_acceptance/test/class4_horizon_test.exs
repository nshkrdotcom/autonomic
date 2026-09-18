defmodule Autonomic.Store.Class4HorizonTest do
  use ExUnit.Case, async: false

  alias Autonomic.{AuthorityGovernor, Canonical, EffectBroker}
  alias Autonomic.Store.{Postgres, Repo}
  alias Autonomic.Typesafe.Bank

  @moduletag :postgres
  @moduletag timeout: 60_000

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE effect_decisions, effects, capability_leases, observation_frames, checkpoints, recovery_records, episode_events, episodes RESTART IDENTITY CASCADE",
      []
    )

    root = Path.join(System.tmp_dir!(), "autonomic-class4-#{System.unique_integer([:positive])}")
    out = Path.join(root, "published")
    state = Path.join(root, "state")
    File.mkdir_p!(out)
    File.mkdir_p!(state)

    old_targets = Application.get_env(:autonomic, :targets, %{})
    old_keys = Application.get_env(:autonomic, :decision_keys, %{})
    old_dir = Application.fetch_env!(:autonomic, :state_dir)
    Application.put_env(:autonomic, :state_dir, state)

    Application.put_env(:autonomic, :targets, %{
      "release" => %{"directory" => out, "max_bytes" => 1024}
    })

    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    Application.put_env(:autonomic, :decision_keys, %{"operator" => Base.encode64(public)})

    client = safe_client()
    start_supervised!({Bank, client: client})

    on_exit(fn ->
      Application.put_env(:autonomic, :targets, old_targets)
      Application.put_env(:autonomic, :decision_keys, old_keys)
      Application.put_env(:autonomic, :state_dir, old_dir)
      _ = TypeSafeSDK.Test.close(client)
      File.rm_rf(root)
    end)

    {:ok, out: out, private: private, client: client}
  end

  test "Class 4 cannot cross commit horizon without exact signed human approval", ctx do
    episode_id = Canonical.id()

    policy = %{
      "id" => "publish-policy",
      "version" => 1,
      "max_effect_class" => 4,
      "capabilities" => [
        %{"kind" => "publish", "scope" => %{"id" => "release"}, "max_class" => 4}
      ],
      "semantic" => %{"max_risk" => 0.65}
    }

    capability = %{
      "kind" => "publish",
      "scope" => %{"id" => "release"},
      "constraints" => %{"max_effect_class" => 4}
    }

    envelope = %{"max_effect_class" => 4, "capabilities" => [capability]}

    assert {:ok, _} =
             Postgres.create_episode(%{
               id: episode_id,
               state: "running",
               current_epoch: 1,
               policy_id: policy["id"],
               policy_version: 1,
               policy: policy,
               hard_envelope: envelope,
               origin_intent_digest: Canonical.digest("publish fixture"),
               trajectory_version: 0,
               trajectory_regime: :stable,
               metadata: %{}
             })

    start_supervised!(
      {AuthorityGovernor, episode_id: episode_id, policy: policy, hard_envelope: envelope}
    )

    assert {:ok, lease} =
             AuthorityGovernor.issue(episode_id, %{
               authority_source: :signed_policy,
               capabilities: [capability],
               max_effect_class: :class_4_irreversible_high_impact,
               ttl_ms: 60_000,
               reason: "approved release candidate"
             })

    assert {:ok, prepared} =
             EffectBroker.prepare(%{
               episode_id: episode_id,
               lease_id: lease.id,
               kind: :publish,
               target_id: "release",
               target: %{"name" => "artifact.txt"},
               payload: "verified artifact\n"
             })

    assert {:error, _} = EffectBroker.commit(prepared.id)
    assert {:ok, still_prepared} = Postgres.fetch_effect(prepared.id)
    assert still_prepared.state == :prepared

    approval_doc = %{
      "effect_id" => prepared.id,
      "effect_revision" => prepared.revision,
      "episode_id" => prepared.episode_id,
      "epoch" => prepared.epoch,
      "payload_digest" => prepared.payload_digest,
      "decision" => "allow"
    }

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        "autonomic.human-approval.v1\n" <> Canonical.json(approval_doc),
        [ctx.private, :ed25519]
      )
      |> Base.encode64()

    approval = %{
      document: approval_doc,
      signature: signature,
      key_id: "operator",
      source_ref: "operator:integration"
    }

    assert {:ok, ready} = EffectBroker.evaluate(prepared.id, human_approval: approval)
    assert ready.state == :ready
    assert {:ok, committed} = EffectBroker.commit(prepared.id)
    assert committed.state == :committed
    assert File.read!(Path.join(ctx.out, "artifact.txt")) == "verified artifact\n"
    assert :ok = TypeSafeSDK.Test.verify!(ctx.client)
  end

  defp safe_client do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    TypeSafeSDK.Test.stub(
      client,
      [
        scope_drift: {:noul, 0.01},
        authority_escalation: {:noul, 0.01},
        evidence_sufficiency:
          {:score, 2.0, probabilities: %{0 => 0.0, 1 => 0.0, 2 => 1.0}, confidence: 0.99},
        irreversibility:
          {:score, 4.0,
           probabilities: %{0 => 0.0, 1 => 0.0, 2 => 0.0, 3 => 0.0, 4 => 1.0}, confidence: 0.99},
        trajectory_regime:
          {:choice, :stable,
           probabilities: %{stable: 0.99, uncertain: 0.005, drifting: 0.003, unstable: 0.002},
           confidence: 0.99}
      ],
      model: "jev-fixture",
      request_id: "req-class4"
    )
  end
end
