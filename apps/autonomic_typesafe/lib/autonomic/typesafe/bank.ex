defmodule Autonomic.Typesafe.Bank do
  @moduledoc "Prepared-once TypeSafeSDK 0.2 semantic bank with fail-closed model/unknown-answer/runtime contracts."
  use GenServer

  alias Autonomic.{Canonical, SemanticObservation, SystemRegulator}
  alias Autonomic.Typesafe.{Evidence, SensorBank}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def observe(frame, opts \\ []),
    do: GenServer.call(__MODULE__, {:observe, frame, opts}, timeout(opts) + 5_000)

  def status, do: GenServer.call(__MODULE__, :status)
  def install_client(client), do: GenServer.call(__MODULE__, {:install_client, client})

  @impl true
  def init(_) do
    prepared = SensorBank.prepare!()

    state = %{
      prepared: prepared,
      client: build_client(),
      bank_version: SensorBank.version(),
      contract_id: SensorBank.contract_id(),
      last_error: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     Map.drop(state, [:prepared, :client]) |> Map.put(:available, not is_nil(state.client)),
     state}
  end

  def handle_call({:install_client, client}, _from, state) do
    case runtime_check(client) do
      :ok -> {:reply, :ok, %{state | client: client, last_error: nil}}
      {:error, _} = error -> {:reply, error, %{state | client: nil, last_error: error}}
    end
  end

  def handle_call({:observe, _frame, _opts}, _from, %{client: nil} = state) do
    SystemRegulator.semantic_health(:unavailable)
    {:reply, {:error, :typesafe_not_configured}, state}
  end

  def handle_call({:observe, frame, opts}, _from, state) do
    evidence_limit = Application.get_env(:autonomic_typesafe, :evidence_limit, 32_768)
    request_limit = Application.get_env(:autonomic_typesafe, :request_limit, 65_536)
    requested_model = Application.get_env(:autonomic_typesafe, :model, "jev-latest")

    result =
      with :ok <- runtime_check(state.client),
           {:ok, semantic_state, budget} <- Evidence.bounded(frame, evidence_limit),
           true <- byte_size(Jason.encode!(semantic_state)) + manifest_bytes() <= request_limit,
           {:ok, response} <-
             TypeSafeSDK.evaluate(state.client, semantic_state, state.prepared,
               model: requested_model,
               retry: false,
               timeout_ms: timeout(opts),
               telemetry_metadata: %{
                 episode_id: frame.episode_id,
                 sensor_bank: state.bank_version,
                 semantic_contract_id: state.contract_id
               }
             ),
           :ok <- reject_unknown(response),
           :ok <- enforce_model(response.model),
           {:ok, observations} <- normalize(response, requested_model, state, budget) do
        SystemRegulator.semantic_health(:healthy)
        {:ok, observations}
      else
        false -> {:error, :semantic_request_budget_exceeded}
        {:error, _} = error -> error
        other -> {:error, other}
      end

    case result do
      {:ok, _} ->
        {:reply, result, %{state | last_error: nil}}

      {:error, reason} ->
        SystemRegulator.semantic_health(:degraded)
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  defp build_client do
    key = Application.get_env(:autonomic_typesafe, :api_key) || System.get_env("TYPESAFE_API_KEY")

    if is_binary(key) and String.trim(key) != "" do
      TypeSafeSDK.new_client(
        api_key: key,
        model: Application.get_env(:autonomic_typesafe, :model, "jev-latest"),
        timeout_ms: Application.get_env(:autonomic_typesafe, :timeout_ms, 3_000),
        retry: false,
        runtime_requirements: Application.get_env(:autonomic_typesafe, :required_capabilities, [])
      )
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp runtime_check(client) do
    TypeSafeSDK.RuntimeCapabilities.check(
      client,
      Application.get_env(:autonomic_typesafe, :required_capabilities, [])
    )
  end

  defp reject_unknown(response) do
    if map_size(response.unknown_answers || %{}) == 0,
      do: :ok,
      else: {:error, {:unknown_required_answers, Map.keys(response.unknown_answers)}}
  end

  defp enforce_model(actual) do
    allowed = Application.get_env(:autonomic_typesafe, :allowed_models, [])

    if allowed == [] or actual in allowed,
      do: :ok,
      else: {:error, {:concrete_model_drift, actual, allowed}}
  end

  defp normalize(response, requested_model, state, budget) do
    alias TypeSafeSDK.{Answer, Response}
    scope = Response.fetch!(response, :scope_drift)
    authority = Response.fetch!(response, :authority_escalation)
    evidence = Response.fetch!(response, :evidence_sufficiency)
    irreversible = Response.fetch!(response, :irreversibility)
    regime = Response.fetch!(response, :trajectory_regime)
    now = Canonical.now()

    common = %{
      model: response.model,
      requested_model: requested_model,
      request_id: safe_request_id(response),
      sdk_version: TypeSafeSDK.version(),
      sensor_bank_version: state.bank_version,
      semantic_contract_id: state.contract_id,
      usage: usage(response.usage),
      retries: response.retries,
      latency_ms: response.elapsed_ms,
      observed_at: now
    }

    observations = [
      struct!(
        SemanticObservation,
        Map.merge(common, %{
          sensor: :scope_drift,
          value: Answer.Noul.yes?(scope, 0.5),
          confidence: Answer.Noul.confidence(scope),
          probabilities: %{true => scope.noul, false => 1.0 - scope.noul},
          metadata: %{budget: budget}
        })
      ),
      struct!(
        SemanticObservation,
        Map.merge(common, %{
          sensor: :authority_escalation,
          value: Answer.Noul.yes?(authority, 0.5),
          confidence: Answer.Noul.confidence(authority),
          probabilities: %{true => authority.noul, false => 1.0 - authority.noul},
          metadata: %{budget: budget}
        })
      ),
      score_observation(:evidence_sufficiency, evidence, common, budget),
      score_observation(:irreversibility, irreversible, common, budget),
      struct!(
        SemanticObservation,
        Map.merge(common, %{
          sensor: :trajectory_regime,
          value: regime.choice,
          confidence: Answer.confidence(regime),
          probabilities: regime.probabilities,
          metadata: %{
            ranked: ranked_entries(Answer.Choice.ranked(regime)),
            margin: Answer.Choice.margin(regime),
            budget: budget
          }
        })
      )
    ]

    {:ok, observations}
  rescue
    error -> {:error, {:response_normalization_failed, error}}
  end

  defp score_observation(sensor, answer, common, budget) do
    {level, label} = TypeSafeSDK.Answer.Score.expected_level(answer)

    struct!(
      SemanticObservation,
      Map.merge(common, %{
        sensor: sensor,
        value:
          if(sensor == :evidence_sufficiency,
            do: label,
            else: TypeSafeSDK.Answer.Score.normalized(answer)
          ),
        confidence: TypeSafeSDK.Answer.confidence(answer),
        probabilities: answer.probabilities,
        metadata: %{
          expected_level: level,
          expected_label: label,
          modal: modal_entry(TypeSafeSDK.Answer.Score.max_level(answer)),
          ranked: ranked_entries(TypeSafeSDK.Answer.Score.ranked(answer)),
          normalized: TypeSafeSDK.Answer.Score.normalized(answer),
          budget: budget
        }
      })
    )
  end

  defp ranked_entries(entries),
    do:
      Enum.map(entries, fn {value, probability} -> %{value: value, probability: probability} end)

  defp modal_entry(nil), do: nil
  defp modal_entry({level, label}), do: %{level: level, label: label}

  defp safe_request_id(response) do
    TypeSafeSDK.Response.request_id!(response)
  rescue
    _ -> response.request_id
  end

  defp usage(%TypeSafeSDK.Usage{} = value), do: Map.from_struct(value)

  defp manifest_bytes, do: SensorBank.manifest() |> Jason.encode!() |> byte_size()

  defp timeout(opts),
    do:
      if(Keyword.get(opts, :mode) == :slow,
        do: Application.get_env(:autonomic_typesafe, :slow_timeout_ms, 10_000),
        else: Application.get_env(:autonomic_typesafe, :timeout_ms, 3_000)
      )
end
