defmodule Autonomic.Typesafe.SensorComponentTest do
  use ExUnit.Case, async: false

  alias Autonomic.{Canonical, ObservationFrame}
  alias Autonomic.Typesafe.{Bank, Evidence, Sensor, SensorBank}

  test "prepared bank uses TypeSafeSDK 0.4 contracts and preserves provenance" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture") |> safe_stub(model: "jev-fixture")
    start_bank(client)

    frame = frame(%{stdout: "all tests passed"})
    assert {:ok, observations} = Sensor.observe(frame)

    assert Enum.map(observations, & &1.sensor) == [
             :scope_drift,
             :authority_escalation,
             :evidence_sufficiency,
             :irreversibility,
             :trajectory_regime
           ]

    status = Bank.status()
    assert status.available
    assert status.semantic_contract_id =~ "typesafe-prepared-v1:"
    assert status.semantic_contract_id == SensorBank.contract_id(SensorBank.prepare!())
    assert get_in(status, [:runtime_capabilities, :runtime, :unary_cancellation, :status]) == :supported
    assert get_in(status, [:runtime_capabilities, :runtime, :cancellation_cleanup, :status]) == :supported

    assert Enum.all?(observations, &(&1.sensor_bank_version == SensorBank.version()))
    assert Enum.all?(observations, &(&1.semantic_contract_id == status.semantic_contract_id))
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

  test "semantic contract identity is the SDK Prepared fingerprint" do
    prepared = SensorBank.prepare!()

    assert SensorBank.contract_id(prepared) == TypeSafeSDK.Prepared.fingerprint(prepared)
    assert SensorBank.contract_id(prepared) =~ "typesafe-prepared-v1:"
  end

  test "future answer types for required sensors fail closed" do
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
    start_bank(client)

    assert {:error, {:unknown_required_answers, ids}} = Sensor.observe(frame(%{stdout: "looks safe"}))
    assert "scope_drift" in Enum.map(ids, &to_string/1)
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "configured concrete model drift is rejected by the SDK response contract" do
    previous = Application.get_env(:autonomic_typesafe, :allowed_models, [])
    Application.put_env(:autonomic_typesafe, :allowed_models, ["jev-approved"])
    on_exit(fn -> Application.put_env(:autonomic_typesafe, :allowed_models, previous) end)

    client = TypeSafeSDK.Test.client(model: "jev-other") |> safe_stub(model: "jev-other")
    start_bank(client)

    assert {:error,
            %TypeSafeSDK.Error{
              type: :response_contract,
              details: %{violation: :model_not_allowed}
            }} = Sensor.observe(frame(%{}))

    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "the SDK exact serialized-request budget rejects oversize requests before transport" do
    previous = Application.get_env(:autonomic_typesafe, :request_limit, 65_536)
    Application.put_env(:autonomic_typesafe, :request_limit, 256)
    on_exit(fn -> Application.put_env(:autonomic_typesafe, :request_limit, previous) end)

    client = TypeSafeSDK.Test.client(model: "jev-fixture") |> safe_stub(model: "jev-fixture")
    start_bank(client)

    assert {:error,
            %TypeSafeSDK.Error{
              type: :request_too_large,
              details: %{actual_bytes: actual, max_bytes: 256}
            }} = Sensor.observe(frame(%{stdout: String.duplicate("x", 64)}))

    assert actual > 256
    assert TypeSafeSDK.Test.requests(client) == []
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "TypeSafe OTP integration stays responsive and enforces max_in_flight" do
    owner = self()
    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    client =
      TypeSafeSDK.Test.stub_callback(client, fn _request ->
        send(owner, {:typesafe_request_started, self()})

        receive do
          :release_typesafe_request ->
            {:answers, safe_specs(), [model: "jev-fixture"]}
        end
      end)

    start_bank(client, max_in_flight: 1)

    first = Task.async(fn -> Sensor.observe(frame(%{stdout: "first"}), mode: :slow) end)
    assert_receive {:typesafe_request_started, worker}, 2_000

    # The bank is not blocked by the network task, and semantic work lives on
    # the adapter-owned task supervisor rather than Autonomic.Tasks.
    assert %{available: true, last_error: nil} = Bank.status()
    assert Task.Supervisor.children(Autonomic.Typesafe.Tasks) != []

    assert {:error,
            %TypeSafeSDK.Error{
              type: :runtime_capability,
              details: %{scope: :otp_server, max_in_flight: 1}
            }} = Sensor.observe(frame(%{stdout: "second"}), mode: :slow)

    send(worker, :release_typesafe_request)
    assert {:ok, observations} = Task.await(first, 5_000)
    assert length(observations) == 5
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "observe options are strict and rejected before transport" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture") |> safe_stub(model: "jev-fixture")
    start_bank(client)

    assert {:error, %TypeSafeSDK.Error{type: :invalid_request}} =
             Sensor.observe(frame(%{}), mode: :slow, mode: :fast)

    assert {:error, %TypeSafeSDK.Error{type: :invalid_request}} =
             Sensor.observe(frame(%{}), mode: :unsupported)

    assert {:error, %TypeSafeSDK.Error{type: :invalid_request}} =
             Sensor.observe(frame(%{}), %{mode: :slow})

    assert TypeSafeSDK.Test.requests(client) == []
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "transport outage degrades semantic health and never produces a safe observation" do
    client = TypeSafeSDK.Test.client(model: "jev-fixture")
    client = TypeSafeSDK.Test.stub_transport_error(client, :econnrefused)
    start_bank(client)

    assert {:error, %TypeSafeSDK.Error{type: :connection}} = Sensor.observe(frame(%{}))
    status = Bank.status()
    assert %{type: :connection} = status.last_error
    refute Map.has_key?(status.last_error, :body)
    assert Autonomic.SystemRegulator.snapshot().health.semantic == :degraded
    refute Autonomic.SystemRegulator.sensitive_commit_allowed?()
    Autonomic.SystemRegulator.semantic_health(:healthy)
    assert :ok = TypeSafeSDK.Test.verify!(client)
    assert :ok = TypeSafeSDK.Test.close(client)
  end

  test "relied-on runtime capabilities are required fail closed" do
    previous = Application.get_env(:autonomic_typesafe, :required_capabilities, [])
    Application.put_env(:autonomic_typesafe, :required_capabilities, [:bounded_queue])
    on_exit(fn -> Application.put_env(:autonomic_typesafe, :required_capabilities, previous) end)

    client = TypeSafeSDK.Test.client(model: "jev-fixture")

    assert {:error, %TypeSafeSDK.Error{type: :runtime_capability}} =
             Bank.start_link(client: client, name: :autonomic_typesafe_capability_failure)

    assert :ok = TypeSafeSDK.Test.close(client)
  end

  defp start_bank(client, opts \\ []) do
    start_supervised!({Bank, Keyword.merge([client: client], opts)})
  end

  defp safe_stub(client, opts), do: TypeSafeSDK.Test.stub(client, safe_specs(), opts)

  defp safe_specs do
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
    ]
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
