defmodule Autonomic.EffectBroker do
  @moduledoc "Durable MVCC effect broker. This is the only trusted path to authoritative adapters."
  use GenServer

  alias Autonomic.{
    AuthorityGovernor,
    Canonical,
    EffectState,
    ObservationFrame,
    Payloads,
    Policy,
    ProposedEffect,
    Runtime,
    SystemRegulator,
    VersionVector
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def prepare(attrs, opts \\ []), do: GenServer.call(__MODULE__, {:prepare, attrs, opts}, 30_000)

  def evaluate(effect_id, opts \\ []),
    do: GenServer.call(__MODULE__, {:evaluate, effect_id, opts}, 60_000)

  def commit(effect_id, opts \\ []),
    do: GenServer.call(__MODULE__, {:commit, effect_id, opts}, 120_000)

  def abort(effect_id, reason \\ :caller_abort),
    do: GenServer.call(__MODULE__, {:abort, effect_id, reason}, 30_000)

  def reconcile(effect_id, opts \\ []),
    do: GenServer.call(__MODULE__, {:reconcile, effect_id, opts}, 60_000)

  def reconcile_pending, do: GenServer.call(__MODULE__, :reconcile_pending, 120_000)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_) do
    Process.send_after(self(), :reconcile_after_boot, 2_000)

    {:ok, %{active: 0, limit: max(Application.get_env(:autonomic, :effect_concurrency, 8), 1)}}
  end

  @impl true
  def handle_info(:reconcile_after_boot, state) do
    case start_work(nil, &do_reconcile_pending/0, state) do
      {:ok, next} -> {:noreply, next}
      {:saturated, next} -> {:noreply, next}
      {:error, next} -> {:noreply, next}
    end
  end

  def handle_info({:broker_result, from, result}, state) do
    if from, do: GenServer.reply(from, result)
    next = %{state | active: max(state.active - 1, 0)}
    report_pressure(next)
    {:noreply, next}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  def handle_call({:prepare, attrs, opts}, from, state),
    do: dispatch(from, state, fn -> do_prepare(attrs, opts) end)

  def handle_call({:evaluate, id, opts}, from, state),
    do: dispatch(from, state, fn -> do_evaluate(id, opts) end)

  def handle_call({:commit, id, opts}, from, state),
    do: dispatch(from, state, fn -> do_commit(id, opts) end)

  def handle_call({:abort, id, reason}, from, state),
    do: dispatch(from, state, fn -> Runtime.store().abort_effect(id, reason) end)

  def handle_call({:reconcile, id, opts}, from, state),
    do: dispatch(from, state, fn -> do_reconcile(id, opts) end)

  def handle_call(:reconcile_pending, from, state),
    do: dispatch(from, state, &do_reconcile_pending/0)

  defp dispatch(from, state, fun) do
    case start_work(from, fun, state) do
      {:ok, next} -> {:noreply, next}
      {:saturated, next} -> {:reply, {:error, :effect_broker_saturated}, next}
      {:error, next} -> {:reply, {:error, :effect_worker_unavailable}, next}
    end
  end

  defp start_work(from, fun, %{active: active, limit: limit} = state) when active < limit do
    owner = self()

    case Task.Supervisor.start_child(Autonomic.Tasks, fn ->
           result =
             try do
               fun.()
             rescue
               error -> {:error, {:broker_worker_exception, Exception.message(error)}}
             catch
               kind, reason -> {:error, {:broker_worker_caught, kind, inspect(reason)}}
             end

           send(owner, {:broker_result, from, result})
         end) do
      {:ok, _pid} ->
        next = %{state | active: active + 1}
        report_pressure(next)
        {:ok, next}

      {:error, _reason} ->
        SystemRegulator.report(:effect_queue, 1.0)
        {:error, state}
    end
  end

  defp start_work(_from, _fun, state) do
    SystemRegulator.report(:effect_queue, 1.0)
    {:saturated, state}
  end

  defp report_pressure(%{active: active, limit: limit}) do
    SystemRegulator.report(:effect_queue, active / limit)
  end

  defp do_prepare(attrs, opts) when is_map(attrs) do
    with {:ok, episode_id} <- required(attrs, :episode_id),
         {:ok, lease_id} <- required(attrs, :lease_id),
         {:ok, kind} <- required(attrs, :kind),
         {:ok, target_id} <- required(attrs, :target_id),
         {:ok, episode} <- Runtime.store().fetch_episode(episode_id),
         {:ok, {adapter, class}} <- Runtime.adapter(to_string(kind)),
         {:ok, trusted_target} <- Runtime.target(to_string(target_id)),
         true <- Policy.permits?(episode.policy, kind, public_target(attrs, target_id), class),
         :ok <-
           AuthorityGovernor.validate(
             episode_id,
             lease_id,
             normalize_kind(kind),
             public_target(attrs, target_id),
             class
           ),
         :ok <- ensure_admitted(class),
         {:ok, payload_ref, payload_digest} <- payload(episode_id, attrs, opts),
         effect <-
           build_effect(
             attrs,
             episode,
             lease_id,
             kind,
             class,
             target_id,
             payload_ref,
             payload_digest
           ),
         :ok <- adapter.validate(effect, Keyword.put(opts, :trusted_target, trusted_target)),
         :ok <- Runtime.store().put_effect(effect),
         {:ok, prepared} <- Runtime.store().prepare_existing_effect(effect.id) do
      {:ok, prepared}
    else
      false -> {:error, :policy_denied}
      :not_found -> {:error, :episode_not_found}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:prepare_failed, error}}
  end

  defp do_prepare(_, _), do: {:error, :invalid_effect_proposal}

  defp do_evaluate(effect_id, opts) do
    with {:ok, effect} <- Runtime.store().fetch_effect(effect_id),
         true <- effect.state in [:prepared, :evaluating],
         {:ok, episode} <- Runtime.store().fetch_episode(effect.episode_id),
         {:ok, {adapter, configured_class}} <- Runtime.adapter(to_string(effect.kind)),
         true <- configured_class == effect.class,
         {:ok, trusted_target} <- target_for(effect),
         :ok <- adapter.validate(effect, Keyword.put(opts, :trusted_target, trusted_target)),
         {:ok, effect} <- ensure_evaluating(effect),
         required <- Policy.required_decisions(episode.policy, effect.class),
         :ok <-
           record_allow(effect, :deterministic, "kernel:deterministic", %{
             checked_at: Canonical.now()
           }),
         :ok <- maybe_semantic(effect, episode, required, opts),
         :ok <- maybe_slow_verify(effect, required, opts),
         :ok <- maybe_human(effect, required, opts),
         {:ok, decisions} <- Runtime.store().effect_decisions(effect.id, effect.revision),
         :ok <- ensure_allows(required, decisions),
         {:ok, ready} <- Runtime.store().mark_effect_ready(effect.id) do
      {:ok, ready}
    else
      false -> {:error, :effect_not_evaluable}
      :not_found -> {:error, :effect_not_found}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:evaluation_failed, error}}
  end

  defp do_commit(effect_id, opts) do
    with {:ok, effect} <- Runtime.store().fetch_effect(effect_id),
         {:ok, episode} <- Runtime.store().fetch_episode(effect.episode_id),
         :ok <- sensitive_gate(effect.class),
         required <- Policy.required_decisions(episode.policy, effect.class),
         {:ok, intent} <- Runtime.store().begin_effect_commit(effect.id, required),
         {:ok, {adapter, configured_class}} <- Runtime.adapter(to_string(intent.kind)),
         true <- configured_class == intent.class,
         {:ok, trusted_target} <- target_for(intent),
         {:ok, committing} <- Runtime.store().mark_committing(intent.id) do
      commit_adapter(adapter, committing, Keyword.put(opts, :trusted_target, trusted_target))
    else
      false -> {:error, :effect_class_mismatch}
      :not_found -> {:error, :effect_not_found}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:commit_authorization_failed, error}}
  end

  # Any exception after commit_intent is ambiguous by default: never blind retry.
  defp commit_adapter(adapter, effect, opts) do
    case adapter.commit(effect, opts) do
      {:ok, receipt} ->
        Runtime.store().complete_effect(effect.id, :committed, %{
          receipt: receipt,
          receipt_ref: Map.get(receipt, :receipt_ref) || Map.get(receipt, "receipt_ref")
        })

      {:unknown, reason} ->
        Runtime.store().complete_effect(effect.id, :commit_unknown, %{
          failure: %{reason: inspect(reason)}
        })

      {:error, reason} ->
        Runtime.store().complete_effect(effect.id, :commit_unknown, %{
          failure: %{adapter_error: inspect(reason)}
        })
    end
  rescue
    error ->
      Runtime.store().complete_effect(effect.id, :commit_unknown, %{
        failure: %{exception: Exception.message(error)}
      })
  catch
    kind, reason ->
      Runtime.store().complete_effect(effect.id, :commit_unknown, %{
        failure: %{caught: inspect({kind, reason})}
      })
  end

  defp do_reconcile(effect_id, opts) do
    with {:ok, effect} <- Runtime.store().fetch_effect(effect_id),
         true <- effect.state in [:commit_intent, :committing, :commit_unknown],
         {:ok, {adapter, _}} <- Runtime.adapter(to_string(effect.kind)),
         {:ok, trusted_target} <- target_for(effect) do
      case adapter.reconcile(effect, Keyword.put(opts, :trusted_target, trusted_target)) do
        {:committed, receipt} ->
          Runtime.store().reconcile_effect(effect.id, :committed, %{receipt: receipt})

        :not_committed ->
          Runtime.store().reconcile_effect(effect.id, :not_committed, %{})

        {:unknown, reason} ->
          Runtime.store().reconcile_effect(effect.id, :unknown, %{
            failure: %{reason: inspect(reason)}
          })
      end
    else
      false -> {:error, :effect_not_reconcilable}
      :not_found -> {:error, :effect_not_found}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:reconciliation_failed, error}}
  end

  defp do_reconcile_pending do
    store = Runtime.store()

    if function_exported?(store, :pending_reconciliation, 0) do
      case store.pending_reconciliation() do
        {:ok, effects} ->
          {:ok, Enum.map(effects, fn effect -> {effect.id, do_reconcile(effect.id, [])} end)}

        error ->
          error
      end
    else
      {:error, :reconciliation_not_supported}
    end
  rescue
    error -> {:error, {:store_unavailable, error}}
  end

  defp maybe_semantic(effect, episode, required, _opts) do
    if "semantic" in Enum.map(required, &to_string/1) do
      frame = %ObservationFrame{
        episode_id: effect.episode_id,
        epoch: effect.epoch,
        sequence: System.unique_integer([:positive, :monotonic]),
        observed_at: Canonical.now(),
        deterministic: [%{type: :effect_evaluation, payload_digest: effect.payload_digest}],
        effect_context: %{
          class: effect.class,
          kind: effect.kind,
          target: effect.target,
          revision: effect.revision
        },
        metadata: %{mode: :effect_evaluation}
      }

      case Runtime.sensor().observe(frame, mode: :slow) do
        {:ok, observations} ->
          {decision, evidence} = semantic_decision(observations, episode.policy)

          record_decision(
            effect,
            :semantic,
            decision,
            "semantic:#{effect.id}:#{effect.revision}",
            evidence
          )

        {:error, reason} ->
          SystemRegulator.semantic_health(:degraded)
          {:error, {:semantic_unavailable, reason}}
      end
    else
      :ok
    end
  end

  defp semantic_decision(observations, policy) do
    threshold = get_in(policy, ["semantic", "max_risk"]) || 0.65

    risky =
      Enum.any?(observations, fn observation ->
        observation.sensor in [:scope_drift, :authority_escalation] and
          semantic_positive?(observation, threshold)
      end)

    sufficient =
      case Enum.find(observations, &(&1.sensor == :evidence_sufficiency)) do
        nil -> false
        obs -> evidence_sufficient?(obs)
      end

    decision = if not risky and sufficient, do: :allow, else: :deny

    {decision,
     %{
       observations: Enum.map(observations, &semantic_ref/1),
       sufficient: sufficient,
       risky: risky
     }}
  end

  defp maybe_slow_verify(effect, required, opts) do
    if "slow_verifier" in Enum.map(required, &to_string/1) do
      case Autonomic.Verifier.verify(effect, opts) do
        {:ok, evidence} ->
          record_allow(
            effect,
            :slow_verifier,
            "verifier:#{effect.id}:#{effect.revision}",
            evidence
          )

        {:error, reason} ->
          record_decision(
            effect,
            :slow_verifier,
            :deny,
            "verifier:#{effect.id}:#{effect.revision}",
            %{reason: inspect(reason)}
          )
      end
    else
      :ok
    end
  end

  defp maybe_human(effect, required, opts) do
    if "human" in Enum.map(required, &to_string/1) do
      record_human_approval(effect, opts)
    else
      :ok
    end
  end

  defp record_human_approval(effect, opts) do
    case Keyword.get(opts, :human_approval) do
      nil ->
        {:error, :human_approval_required}

      approval ->
        with :ok <- Autonomic.HumanApproval.verify(effect, approval) do
          record_allow(effect, :human, Map.get(approval, :source_ref, "human:approval"), %{
            approval: Map.drop(approval, [:signature])
          })
        end
    end
  end

  defp ensure_evaluating(%{state: :evaluating} = effect), do: {:ok, effect}
  defp ensure_evaluating(effect), do: Runtime.store().mark_effect_evaluating(effect.id)

  defp ensure_allows(required, decisions) do
    required = MapSet.new(Enum.map(required, &to_string/1))
    denied? = Enum.any?(decisions, &(Map.get(&1, :decision) == "deny"))

    allowed =
      decisions
      |> Enum.filter(&(Map.get(&1, :decision) == "allow"))
      |> MapSet.new(&Map.get(&1, :kind))

    missing = MapSet.difference(required, allowed) |> MapSet.to_list()

    cond do
      denied? -> {:error, :decision_denied}
      missing != [] -> {:error, {:missing_decisions, missing}}
      true -> :ok
    end
  end

  defp record_allow(effect, kind, source_ref, evidence),
    do: record_decision(effect, kind, :allow, source_ref, evidence)

  defp record_decision(effect, kind, decision, source_ref, evidence) do
    digest = Canonical.digest(evidence)

    entry = %{
      kind: kind,
      decision: decision,
      source_ref: source_ref,
      effect_revision: effect.revision,
      epoch: effect.epoch,
      policy_version: effect.version_vector.policy_version,
      trajectory_version: effect.version_vector.trajectory_version,
      payload_digest: effect.payload_digest,
      evidence_ref: "sha256:#{digest}",
      expires_at: Canonical.now() + 300_000,
      metadata: %{evidence_digest: digest}
    }

    case Runtime.store().record_effect_decision(effect.id, entry) do
      {:ok, _} ->
        :ok

      {:error, {:invalid_decision, changeset}} ->
        {:error, {:decision_persistence_failed, changeset}}

      {:error, _} = error ->
        error
    end
  end

  defp build_effect(attrs, episode, lease_id, kind, class, target_id, payload_ref, payload_digest) do
    revision = 1

    vector = %VersionVector{
      episode_id: episode.id,
      epoch: episode.current_epoch,
      policy_version: episode.policy_version,
      snapshot_ancestry: Enum.reject([episode.current_checkpoint_id], &is_nil/1),
      trajectory_version: episode.trajectory_version,
      trajectory_regime: episode.trajectory_regime,
      lease_id: lease_id,
      effect_revision: revision
    }

    %ProposedEffect{
      id: Canonical.id(),
      episode_id: episode.id,
      epoch: episode.current_epoch,
      lease_id: lease_id,
      class: class,
      kind: normalize_kind(kind),
      target: public_target(attrs, target_id),
      payload_ref: payload_ref,
      payload_digest: payload_digest,
      revision: revision,
      reversible?:
        Map.get(attrs, :reversible?, Map.get(attrs, "reversible", EffectState.rank(class) < 4)),
      state: :proposed,
      version_vector: vector,
      expires_at: Map.get(attrs, :expires_at, Canonical.now() + 600_000),
      created_at: Canonical.now(),
      metadata: %{proposal_metadata: Map.get(attrs, :metadata, %{})}
    }
  end

  defp payload(episode_id, attrs, opts) do
    limit = Keyword.get(opts, :payload_limit, 4_194_304)

    cond do
      is_binary(Map.get(attrs, :payload)) ->
        bytes = Map.fetch!(attrs, :payload)
        with {:ok, digest} <- Payloads.put(episode_id, bytes, limit), do: {:ok, digest, digest}

      is_binary(Map.get(attrs, "payload")) ->
        bytes = Map.fetch!(attrs, "payload")
        with {:ok, digest} <- Payloads.put(episode_id, bytes, limit), do: {:ok, digest, digest}

      is_binary(Map.get(attrs, :payload_ref)) ->
        ref = Map.fetch!(attrs, :payload_ref)
        with {:ok, bytes} <- Payloads.get(episode_id, ref), do: {:ok, ref, Canonical.hash(bytes)}

      true ->
        {:error, :payload_required}
    end
  end

  defp public_target(attrs, target_id) do
    supplied = Map.get(attrs, :target, Map.get(attrs, "target", %{}))
    supplied = if is_map(supplied), do: supplied, else: %{}

    supplied
    |> Map.drop([
      "credential",
      "credentials",
      "token",
      "api_key",
      :credential,
      :credentials,
      :token,
      :api_key
    ])
    |> Map.put("id", to_string(target_id))
  end

  defp target_for(effect) do
    id = Map.get(effect.target, "id") || Map.get(effect.target, :id)
    if is_binary(id), do: Runtime.target(id), else: {:error, :target_id_missing}
  end

  defp ensure_admitted(class),
    do: if(SystemRegulator.admit?(class), do: :ok, else: {:error, :system_backpressure})

  defp sensitive_gate(class) do
    if Policy.class_rank(class) >= 3 and not SystemRegulator.sensitive_commit_allowed?(),
      do: {:error, :sensitive_commits_paused},
      else: :ok
  end

  defp required(map, key) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp normalize_kind(value) when is_atom(value), do: value

  defp normalize_kind(value) when is_binary(value) do
    case value do
      "git_commit" -> :git_commit
      "git_remote" -> :git_remote
      "http_read" -> :http_read
      "http_mutation" -> :http_mutation
      "publish" -> :publish
      _ -> :unknown_effect_kind
    end
  end

  defp semantic_positive?(observation, threshold) do
    value = observation.value

    probability =
      cond do
        is_boolean(value) -> if(value, do: observation.confidence || 1.0, else: 0.0)
        is_number(value) -> value * 1.0
        true -> observation.confidence || 0.5
      end

    probability >= threshold
  end

  defp evidence_sufficient?(observation) do
    observation.value in [:sufficient, "Sufficient", "sufficient", 2] or
      (is_number(observation.value) and observation.value >= 0.66)
  end

  defp semantic_ref(observation) do
    %{
      sensor: observation.sensor,
      value: observation.value,
      confidence: observation.confidence,
      request_id: observation.request_id,
      model: observation.model,
      contract: observation.semantic_contract_id
    }
  end
