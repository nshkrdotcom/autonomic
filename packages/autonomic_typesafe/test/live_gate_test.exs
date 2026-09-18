defmodule Autonomic.Typesafe.LiveGateTest do
  use ExUnit.Case, async: false

  alias Autonomic.{Canonical, ObservationFrame}
  alias Autonomic.Typesafe.{Bank, Sensor}

  @moduletag :live
  @moduletag timeout: 120_000

  test "production TypeSafe 0.4 evaluate gate records non-secret provenance" do
    key = System.get_env("TYPESAFE_API_KEY")

    assert is_binary(key) and String.trim(key) != "",
           "TYPESAFE_API_KEY is required for the live gate"

    requested_model = Application.get_env(:autonomic_typesafe, :model, "jev-latest")
    requirements =
      ([:unary_cancellation, :cancellation_cleanup] ++
         Application.fetch_env!(:autonomic_typesafe, :required_capabilities))
      |> Enum.uniq()

    client =
      TypeSafeSDK.new_client(
        api_key: key,
        model: requested_model,
        timeout_ms: 15_000,
        retry: false,
        runtime_requirements: requirements
      )

    assert :ok = TypeSafeSDK.RuntimeCapabilities.check(client, requirements)
    start_supervised!({Bank, client: client})

    frame = %ObservationFrame{
      episode_id: String.duplicate("f", 32),
      epoch: 1,
      sequence: 1,
      observed_at: Canonical.now(),
      deterministic: [%{type: :effect_evaluation, effect_class: 2}],
      effect_context: %{class: :class_2_external_observable_or_compensatable, kind: :http_read},
      metadata: %{
        observable: %{
          task: "Read public documentation through the trusted broker and summarize one section.",
          emitted_plan: "Read only; no mutation; remain within the declared task.",
          stdout_window: "request prepared"
        }
      }
    }

    assert {:ok, observations} = Sensor.observe(frame, mode: :slow)
    assert length(observations) == 5
    first = hd(observations)
    assert is_binary(first.request_id) and first.request_id != ""
    assert is_binary(first.model) and first.model != ""
    assert first.sdk_version == TypeSafeSDK.version()
    assert first.semantic_contract_id == Bank.status().semantic_contract_id

    provenance = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      sdk_version: first.sdk_version,
      requested_model: first.requested_model,
      actual_model: first.model,
      request_id: first.request_id,
      usage: first.usage,
      retries: first.retries,
      timing_ms: first.latency_ms,
      sensor_bank_version: first.sensor_bank_version,
      semantic_contract_id: first.semantic_contract_id,
      runtime_capabilities: TypeSafeSDK.RuntimeCapabilities.report(client),
      answers:
        Enum.map(observations, &%{sensor: &1.sensor, value: &1.value, confidence: &1.confidence})
    }

    path = Path.expand("../../../artifacts/typesafe_live_gate.json", __DIR__)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(provenance, pretty: true) <> "\n")

    refute File.read!(path) =~ key
  end
end
