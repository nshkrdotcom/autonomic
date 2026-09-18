defmodule Autonomic.Dev.ScriptedSensor do
  @moduledoc "Deterministic semantic sensor for examples. Never use as production evidence."
  @behaviour Autonomic.SemanticSensor
  use Agent

  alias Autonomic.{Canonical, SemanticObservation}

  def start_link(_opts),
    do: Agent.start_link(fn -> %{queue: [], default: safe_observations()} end, name: __MODULE__)

  def reset, do: Agent.update(__MODULE__, fn _ -> %{queue: [], default: safe_observations()} end)
  def script(entries) when is_list(entries), do: Agent.update(__MODULE__, &%{&1 | queue: entries})
  def default(entry), do: Agent.update(__MODULE__, &%{&1 | default: entry})
  def safe, do: safe_observations()

  @impl true
  def observe(_frame, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.queue do
        [entry | rest] -> {normalize(entry), %{state | queue: rest}}
        [] -> {normalize(state.default), state}
      end
    end)
  end

  defp normalize({:unavailable, reason}), do: {:error, reason}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize({:ok, observations}), do: {:ok, Enum.map(observations, &observation/1)}

  defp normalize(observations) when is_list(observations),
    do: {:ok, Enum.map(observations, &observation/1)}

  defp observation(%SemanticObservation{} = value), do: value

  defp observation(map) when is_map(map) do
    %SemanticObservation{
      sensor: Map.fetch!(map, :sensor),
      value: Map.fetch!(map, :value),
      confidence: Map.get(map, :confidence, 1.0),
      probabilities: Map.get(map, :probabilities),
      model: Map.get(map, :model, "scripted-example"),
      requested_model: Map.get(map, :requested_model, "scripted-example"),
      request_id: Map.get(map, :request_id, "scripted-#{Canonical.id()}"),
      sdk_version: "example",
      sensor_bank_version: "example-v1",
      semantic_contract_id: "example-only",
      usage: %{},
      retries: 0,
      latency_ms: 0,
      observed_at: Canonical.now(),
      metadata: Map.get(map, :metadata, %{simulated: true})
    }
  end

  defp safe_observations do
    [
      %{sensor: :scope_drift, value: false, confidence: 1.0},
      %{sensor: :authority_escalation, value: false, confidence: 1.0},
      %{sensor: :evidence_sufficiency, value: :sufficient, confidence: 1.0},
      %{sensor: :trajectory_regime, value: :stable, confidence: 1.0}
    ]
  end
end
