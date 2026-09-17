defmodule Autonomic.Typesafe.SensorComponentTest do
  use ExUnit.Case, async: false

  alias Autonomic.{Canonical, ObservationFrame}
  alias Autonomic.Typesafe.{Bank, Evidence, Sensor, SensorBank}

  test "prepared bank uses the strict TypeSafe test transport and preserves provenance" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    client =
      TypeSafeSDK.Test.stub(
        client,
        [
          scope_drift: {:noul, 0.05},
          authority_escalation: {:noul, 0.02},
          evidence_sufficiency:
            {:score, 1.95, probabilities: %{0 => 0.01, 1 => 0.04, 2 => 0.95}, confidence: 0.96},
          irreversibility:
            {:score, 3.0,
             probabilities: %{0 => 0.0, 1 => 0.01, 2 => 0.04, 3 => 0.9, 4 => 0.05},
             confidence: 0.91},
          trajectory_regime:
            {:choice, :stable,
             probabilities: %{stable: 0.96, uncertain: 0.02, drifting: 0.01, unstable: 0.01},
             confidence: 0.96}
        ],
        model: "jev-fixture",
        usage: %{input_tokens: 12, output_tokens: 7}
      )

    assert :ok = Bank.install_client(client)
    frame = frame(%{stdout: "all tests passed"})
    assert {:ok, observations} = Sensor.observe(frame)

    assert Enum.map(observations, & &1.sensor) == [
             :scope_drift,
             :authority_escalation,
             :evidence_sufficiency,
             :irreversibility,
             :trajectory_regime
           ]

    assert Enum.all?(observations, &(&1.sensor_bank_version == SensorBank.version()))
    assert Enum.all?(observations, &(&1.semantic_contract_id == SensorBank.contract_id()))
    assert Enum.all?(observations, &(&1.model == "jev-fixture"))
    assert is_binary(Canonical.json(observations))
    assert Enum.find(observations, &(&1.sensor == :trajectory_regime)).value == :stable
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "observable state is redacted before transport and bounded" do
    frame =
      frame(%{
        authorization: "Bearer abcdefghijklmnop",
        nested: %{api_key: "super-secret"},
        text: "password=hunter2"
      })

    assert {:ok, state, budget} = Evidence.bounded(frame, 4_096)
    encoded = Jason.encode!(state)
    refute encoded =~ "abcdefghijklmnop"
    refute encoded =~ "super-secret"
    refute encoded =~ "hunter2"
    assert byte_size(encoded) <= 4_096
    assert budget.sent_bytes <= 4_096
  end

  test "semantic contract identity is stable over its declarative manifest" do
    assert SensorBank.contract_id() ==
             "sha256:" <>
               Canonical.hash(
                 "autonomic.typesafe-sensor-manifest.v1\n" <>
                   Canonical.json(SensorBank.manifest())
               )
  end

  test "future unknown required answers fail closed" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    body = %{
      "model" => "jev-fixture",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3},
      "answers" => %{
        "scope_drift" => %{"type" => "future-semantic-answer", "payload" => true},
        "authority_escalation" => %{"type" => "noul", "noul" => 0.01},
        "evidence_sufficiency" =>
          score_answer(2.0, [0.0, 0.0, 1.0], ["Insufficient", "Partial", "Sufficient"]),
        "irreversibility" =>
          score_answer(1.0, [0.0, 1.0, 0.0, 0.0, 0.0], [
            "Local",
            "Reversible",
            "External",
            "Authoritative",
            "High-impact"
          ]),
        "trajectory_regime" => %{
          "type" => "choice",
          "choice" => "stable",
          "confidence" => 0.99,
          "probabilities" => %{
            "stable" => 0.99,
            "uncertain" => 0.005,
            "drifting" => 0.003,
            "unstable" => 0.002
          }
        }
      }
    }

    client = TypeSafeSDK.Test.stub_response(client, body, request_id: "req-future")
    assert :ok = Bank.install_client(client)

    assert {:error, {:unknown_required_answers, ids}} =
             Sensor.observe(frame(%{stdout: "looks safe"}))

    assert "scope_drift" in Enum.map(ids, &to_string/1)
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "configured concrete model drift is semantic degradation, not authority" do
    previous = Application.get_env(:autonomic_typesafe, :allowed_models, [])
    Application.put_env(:autonomic_typesafe, :allowed_models, ["jev-approved"])
    on_exit(fn -> Application.put_env(:autonomic_typesafe, :allowed_models, previous) end)

    client = TypeSafeSDK.Test.client(model: "jev-other")
    client = safe_stub(client, model: "jev-other")
    assert :ok = Bank.install_client(client)

    assert {:error, {:concrete_model_drift, "jev-other", ["jev-approved"]}} =
             Sensor.observe(frame(%{}))

    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "transport outage degrades semantic health and never produces a safe observation" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")
    client = TypeSafeSDK.Test.stub_transport_error(client, :econnrefused)
    assert :ok = Bank.install_client(client)
    assert {:error, _} = Sensor.observe(frame(%{}))
    assert Autonomic.SystemRegulator.snapshot().health.semantic == :degraded
    refute Autonomic.SystemRegulator.sensitive_commit_allowed?()
    Autonomic.SystemRegulator.semantic_health(:healthy)
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "relied-on transport capabilities are required fail closed" do
    previous = Application.get_env(:autonomic_typesafe, :required_capabilities, [])
    Application.put_env(:autonomic_typesafe, :required_capabilities, [:bounded_queue])
    on_exit(fn -> Application.put_env(:autonomic_typesafe, :required_capabilities, previous) end)

    client = TypeSafeSDK.Test.client(model: "jev-fixture")
    assert {:error, %TypeSafeSDK.Error{type: :runtime_capability}} = Bank.install_client(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  defp safe_stub(client, opts) do
    TypeSafeSDK.Test.stub(
      client,
      [
        scope_drift: {:noul, 0.01},
        authority_escalation: {:noul, 0.01},
        evidence_sufficiency:
          {:score, 2.0, probabilities: %{0 => 0.0, 1 => 0.0, 2 => 1.0}, confidence: 0.99},
        irreversibility:
          {:score, 1.0,
           probabilities: %{0 => 0.0, 1 => 1.0, 2 => 0.0, 3 => 0.0, 4 => 0.0}, confidence: 0.99},
        trajectory_regime:
          {:choice, :stable,
           probabilities: %{stable: 0.99, uncertain: 0.005, drifting: 0.003, unstable: 0.002},
           confidence: 0.99}
      ],
      opts
    )
  end

  defp score_answer(score, probabilities, labels) do
    %{
      "type" => "score",
      "score" => score,
      "confidence" => Enum.max(probabilities),
      "legend" =>
        labels |> Enum.with_index() |> Map.new(fn {label, i} -> {Integer.to_string(i), label} end),
      "probabilities" =>
        probabilities
        |> Enum.with_index()
        |> Map.new(fn {value, i} -> {Integer.to_string(i), value} end)
    }
  end

  defp frame(observable) do
    %ObservationFrame{
      episode_id: String.duplicate("a", 32),
      epoch: 1,
      sequence: 1,
      observed_at: Canonical.now(),
      deterministic: [%{type: :effect_evaluation}],
      effect_context: %{class: :class_3_authoritative_external_mutation},
      metadata: %{observable: observable}
    }
  end
end
