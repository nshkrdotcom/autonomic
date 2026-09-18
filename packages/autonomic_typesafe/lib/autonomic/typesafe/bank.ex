defmodule Autonomic.Typesafe.Bank do
  @moduledoc """
  Bounded TypeSafeSDK 0.4 semantic bank for Autonomic observations.

  Evaluations run through `TypeSafeSDK.OTP.Server`, using the caller-owned
  `Autonomic.Typesafe.Tasks` supervisor and Pristine cancellation. The GenServer remains
  responsive while semantic HTTP work is in flight; `max_in_flight` provides an
  explicit local bound without introducing another HTTP queue or retry engine.
  """

  use TypeSafeSDK.OTP.Server

  alias Autonomic.{Canonical, SemanticObservation, SystemRegulator}
  alias Autonomic.Typesafe.{Evidence, SensorBank}
  alias TypeSafeSDK.{Answer, Client, Error, Prepared, Response, RuntimeCapabilities}

  @start_options [:client, :task_supervisor, :max_in_flight, :name]
  @observe_options [:mode]

  def start_link(opts) when is_list(opts) do
    with :ok <- validate_start_options(opts),
         {:ok, client} <- client(opts),
         :ok <- runtime_check(client) do
      prepared = SensorBank.prepare!()
      contract_id = SensorBank.contract_id(prepared)
      runtime_capabilities = RuntimeCapabilities.report(client)

      server_opts = [
        client: client,
        task_supervisor: Keyword.get(opts, :task_supervisor, Autonomic.Typesafe.Tasks),
        max_in_flight: Keyword.get(opts, :max_in_flight, config(:max_in_flight, 8)),
        evaluation_options: evaluation_defaults(),
        init_arg: %{
          prepared: prepared,
          bank_version: SensorBank.version(),
          contract_id: contract_id,
          requested_model: config(:model, "jev-latest"),
          runtime_capabilities: runtime_capabilities
        },
        name: Keyword.get(opts, :name, __MODULE__)
      ]

      TypeSafeSDK.OTP.Server.start_link(__MODULE__, server_opts)
    end
  end

  def start_link(_opts),
    do: {:error, Error.invalid_request(["autonomic", "bank_options"], "must be a keyword list")}

  @doc false
  @spec configured_client() :: {:ok, Client.t()} | :not_configured
  def configured_client do
    case configured_api_key() do
      nil ->
        :not_configured

      key ->
        {:ok,
         TypeSafeSDK.new_client(
           api_key: key,
           model: config(:model, "jev-latest"),
           timeout_ms: config(:timeout_ms, 3_000),
           retry: false
         )}
    end
  end

  @spec observe(Autonomic.ObservationFrame.t(), keyword()) ::
          {:ok, [SemanticObservation.t()]} | {:error, term()}
  def observe(frame, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        SystemRegulator.semantic_health(:unavailable)
        {:error, :typesafe_not_configured}

      _pid ->
        call_observe(frame, opts)
    end
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{available: false, last_error: :typesafe_not_configured}
      _pid -> GenServer.call(__MODULE__, :status)
    end
  end

  @impl true
  def init(%{
        prepared: %Prepared{} = prepared,
        bank_version: bank_version,
        contract_id: contract_id,
        requested_model: requested_model,
        runtime_capabilities: runtime_capabilities
      }) do
    {:ok,
     %{
       prepared: prepared,
       bank_version: bank_version,
       contract_id: contract_id,
       requested_model: requested_model,
       runtime_capabilities: runtime_capabilities,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       available: true,
       bank_version: state.bank_version,
       semantic_contract_id: state.contract_id,
       requested_model: state.requested_model,
       runtime_capabilities: state.runtime_capabilities,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:observe, frame, opts}, from, state) do
    case prepare_evaluation(frame, opts, state) do
      {:ok, semantic_state, budget, evaluation_opts} ->
        tag = %{
          from: from,
          budget: budget,
          requested_model: state.requested_model
        }

        {:evaluate, {tag, semantic_state, state.prepared, evaluation_opts}, state}

      {:error, reason} ->
        SystemRegulator.semantic_health(:degraded)
        {:reply, {:error, reason}, %{state | last_error: error_status(reason)}}
    end
  end

  @impl true
  def handle_evaluation(result, tag, state) do
    normalized = normalize_evaluation(result, tag, state)

    next_state =
      case normalized do
        {:ok, _observations} ->
          SystemRegulator.semantic_health(:healthy)
          %{state | last_error: nil}

        {:error, reason} ->
          SystemRegulator.semantic_health(:degraded)
          %{state | last_error: error_status(reason)}
      end

    GenServer.reply(tag.from, normalized)
    {:noreply, next_state}
  end

  defp call_observe(frame, opts) do
    with :ok <- validate_observe_options(opts) do
      try do
        # TypeSafe/Pristine own the request timeout. Avoid a second GenServer-call
        # timeout that could abandon an in-flight semantic task after the SDK has
        # already established bounded cancellation and max_in_flight semantics.
        GenServer.call(__MODULE__, {:observe, frame, opts}, :infinity)
      catch
        :exit, {:noproc, _call} ->
          SystemRegulator.semantic_health(:unavailable)
          {:error, :typesafe_not_configured}
      end
    end
  end

  defp prepare_evaluation(frame, opts, state) do
    evidence_limit = config(:evidence_limit, 32_768)

    with {:ok, semantic_state, budget} <- Evidence.bounded(frame, evidence_limit) do
      evaluation_opts = [
        timeout_ms: timeout(opts),
        telemetry_metadata: %{
          episode_id: frame.episode_id,
          epoch: frame.epoch,
          sequence: frame.sequence,
          sensor_bank: state.bank_version,
          semantic_contract_id: state.contract_id
        }
      ]

      {:ok, semantic_state, budget, evaluation_opts}
    end
  end

  defp normalize_evaluation({:ok, response}, tag, state) do
    with :ok <- validate_prepared_fingerprint(response, state.contract_id),
         :ok <- reject_unknown_required(response),
         {:ok, observations} <- normalize(response, tag.requested_model, state, tag.budget) do
      {:ok, observations}
    end
  end

  defp normalize_evaluation({:error, %Error{} = error}, _tag, _state), do: {:error, error}
  defp normalize_evaluation({:error, reason}, _tag, _state), do: {:error, reason}

  defp normalize(response, requested_model, state, budget) do
    scope = Response.fetch!(response, :scope_drift)
    authority = Response.fetch!(response, :authority_escalation)
    evidence = Response.fetch!(response, :evidence_sufficiency)
    irreversible = Response.fetch!(response, :irreversibility)
    regime = Response.fetch!(response, :trajectory_regime)
    metadata = Response.metadata(response)
    request_id = Response.request_id!(response)
    now = Canonical.now()

    common = %{
      model: response.model,
      requested_model: requested_model,
      request_id: request_id,
      sdk_version: TypeSafeSDK.version(),
      sensor_bank_version: state.bank_version,
      semantic_contract_id: state.contract_id,
      usage: metadata.usage,
      retries: metadata.retries,
      latency_ms: metadata.elapsed_ms,
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
    _error -> {:error, :response_normalization_failed}
  end

  defp score_observation(sensor, answer, common, budget) do
    {level, label} = Answer.Score.expected_level(answer)

    struct!(
      SemanticObservation,
      Map.merge(common, %{
        sensor: sensor,
        value:
          if(sensor == :evidence_sufficiency, do: label, else: Answer.Score.normalized(answer)),
        confidence: Answer.confidence(answer),
        probabilities: answer.probabilities,
        metadata: %{
          expected_level: level,
          expected_label: label,
          modal: modal_entry(Answer.Score.max_level(answer)),
          ranked: ranked_entries(Answer.Score.ranked(answer)),
          normalized: Answer.Score.normalized(answer),
          budget: budget
        }
      })
    )
  end

  defp validate_prepared_fingerprint(response, expected) do
    case Response.metadata(response).prepared_fingerprint do
      ^expected -> :ok
      actual -> {:error, {:semantic_contract_fingerprint_mismatch, actual, expected}}
    end
  end

  defp reject_unknown_required(response) do
    case Map.keys(response.unknown_answers || %{}) do
      [] -> :ok
      keys -> {:error, {:unknown_required_answers, keys}}
    end
  end

  defp evaluation_defaults do
    [
      model: config(:model, "jev-latest"),
      retry: false,
      max_request_bytes: config(:request_limit, 65_536),
      response_contract: [
        on_unknown_answer: :error,
        allowed_models: allowed_models_contract()
      ]
    ]
  end

  defp allowed_models_contract do
    case config(:allowed_models, []) do
      [] -> nil
      models -> models
    end
  end

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, %Client{} = client} ->
        {:ok, client}

      {:ok, _other} ->
        {:error, Error.configuration("Autonomic.Typesafe.Bank requires a TypeSafeSDK.Client")}

      :error ->
        case configured_client() do
          {:ok, client} -> {:ok, client}
          :not_configured -> {:error, Error.configuration("TypeSafeSDK is not configured")}
        end
    end
  end

  defp runtime_check(client), do: RuntimeCapabilities.check(client, runtime_requirements())

  defp runtime_requirements do
    (required_capabilities() ++ config(:required_capabilities, []))
    |> Enum.uniq()
  end

  defp required_capabilities, do: [:unary_cancellation, :cancellation_cleanup]

  defp validate_start_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, Error.invalid_request(["autonomic", "bank_options"], "must be a keyword list")}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error,
         Error.invalid_request(
           ["autonomic", "bank_options"],
           "duplicate options are not allowed"
         )}

      Keyword.keys(opts) -- @start_options != [] ->
        {:error, Error.invalid_request(["autonomic", "bank_options"], "unknown option")}

      true ->
        :ok
    end
  end

  defp validate_observe_options(opts) do
    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error,
         Error.invalid_request(["autonomic", "observe_options"], "must be a keyword list")}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error,
         Error.invalid_request(
           ["autonomic", "observe_options"],
           "duplicate options are not allowed"
         )}

      Keyword.keys(opts) -- @observe_options != [] ->
        {:error, Error.invalid_request(["autonomic", "observe_options"], "unknown option")}

      Keyword.get(opts, :mode, :fast) not in [:fast, :slow] ->
        {:error,
         Error.invalid_request(
           ["autonomic", "observe_options", "mode"],
           "must be :fast or :slow"
         )}

      true ->
        :ok
    end
  end

  defp error_status(%Error{} = error), do: Error.metadata(error)
  defp error_status(reason) when is_atom(reason), do: %{type: :local, code: reason}

  defp error_status(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> %{type: :local, code: code}
      _other -> %{type: :local, code: :unknown}
    end
  end

  defp error_status(_reason), do: %{type: :local, code: :unknown}

  defp ranked_entries(entries),
    do:
      Enum.map(entries, fn {value, probability} -> %{value: value, probability: probability} end)

  defp modal_entry(nil), do: nil
  defp modal_entry({level, label}), do: %{level: level, label: label}

  defp timeout(opts) do
    if Keyword.get(opts, :mode) == :slow,
      do: config(:slow_timeout_ms, 10_000),
      else: config(:timeout_ms, 3_000)
  end

  defp configured_api_key do
    config(:api_key, nil)
    |> blank_to_nil()
    |> then(fn configured -> configured || blank_to_nil(System.get_env("TYPESAFE_API_KEY")) end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp config(key, default), do: Application.get_env(:autonomic_typesafe, key, default)
end