end

defmodule Autonomic.HumanApproval do
  @moduledoc "Verifier for operator approvals bound to exact effect revision/payload/epoch."
  alias Autonomic.{Canonical, Runtime}

  def verify(effect, approval) when is_map(approval) do
    document = Map.get(approval, :document, Map.get(approval, "document", approval))
    signature = Map.get(approval, :signature, Map.get(approval, "signature"))
    key_id = Map.get(approval, :key_id, Map.get(approval, "key_id"))
    keys = Application.get_env(:autonomic, :decision_keys, %{})

    expected = %{
      "effect_id" => effect.id,
      "effect_revision" => effect.revision,
      "episode_id" => effect.episode_id,
      "epoch" => effect.epoch,
      "payload_digest" => effect.payload_digest,
      "decision" => "allow"
    }

    with true <-
           Enum.all?(expected, fn {k, v} ->
             Map.get(document, k) == v or Map.get(document, String.to_existing_atom(k)) == v
           end),
         encoded when is_binary(encoded) <- Map.get(keys, key_id),
         {:ok, public} <- Base.decode64(encoded),
         {:ok, sig} <- Base.decode64(signature || ""),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             "autonomic.human-approval.v1\n" <> Canonical.json(document),
             sig,
             [public, :ed25519]
           ) do
      :ok
    else
      _ -> {:error, :invalid_human_approval}
    end
  rescue
    _ -> {:error, :invalid_human_approval}
  end
end
