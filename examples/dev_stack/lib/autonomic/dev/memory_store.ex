defmodule Autonomic.Dev.MemoryStore do
  @moduledoc """
  In-memory `Autonomic.Store` implementation for examples only.

  All authority-changing operations are serialized through one GenServer. That preserves
  the fencing/concurrency shape needed by the examples, but there is deliberately no
  durability, crash recovery, cross-node ownership, or PostgreSQL transaction boundary.
  """
  @behaviour Autonomic.Store
  use GenServer

  alias Autonomic.{Canonical, CapabilityLease, EffectState, EpisodeCheckpoint, ProposedEffect}

  @uncommitted [:proposed, :prepared, :evaluating, :ready]
  @reconcilable [:commit_intent, :committing, :commit_unknown]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, fresh(), name: __MODULE__)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def events(episode_id), do: GenServer.call(__MODULE__, {:events, episode_id})
  def all_artifacts, do: GenServer.call(__MODULE__, :all_artifacts)

  @impl true
  def current_epoch(episode_id), do: GenServer.call(__MODULE__, {:current_epoch, episode_id})
  def create_episode(attrs), do: GenServer.call(__MODULE__, {:create_episode, attrs})
  def fetch_episode(id), do: GenServer.call(__MODULE__, {:fetch_episode, id})

  def set_episode_state(id, state, metadata \\ %{}),
    do: GenServer.call(__MODULE__, {:set_episode_state, id, state, metadata})

  def set_episode_domain(id, domain),
    do: GenServer.call(__MODULE__, {:set_episode_domain, id, domain})

  @impl true
  def advance_epoch(episode_id, metadata),
    do: GenServer.call(__MODULE__, {:advance_epoch, episode_id, metadata})

  @impl true
  def put_lease(%CapabilityLease{} = lease), do: GenServer.call(__MODULE__, {:put_lease, lease})

  @impl true
  def fetch_lease(id), do: GenServer.call(__MODULE__, {:fetch_lease, id})
  def revoke_lease(id, reason), do: GenServer.call(__MODULE__, {:revoke_lease, id, reason})

  @impl true
  def put_effect(%ProposedEffect{} = effect),
    do: GenServer.call(__MODULE__, {:put_effect, effect})

  def prepare_effect(%ProposedEffect{} = effect) do
    with :ok <- put_effect(%{effect | state: :proposed}) do
      prepare_existing_effect(effect.id)
    end
  end

  def prepare_existing_effect(id), do: GenServer.call(__MODULE__, {:prepare_existing_effect, id})

  def list_effects(episode_id, states \\ nil),
    do: GenServer.call(__MODULE__, {:list_effects, episode_id, states})

  def abort_effect(id, reason), do: GenServer.call(__MODULE__, {:abort_effect, id, reason})

  @impl true
  def fetch_effect(id), do: GenServer.call(__MODULE__, {:fetch_effect, id})

  def update_effect_revision(id, attrs),
    do: GenServer.call(__MODULE__, {:update_effect_revision, id, attrs})

  def mark_effect_evaluating(id), do: transition(id, :evaluating, :effect_evaluating)
  def mark_effect_ready(id), do: transition(id, :ready, :effect_ready)

  def record_effect_decision(id, decision),
    do: GenServer.call(__MODULE__, {:record_effect_decision, id, decision})

  def effect_decisions(id, revision \\ nil),
    do: GenServer.call(__MODULE__, {:effect_decisions, id, revision})

  def begin_effect_commit(id, required),
    do: GenServer.call(__MODULE__, {:begin_effect_commit, id, required})

  def mark_committing(id), do: transition(id, :committing, :effect_committing)

  def complete_effect(id, outcome, details \\ %{}),
    do: GenServer.call(__MODULE__, {:complete_effect, id, outcome, details})

  def reconcile_effect(id, outcome, details \\ %{}),
    do: GenServer.call(__MODULE__, {:reconcile_effect, id, outcome, details})

  def pending_reconciliation, do: GenServer.call(__MODULE__, :pending_reconciliation)

  def put_checkpoint(%EpisodeCheckpoint{} = checkpoint),
    do: GenServer.call(__MODULE__, {:put_checkpoint, checkpoint})

  def latest_stable_checkpoint(episode_id),
    do: GenServer.call(__MODULE__, {:latest_stable_checkpoint, episode_id})

  def checkpoint(id), do: GenServer.call(__MODULE__, {:checkpoint, id})

  def update_trajectory(episode_id, state),
    do: GenServer.call(__MODULE__, {:update_trajectory, episode_id, state})

  def record_observation(frame), do: GenServer.call(__MODULE__, {:record_observation, frame})
  def record_recovery(attrs), do: GenServer.call(__MODULE__, {:record_recovery, attrs})

  def claim_episode(id, node, ttl_ms),
    do: GenServer.call(__MODULE__, {:claim_episode, id, node, ttl_ms})

  def renew_episode_owner(id, token, ttl_ms),
    do: GenServer.call(__MODULE__, {:renew_episode_owner, id, token, ttl_ms})

  @impl true
  def append_event(episode_id, kind, payload),
    do: GenServer.call(__MODULE__, {:append_event, episode_id, kind, payload})

  defp transition(id, to, kind), do: GenServer.call(__MODULE__, {:transition, id, to, kind})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, fresh()}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  def handle_call(:all_artifacts, _from, state), do: {:reply, state, state}
  def handle_call({:events, id}, _from, state), do: {:reply, Map.get(state.events, id, []), state}

  def handle_call({:current_epoch, id}, _from, state) do
    reply =
      case state.episodes[id] do
        nil -> {:error, :episode_not_found}
        episode -> {:ok, episode.current_epoch}
      end

    {:reply, reply, state}
  end

  def handle_call({:create_episode, attrs}, _from, state) do
    id = Map.fetch!(attrs, :id)

    if Map.has_key?(state.episodes, id) do
      {:reply, {:error, :episode_exists}, state}
    else
      policy = Map.fetch!(attrs, :policy)
      hard = Map.fetch!(attrs, :hard_envelope)

      episode = %{
        id: id,
        state: normalize_atom(Map.get(attrs, :state, :bootstrapping)),
        current_epoch: Map.get(attrs, :current_epoch, 1),
        policy_id: Map.get(attrs, :policy_id),
        policy_version: Map.get(attrs, :policy_version, Map.get(policy, "version", 1)),
        policy_digest: Map.get(attrs, :policy_digest, Canonical.digest(policy)),
        policy: plain(policy),
        hard_envelope: plain(hard),
        origin_intent_digest: Map.get(attrs, :origin_intent_digest),
        current_checkpoint_id: Map.get(attrs, :current_checkpoint_id),
        domain_ref: nil,
        domain_generation: nil,
        domain_os_ref: nil,
        domain_metadata: %{},
        trajectory_version: Map.get(attrs, :trajectory_version, 0),
        trajectory_regime: normalize_atom(Map.get(attrs, :trajectory_regime, :stable)),
        trajectory_state: Map.get(attrs, :trajectory_state, %{}),
        owner_node: nil,
        owner_lease_token: nil,
        owner_lease_expires_at: nil,
        metadata: Map.get(attrs, :metadata, %{})
      }

      state = put_in(state, [:episodes, id], episode)

      {seq, state} =
        add_event(state, id, :episode_created, %{
          epoch: episode.current_epoch,
          policy_version: episode.policy_version
        })

      _ = seq
      {:reply, {:ok, episode}, state}
    end
  end

  def handle_call({:fetch_episode, id}, _from, state) do
    reply =
      case state.episodes[id] do
        nil -> :not_found
        episode -> {:ok, episode}
      end

    {:reply, reply, state}
  end

  def handle_call({:set_episode_state, id, new_state, metadata}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found) do
      episode = %{episode | state: normalize_atom(new_state)}
      state = put_in(state, [:episodes, id], episode)

      {_seq, state} =
        add_event(state, id, :episode_state, %{state: new_state, metadata: plain(metadata)})

      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:set_episode_domain, id, nil}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found) do
      episode = %{
        episode
        | domain_ref: nil,
          domain_generation: nil,
          domain_os_ref: nil,
          domain_metadata: %{}
      }

      state = put_in(state, [:episodes, id], episode)
      {_seq, state} = add_event(state, id, :domain_cleared, %{})
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:set_episode_domain, id, domain}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found),
         true <- domain.epoch == episode.current_epoch do
      episode = %{
        episode
        | domain_ref: domain.id,
          domain_generation: domain.generation,
          domain_os_ref: domain.os_ref,
          domain_metadata: domain.metadata || %{}
      }

      state = put_in(state, [:episodes, id], episode)

      {_seq, state} =
        add_event(state, id, :domain_bound, %{
          domain_ref: domain.id,
          epoch: domain.epoch,
          generation: domain.generation
        })

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :stale_domain_epoch}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:advance_epoch, id, metadata}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found) do
      new_epoch = episode.current_epoch + 1
      now = Canonical.now()
      episode = %{episode | current_epoch: new_epoch}

      leases =
        Map.new(state.leases, fn {key, lease} ->
          if lease.episode_id == id and lease.epoch < new_epoch and is_nil(lease.revoked_at),
            do: {key, %{lease | revoked_at: now}},
            else: {key, lease}
        end)

      effects =
        Map.new(state.effects, fn {key, effect} ->
          if effect.episode_id == id and effect.epoch < new_epoch and effect.state in @uncommitted,
            do: {key, %{effect | state: :stale}},
            else: {key, effect}
        end)

      state = %{state | leases: leases, effects: effects} |> put_in([:episodes, id], episode)

      in_flight =
        effects
        |> Map.values()
        |> Enum.filter(
          &(&1.episode_id == id and &1.epoch < new_epoch and &1.state in @reconcilable)
        )
        |> Enum.map(& &1.id)

      {_seq, state} =
        add_event(state, id, :epoch_advanced, %{
          old_epoch: new_epoch - 1,
          new_epoch: new_epoch,
          in_flight_commits: in_flight,
          metadata: plain(metadata)
        })

      {:reply, {:ok, new_epoch}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:put_lease, lease}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, lease.episode_id, :episode_not_found),
         true <- episode.current_epoch == lease.epoch,
         true <- episode.policy_version == lease.policy_version,
         true <- lease.expires_at > lease.issued_at do
      state = put_in(state, [:leases, lease.id], lease)

      {_seq, state} =
        add_event(state, lease.episode_id, :lease_issued, %{
          lease_id: lease.id,
          epoch: lease.epoch,
          max_effect_class: lease.max_effect_class
        })

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :invalid_or_stale_lease}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:fetch_lease, id}, _from, state) do
    reply =
      case state.leases[id] do
        nil -> :not_found
        lease -> {:ok, lease}
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke_lease, id, reason}, _from, state) do
    case state.leases[id] do
      nil ->
        {:reply, :not_found, state}

      lease ->
        lease = %{lease | revoked_at: Canonical.now(), reason: to_string(reason)}
        state = put_in(state, [:leases, id], lease)

        {_seq, state} =
          add_event(state, lease.episode_id, :lease_revoked, %{
            lease_id: id,
            reason: to_string(reason)
          })

        {:reply, :ok, state}
    end
  end

  def handle_call({:put_effect, effect}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, effect.episode_id, :episode_not_found),
         true <- episode.current_epoch == effect.epoch,
         false <- Map.has_key?(state.effects, effect.id) do
      state = put_in(state, [:effects, effect.id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, :effect_proposed, %{
          effect_id: effect.id,
          revision: effect.revision,
          class: effect.class,
          kind: effect.kind,
          payload_digest: effect.payload_digest
        })

      {:reply, :ok, state}
    else
      true -> {:reply, {:error, :effect_exists}, state}
      false -> {:reply, {:error, :stale_authority}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:prepare_existing_effect, id}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         {:ok, episode} <- fetch_map(state.episodes, effect.episode_id, :episode_not_found),
         {:ok, lease} <- fetch_map(state.leases, effect.lease_id, :lease_not_found),
         :ok <- check(effect.state == :proposed, :effect_not_proposed),
         :ok <- check(episode.current_epoch == effect.epoch, :stale_authority),
         :ok <-
           check(
             lease.episode_id == effect.episode_id and lease.epoch == effect.epoch,
             :stale_lease
           ),
         :ok <-
           check(
             is_nil(lease.revoked_at) and lease.expires_at > Canonical.now(),
             :expired_or_revoked_lease
           ),
         :ok <- check(effect.version_vector.epoch == episode.current_epoch, :stale_version_epoch),
         :ok <-
           check(effect.version_vector.policy_version == episode.policy_version, :stale_policy),
         :ok <-
           check(
             effect.version_vector.trajectory_version == episode.trajectory_version,
             :stale_trajectory
           ),
         :ok <-
           check(effect.version_vector.effect_revision == effect.revision, :stale_effect_revision) do
      effect = %{effect | state: :prepared}
      state = put_in(state, [:effects, id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, :effect_prepared, %{
          effect_id: id,
          revision: effect.revision
        })

      {:reply, {:ok, effect}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_effects, episode_id, states}, _from, state) do
    values =
      state.effects
      |> Map.values()
      |> Enum.filter(&(&1.episode_id == episode_id))
      |> Enum.sort_by(& &1.created_at)

    values = if is_list(states), do: Enum.filter(values, &(&1.state in states)), else: values
    {:reply, {:ok, values}, state}
  end

  def handle_call({:abort_effect, id, reason}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found) do
      cond do
        effect.state in [:aborted, :expired, :stale, :failed] ->
          {:reply, {:ok, effect}, state}

        effect.state in @reconcilable ->
          {:reply, {:error, :commit_horizon_crossed}, state}

        EffectState.allowed?(effect.state, :aborted) ->
          effect = %{effect | state: :aborted, failure: %{reason: to_string(reason)}}
          state = put_in(state, [:effects, id], effect)

          {_seq, state} =
            add_event(state, effect.episode_id, :effect_aborted, %{
              effect_id: id,
              reason: to_string(reason)
            })

          {:reply, {:ok, effect}, state}

        true ->
          {:reply, {:error, {:invalid_effect_transition, effect.state, :aborted}}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:fetch_effect, id}, _from, state) do
    reply =
      case state.effects[id] do
        nil -> :not_found
        effect -> {:ok, effect}
      end

    {:reply, reply, state}
  end

  def handle_call({:update_effect_revision, id, attrs}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         :ok <- check(effect.state in [:prepared, :evaluating, :ready], :effect_not_revisable) do
      revision = (effect.revision || 1) + 1
      vector = %{effect.version_vector | effect_revision: revision}

      effect = %{
        effect
        | revision: revision,
          target: Map.get(attrs, :target, effect.target),
          payload_ref: Map.get(attrs, :payload_ref, effect.payload_ref),
          payload_digest: Map.get(attrs, :payload_digest, effect.payload_digest),
          version_vector: vector,
          state: :prepared
      }

      state = put_in(state, [:effects, id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, :effect_revised, %{
          effect_id: id,
          revision: revision,
          payload_digest: effect.payload_digest
        })

      {:reply, {:ok, effect}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:transition, id, to, kind}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         true <- EffectState.allowed?(effect.state, to) do
      from = effect.state
      effect = %{effect | state: to}
      state = put_in(state, [:effects, id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, kind, %{effect_id: id, from: from, to: to})

      {:reply, {:ok, effect}, state}
    else
      false -> {:reply, {:error, :invalid_effect_transition}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:record_effect_decision, id, decision}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         {:ok, episode} <- fetch_map(state.episodes, effect.episode_id, :episode_not_found),
         :ok <- validate_decision(episode, effect, decision) do
      entry = %{
        id: Map.get(decision, :id, Canonical.id()),
        effect_id: id,
        effect_revision: effect.revision,
        kind: decision |> Map.fetch!(:kind) |> to_string(),
        decision: decision |> Map.fetch!(:decision) |> to_string(),
        source_ref: Map.get(decision, :source_ref),
        episode_id: effect.episode_id,
        epoch: effect.epoch,
        policy_version: effect.version_vector.policy_version,
        trajectory_version: effect.version_vector.trajectory_version,
        snapshot_ref: Map.get(decision, :snapshot_ref),
        expires_at: Map.get(decision, :expires_at),
        payload_digest: effect.payload_digest,
        evidence_ref: Map.get(decision, :evidence_ref),
        signature: Map.get(decision, :signature),
        created_at: Map.get(decision, :created_at, Canonical.now()),
        metadata: Map.get(decision, :metadata, %{})
      }

      existing =
        Map.get(state.decisions, id, [])
        |> Enum.find(
          &(&1.effect_revision == effect.revision and &1.kind == entry.kind and
              &1.source_ref == entry.source_ref)
        )

      cond do
        is_nil(existing) ->
          decisions = Map.update(state.decisions, id, [entry], &(&1 ++ [entry]))
          state = %{state | decisions: decisions}

          {_seq, state} =
            add_event(state, effect.episode_id, :effect_decision, %{
              effect_id: id,
              revision: effect.revision,
              kind: entry.kind,
              decision: entry.decision,
              evidence_ref: entry.evidence_ref
            })

          {:reply, {:ok, entry}, state}

        same_decision?(existing, entry) ->
          {:reply, {:ok, existing}, state}

        true ->
          {:reply, {:error, :conflicting_effect_decision}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:effect_decisions, id, revision}, _from, state) do
    values = Map.get(state.decisions, id, [])

    values =
      if is_nil(revision),
        do: values,
        else: Enum.filter(values, &(&1.effect_revision == revision))

    {:reply, {:ok, values}, state}
  end

  def handle_call({:begin_effect_commit, id, required}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         {:ok, episode} <- fetch_map(state.episodes, effect.episode_id, :episode_not_found),
         {:ok, lease} <- fetch_map(state.leases, effect.lease_id, :lease_not_found),
         :ok <- validate_commit_horizon(episode, effect, lease),
         :ok <- validate_required_decisions(Map.get(state.decisions, id, []), effect, required) do
      attempt = Canonical.id()

      effect = %{
        effect
        | state: :commit_intent,
          commit_attempt_id: attempt,
          idempotency_key: effect.idempotency_key || "autonomic-#{effect.id}"
      }

      state = put_in(state, [:effects, id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, :effect_commit_intent, %{
          effect_id: id,
          revision: effect.revision,
          commit_attempt_id: attempt,
          idempotency_key: effect.idempotency_key,
          version_vector: Map.from_struct(effect.version_vector)
        })

      {:reply, {:ok, effect}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:complete_effect, id, outcome, details}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found) do
      {to, attrs, event} =
        case outcome do
          :committed ->
            {:committed,
             %{
               committed_at: Canonical.now(),
               external_receipt_ref: Map.get(details, :receipt_ref),
               failure: nil,
               metadata: put_receipt(effect.metadata, Map.get(details, :receipt, %{}))
             }, :effect_committed}

          :failed ->
            {:failed, %{failure: Map.get(details, :failure, details)}, :effect_failed}

          :commit_unknown ->
            {:commit_unknown, %{failure: Map.get(details, :failure, details)},
             :effect_commit_unknown}
        end

      if EffectState.allowed?(effect.state, to) do
        from = effect.state
        effect = struct(effect, attrs) |> Map.put(:state, to)
        state = put_in(state, [:effects, id], effect)

        {_seq, state} =
          add_event(state, effect.episode_id, event, %{
            effect_id: id,
            from: from,
            to: to,
            details: plain(details)
          })

        {:reply, {:ok, effect}, state}
      else
        {:reply, {:error, {:invalid_effect_transition, effect.state, to}}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:reconcile_effect, id, outcome, details}, _from, state) do
    with {:ok, effect} <- fetch_map(state.effects, id, :effect_not_found),
         true <- effect.state in @reconcilable do
      effect =
        case outcome do
          :committed ->
            %{
              effect
              | state: :committed,
                committed_at: Canonical.now(),
                failure: nil,
                metadata: put_receipt(effect.metadata, Map.get(details, :receipt, %{}))
            }

          :not_committed ->
            %{effect | state: :ready, commit_attempt_id: nil, failure: nil}

          :unknown ->
            %{
              effect
              | state: :commit_unknown,
                failure: Map.get(details, :failure, %{reason: :reconciliation_unknown})
            }

          :failed ->
            %{effect | state: :failed, failure: Map.get(details, :failure, details)}
        end

      state = put_in(state, [:effects, id], effect)

      {_seq, state} =
        add_event(state, effect.episode_id, :effect_reconciled, %{
          effect_id: id,
          outcome: outcome,
          details: plain(details)
        })

      {:reply, {:ok, effect}, state}
    else
      false -> {:reply, {:error, :not_reconcilable}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:pending_reconciliation, _from, state) do
    effects =
      state.effects
      |> Map.values()
      |> Enum.filter(&(&1.state in @reconcilable))
      |> Enum.sort_by(& &1.created_at)

    {:reply, {:ok, effects}, state}
  end

  def handle_call({:put_checkpoint, checkpoint}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, checkpoint.episode_id, :episode_not_found),
         true <- episode.current_epoch == checkpoint.epoch do
      checkpoint = if checkpoint.id, do: checkpoint, else: %{checkpoint | id: Canonical.id()}
      checkpoints = Map.put(state.checkpoints, checkpoint.id, checkpoint)

      episode =
        if checkpoint.trust_level == :stable,
          do: %{episode | current_checkpoint_id: checkpoint.id},
          else: episode

      state = %{state | checkpoints: checkpoints} |> put_in([:episodes, episode.id], episode)

      {_seq, state} =
        add_event(state, episode.id, :checkpoint_recorded, %{
          checkpoint_id: checkpoint.id,
          epoch: checkpoint.epoch,
          filesystem_digest: checkpoint.filesystem_digest,
          trust_level: checkpoint.trust_level
        })

      {:reply, {:ok, checkpoint}, state}
    else
      false -> {:reply, {:error, :stale_checkpoint_epoch}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:latest_stable_checkpoint, episode_id}, _from, state) do
    checkpoint =
      state.checkpoints
      |> Map.values()
      |> Enum.filter(&(&1.episode_id == episode_id and &1.trust_level == :stable))
      |> Enum.max_by(& &1.created_at, fn -> nil end)

    {:reply, if(checkpoint, do: {:ok, checkpoint}, else: :not_found), state}
  end

  def handle_call({:checkpoint, id}, _from, state) do
    {:reply, if(state.checkpoints[id], do: {:ok, state.checkpoints[id]}, else: :not_found), state}
  end

  def handle_call({:update_trajectory, episode_id, homeostat}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, episode_id, :episode_not_found),
         true <- homeostat.epoch == episode.current_epoch,
         true <- homeostat.trajectory_version >= episode.trajectory_version do
      episode = %{
        episode
        | trajectory_version: homeostat.trajectory_version,
          trajectory_regime: homeostat.regime,
          trajectory_state: Map.from_struct(homeostat)
      }

      state = put_in(state, [:episodes, episode_id], episode)

      {_seq, state} =
        add_event(state, episode_id, :trajectory_updated, %{
          version: homeostat.trajectory_version,
          regime: homeostat.regime
        })

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :stale_trajectory}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:record_observation, frame}, _from, state) do
    ref = "observation:#{Canonical.id()}:#{Canonical.digest(frame)}"
    {:reply, {:ok, ref}, %{state | observations: state.observations ++ [{ref, frame}]}}
  end

  def handle_call({:record_recovery, attrs}, _from, state) do
    id = Map.get(attrs, :id, Canonical.id())
    {:reply, {:ok, id}, put_in(state, [:recoveries, id], Map.put(attrs, :id, id))}
  end

  def handle_call({:claim_episode, id, owner, ttl}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found) do
      now = Canonical.now()

      if is_nil(episode.owner_lease_expires_at) or episode.owner_lease_expires_at < now or
           episode.owner_node == owner do
        token = Canonical.id()

        episode = %{
          episode
          | owner_node: owner,
            owner_lease_token: token,
            owner_lease_expires_at: now + ttl
        }

        {:reply, {:ok, token}, put_in(state, [:episodes, id], episode)}
      else
        {:reply, {:error, :owned_elsewhere}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:renew_episode_owner, id, token, ttl}, _from, state) do
    with {:ok, episode} <- fetch_map(state.episodes, id, :episode_not_found),
         true <- episode.owner_lease_token == token do
      episode = %{episode | owner_lease_expires_at: Canonical.now() + ttl}
      {:reply, :ok, put_in(state, [:episodes, id], episode)}
    else
      false -> {:reply, {:error, :owner_token_mismatch}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:append_event, id, kind, payload}, _from, state) do
    case state.episodes[id] do
      nil ->
        {:reply, {:error, :episode_not_found}, state}

      _ ->
        {seq, state} = add_event(state, id, kind, payload)
        {:reply, {:ok, seq}, state}
    end
  end

  defp fresh do
    %{
      episodes: %{},
      leases: %{},
      effects: %{},
      decisions: %{},
      checkpoints: %{},
      events: %{},
      observations: [],
      recoveries: %{}
    }
  end

  defp fetch_map(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp validate_decision(episode, effect, decision) do
    now = Canonical.now()

    checks = [
      {episode.current_epoch == effect.epoch, :stale_authority},
      {Map.get(decision, :effect_revision, effect.revision) == effect.revision,
       :stale_effect_revision},
      {Map.get(decision, :epoch, effect.epoch) == effect.epoch, :stale_decision_epoch},
      {Map.get(decision, :policy_version, effect.version_vector.policy_version) ==
         effect.version_vector.policy_version, :stale_decision_policy},
      {Map.get(decision, :trajectory_version, effect.version_vector.trajectory_version) ==
         effect.version_vector.trajectory_version, :stale_decision_trajectory},
      {Map.get(decision, :payload_digest, effect.payload_digest) == effect.payload_digest,
       :stale_decision_payload},
      {is_nil(Map.get(decision, :expires_at)) or Map.get(decision, :expires_at) > now,
       :expired_decision}
    ]

    case Enum.find(checks, fn {ok, _} -> not ok end) do
      nil -> :ok
      {_, reason} -> {:error, reason}
    end
  end

  defp same_decision?(a, b) do
    a.decision == b.decision and a.epoch == b.epoch and a.policy_version == b.policy_version and
      a.trajectory_version == b.trajectory_version and a.payload_digest == b.payload_digest and
      a.evidence_ref == b.evidence_ref
  end

  defp validate_commit_horizon(episode, effect, lease) do
    now = Canonical.now()

    checks = [
      {episode.current_epoch == effect.epoch, :stale_authority},
      {effect.state == :ready, :effect_not_ready},
      {lease.episode_id == effect.episode_id and lease.epoch == effect.epoch, :stale_lease},
      {is_nil(lease.revoked_at) and lease.expires_at > now, :expired_or_revoked_lease},
      {effect.version_vector.epoch == episode.current_epoch, :stale_version_epoch},
      {effect.version_vector.policy_version == episode.policy_version, :stale_policy},
      {effect.version_vector.trajectory_version == episode.trajectory_version, :stale_trajectory},
      {effect.version_vector.effect_revision == effect.revision, :stale_effect_revision},
      {is_nil(effect.expires_at) or effect.expires_at > now, :effect_expired}
    ]

    case Enum.find(checks, fn {ok, _} -> not ok end) do
      nil -> :ok
      {_, reason} -> {:error, reason}
    end
  end

  defp validate_required_decisions(decisions, effect, required) do
    now = Canonical.now()
    current = Enum.filter(decisions, &(&1.effect_revision == effect.revision))

    if Enum.any?(current, &(&1.decision == "deny")) do
      {:error, :decision_denied}
    else
      valid =
        current
        |> Enum.filter(fn d ->
          d.decision == "allow" and d.epoch == effect.epoch and
            d.policy_version == effect.version_vector.policy_version and
            d.trajectory_version == effect.version_vector.trajectory_version and
            d.payload_digest == effect.payload_digest and
            (is_nil(d.expires_at) or d.expires_at > now)
        end)
        |> MapSet.new(& &1.kind)

      missing = required |> Enum.map(&to_string/1) |> Enum.reject(&MapSet.member?(valid, &1))
      if missing == [], do: :ok, else: {:error, {:missing_decisions, missing}}
    end
  end

  defp put_receipt(metadata, receipt),
    do: Map.put(metadata || %{}, "external_receipt", plain(receipt))

  defp add_event(state, episode_id, kind, payload) do
    prior = Map.get(state.events, episode_id, [])
    seq = length(prior) + 1

    previous_hash =
      case List.last(prior) do
        nil -> nil
        event -> event.entry_hash
      end

    body = %{
      episode_id: episode_id,
      sequence: seq,
      kind: to_string(kind),
      payload: plain(payload),
      previous_hash: previous_hash,
      created_at_ms: Canonical.now()
    }

    event = Map.put(body, :entry_hash, Canonical.digest(body))
    {seq, put_in(state, [:events, episode_id], prior ++ [event])}
  end

  defp plain(nil), do: nil
  defp plain(value), do: Canonical.plain(value)
  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
