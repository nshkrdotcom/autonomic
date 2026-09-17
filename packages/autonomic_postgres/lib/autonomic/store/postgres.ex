defmodule Autonomic.Store.Postgres do
  @moduledoc "PostgreSQL-backed durable authority store with one lock order: episode -> effect -> lease."
  @behaviour Autonomic.Store

  import Ecto.Query

  alias Autonomic.{
    Canonical,
    Capability,
    CapabilityLease,
    EffectState,
    EpisodeCheckpoint,
    ProposedEffect,
    SemanticObservation,
    VersionVector
  }

  alias Autonomic.Store.Repo
  alias Autonomic.Store.Schema.CapabilityLease, as: LeaseRow

  alias Autonomic.Store.Schema.{
    Checkpoint,
    Effect,
    EffectDecision,
    Episode,
    EpisodeEvent,
    ObservationFrame,
    RecoveryRecord
  }

  @uncommitted ~w(proposed prepared evaluating ready)
  @commit_states ~w(commit_intent committing commit_unknown)

  @impl true
  def current_epoch(episode_id) do
    case Repo.get(Episode, episode_id) do
      nil -> {:error, :episode_not_found}
      episode -> {:ok, episode.current_epoch}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def create_episode(attrs) when is_map(attrs) do
    id = fetch(attrs, :id)
    policy = fetch(attrs, :policy)
    hard_envelope = fetch(attrs, :hard_envelope)

    row_attrs = %{
      id: id,
      state: Map.get(attrs, :state, "bootstrapping"),
      current_epoch: Map.get(attrs, :current_epoch, 1),
      policy_id: Map.get(attrs, :policy_id),
      policy_version: Map.get(attrs, :policy_version, Map.get(policy, "version", 1)),
      policy_digest: Map.get(attrs, :policy_digest, Canonical.digest(policy)),
      policy: plain(policy),
      hard_envelope: plain(hard_envelope),
      origin_intent_digest: Map.get(attrs, :origin_intent_digest),
      current_checkpoint_id: Map.get(attrs, :current_checkpoint_id),
      trajectory_version: Map.get(attrs, :trajectory_version, 0),
      trajectory_regime: to_string(Map.get(attrs, :trajectory_regime, :stable)),
      trajectory_state: plain(Map.get(attrs, :trajectory_state, %{})),
      metadata: plain(Map.get(attrs, :metadata, %{}))
    }

    Repo.transaction(fn ->
      case %Episode{} |> Episode.changeset(row_attrs) |> Repo.insert() do
        {:ok, episode} ->
          append_event_locked!(episode, :episode_created, %{
            epoch: episode.current_epoch,
            policy_version: episode.policy_version,
            policy_digest: episode.policy_digest
          })

          episode

        {:error, changeset} ->
          Repo.rollback({:invalid_episode, changeset})
      end
    end)
    |> tx_result()
  end

  def fetch_episode(id) do
    case Repo.get(Episode, id) do
      nil -> :not_found
      episode -> {:ok, episode_to_map(episode)}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def set_episode_state(episode_id, state, metadata \\ %{}) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      {:ok, episode} = episode |> Episode.changeset(%{state: to_string(state)}) |> Repo.update()

      append_event_locked!(episode, :episode_state, %{
        state: to_string(state),
        metadata: plain(metadata)
      })

      :ok
    end)
    |> tx_result()
  end

  def set_episode_domain(episode_id, nil) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)

      {:ok, episode} =
        episode
        |> Episode.changeset(%{
          domain_ref: nil,
          domain_generation: nil,
          domain_os_ref: nil,
          domain_metadata: %{}
        })
        |> Repo.update()

      append_event_locked!(episode, :domain_cleared, %{})
      :ok
    end)
    |> tx_result()
  end

  def set_episode_domain(episode_id, %Autonomic.ExecutionDomain.Domain{} = domain) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      if episode.current_epoch != domain.epoch, do: Repo.rollback(:stale_domain_epoch)

      attrs = %{
        domain_ref: domain.id,
        domain_generation: domain.generation,
        domain_os_ref: if(is_nil(domain.os_ref), do: nil, else: to_string(domain.os_ref)),
        domain_metadata: plain(domain.metadata || %{})
      }

      {:ok, episode} = episode |> Episode.changeset(attrs) |> Repo.update()

      append_event_locked!(episode, :domain_bound, %{
        domain_ref: domain.id,
        generation: domain.generation,
        epoch: domain.epoch
      })

      :ok
    end)
    |> tx_result()
  end

  @impl true
  def advance_epoch(episode_id, metadata) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      new_epoch = episode.current_epoch + 1
      now = Canonical.now()

      {:ok, updated} = episode |> Episode.changeset(%{current_epoch: new_epoch}) |> Repo.update()

      from(l in LeaseRow,
        where: l.episode_id == ^episode_id and l.epoch < ^new_epoch and is_nil(l.revoked_at_ms)
      )
      |> Repo.update_all(set: [revoked_at_ms: now])

      from(e in Effect,
        where: e.episode_id == ^episode_id and e.epoch < ^new_epoch and e.state in ^@uncommitted
      )
      |> Repo.update_all(set: [state: "stale", updated_at: DateTime.utc_now()])

      in_flight =
        from(e in Effect,
          where:
            e.episode_id == ^episode_id and e.epoch < ^new_epoch and e.state in ^@commit_states,
          select: e.id
        )
        |> Repo.all()

      append_event_locked!(updated, :epoch_advanced, %{
        old_epoch: episode.current_epoch,
        new_epoch: new_epoch,
        in_flight_commits: in_flight,
        metadata: plain(metadata)
      })

      new_epoch
    end)
    |> tx_result()
  end

  @impl true
  def put_lease(%CapabilityLease{} = lease) do
    attrs = lease_to_attrs(lease)

    Repo.transaction(fn ->
      episode = lock_episode!(lease.episode_id)

      cond do
        episode.current_epoch != lease.epoch -> Repo.rollback(:stale_lease_epoch)
        episode.policy_version != lease.policy_version -> Repo.rollback(:stale_lease_policy)
        lease.expires_at <= lease.issued_at -> Repo.rollback(:invalid_lease_expiry)
        true -> :ok
      end

      case %LeaseRow{} |> LeaseRow.changeset(attrs) |> Repo.insert() do
        {:ok, _} ->
          append_event_locked!(episode, :lease_issued, %{
            lease_id: lease.id,
            epoch: lease.epoch,
            max_effect_class: lease.max_effect_class
          })

          :ok

        {:error, changeset} ->
          Repo.rollback({:invalid_lease, changeset})
      end
    end)
    |> tx_result()
  rescue
    error -> {:error, {:store_error, error}}
  end

  @impl true
  def fetch_lease(id) do
    case Repo.get(LeaseRow, id) do
      nil -> :not_found
      row -> {:ok, lease_from_row(row)}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def revoke_lease(id, reason) do
    case Repo.get(LeaseRow, id) do
      %LeaseRow{} = preliminary ->
        Repo.transaction(fn ->
          episode = lock_episode!(preliminary.episode_id)
          lease = lock_lease!(id)
          now = Canonical.now()

          {:ok, _} =
            lease
            |> LeaseRow.changeset(%{revoked_at_ms: now, reason: to_string(reason)})
            |> Repo.update()

          append_event_locked!(episode, :lease_revoked, %{
            lease_id: id,
            reason: to_string(reason),
            at: now
          })

          :ok
        end)
        |> tx_result()

      nil ->
        :not_found
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  @impl true
  def put_effect(%ProposedEffect{} = effect) do
    Repo.transaction(fn ->
      episode = lock_episode!(effect.episode_id)
      if episode.current_epoch != effect.epoch, do: Repo.rollback(:stale_authority)

      case %Effect{} |> Effect.changeset(effect_to_attrs(effect)) |> Repo.insert() do
        {:ok, row} ->
          append_event_locked!(episode, :effect_proposed, %{
            effect_id: row.id,
            revision: row.revision,
            class: row.class,
            kind: row.kind,
            payload_digest: row.payload_digest
          })

          :ok

        {:error, changeset} ->
          Repo.rollback({:invalid_effect, changeset})
      end
    end)
    |> tx_result()
  rescue
    error -> {:error, {:store_error, error}}
  end

  # Compatibility entrypoint. The durable lifecycle always writes :proposed first.
  def prepare_effect(%ProposedEffect{} = effect) do
    proposed = %{effect | state: :proposed}

    with :ok <- put_effect(proposed), do: prepare_existing_effect(proposed.id)
  end

  def prepare_existing_effect(effect_id) do
    with_locked_effect(effect_id, fn episode, effect ->
      lease = lock_lease!(effect.lease_id)
      now = Canonical.now()
      vector = effect.version_vector

      checks = [
        {effect.state == "proposed", :effect_not_proposed},
        {episode.current_epoch == effect.epoch, :stale_authority},
        {lease.episode_id == effect.episode_id and lease.epoch == effect.epoch, :stale_lease},
        {is_nil(lease.revoked_at_ms) and lease.expires_at_ms > now, :expired_or_revoked_lease},
        {vector["epoch"] == episode.current_epoch, :stale_version_epoch},
        {vector["policy_version"] == episode.policy_version, :stale_policy},
        {vector["trajectory_version"] == episode.trajectory_version, :stale_trajectory},
        {vector["effect_revision"] == effect.revision, :stale_effect_revision}
      ]

      require_checks!(checks)

      {:ok, updated} = effect |> Effect.changeset(%{state: "prepared"}) |> Repo.update()

      append_event_locked!(episode, :effect_prepared, %{
        effect_id: effect.id,
        revision: effect.revision,
        class: effect.class,
        kind: effect.kind,
        payload_digest: effect.payload_digest
      })

      effect_from_row(updated)
    end)
  end

  def list_effects(episode_id, states \\ nil) do
    query =
      from(e in Effect, where: e.episode_id == ^episode_id, order_by: [asc: e.created_at_ms])

    query =
      if is_list(states) do
        state_names = Enum.map(states, &to_string/1)
        from(e in query, where: e.state in ^state_names)
      else
        query
      end

    {:ok, Enum.map(Repo.all(query), &effect_from_row/1)}
  rescue
    error -> {:error, {:store_error, error}}
  end

  def abort_effect(effect_id, reason) do
    with_locked_effect(effect_id, fn episode, effect ->
      state = EffectState.parse_state(effect.state)

      cond do
        state in [:aborted, :expired, :stale, :failed] ->
          effect_from_row(effect)

        EffectState.in_flight?(state) ->
          Repo.rollback(:commit_horizon_crossed)

        EffectState.allowed?(state, :aborted) ->
          {:ok, updated} =
            effect
            |> Effect.changeset(%{state: "aborted", failure: %{"reason" => to_string(reason)}})
            |> Repo.update()

          append_event_locked!(episode, :effect_aborted, %{
            effect_id: effect.id,
            reason: to_string(reason)
          })

          effect_from_row(updated)

        true ->
          Repo.rollback({:invalid_effect_transition, state, :aborted})
      end
    end)
  end

  @impl true
  def fetch_effect(id) do
    case Repo.get(Effect, id) do
      nil -> :not_found
      row -> {:ok, effect_from_row(row)}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def update_effect_revision(effect_id, attrs) when is_map(attrs) do
    with_locked_effect(effect_id, fn episode, effect ->
      if effect.state not in ~w(prepared evaluating ready) do
        Repo.rollback(:effect_not_revisable)
      end

      revision = effect.revision + 1
      target = plain(Map.get(attrs, :target, effect.target))
      payload_ref = Map.get(attrs, :payload_ref, effect.payload_ref)
      payload_digest = Map.get(attrs, :payload_digest, effect.payload_digest)
      vector = Map.put(effect.version_vector, "effect_revision", revision)

      {:ok, updated} =
        effect
        |> Effect.changeset(%{
          revision: revision,
          target: target,
          payload_ref: payload_ref,
          payload_digest: payload_digest,
          version_vector: vector,
          state: "prepared"
        })
        |> Repo.update()

      append_event_locked!(episode, :effect_revised, %{
        effect_id: effect_id,
        revision: revision,
        payload_digest: payload_digest
      })

      effect_from_row(updated)
    end)
  end

  def mark_effect_evaluating(effect_id) do
    transition(effect_id, :evaluating, :effect_evaluating, %{})
  end

  def mark_effect_ready(effect_id) do
    transition(effect_id, :ready, :effect_ready, %{})
  end

  def record_effect_decision(effect_id, decision) when is_map(decision) do
    with_locked_effect(effect_id, fn episode, effect ->
      validate_decision_binding!(episode, effect, decision)

      attrs = %{
        id: Map.get(decision, :id, Canonical.id()),
        effect_id: effect.id,
        effect_revision: effect.revision,
        kind: decision |> fetch(:kind) |> to_string(),
        decision: decision |> fetch(:decision) |> to_string(),
        source_ref: Map.get(decision, :source_ref),
        episode_id: effect.episode_id,
        epoch: effect.epoch,
        policy_version: get_in(effect.version_vector, ["policy_version"]),
        trajectory_version: get_in(effect.version_vector, ["trajectory_version"]),
        snapshot_ref: Map.get(decision, :snapshot_ref),
        expires_at_ms: Map.get(decision, :expires_at),
        payload_digest: effect.payload_digest,
        evidence_ref: Map.get(decision, :evidence_ref),
        signature: plain(Map.get(decision, :signature)),
        created_at_ms: Map.get(decision, :created_at, Canonical.now()),
        metadata: plain(Map.get(decision, :metadata, %{}))
      }

      decision_kind = attrs.kind
      source_ref = attrs.source_ref

      existing =
        from(d in EffectDecision,
          where:
            d.effect_id == ^effect.id and d.effect_revision == ^effect.revision and
              d.kind == ^decision_kind and d.source_ref == ^source_ref,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      persist_decision(existing, attrs, episode, effect)
    end)
  end

  defp persist_decision(existing, attrs, episode, effect) do
    if existing do
      if same_decision?(existing, attrs),
        do: decision_to_map(existing),
        else: Repo.rollback(:conflicting_effect_decision)
    else
      case %EffectDecision{} |> EffectDecision.changeset(attrs) |> Repo.insert() do
        {:ok, row} ->
          append_event_locked!(episode, :effect_decision, %{
            effect_id: effect.id,
            revision: effect.revision,
            kind: row.kind,
            decision: row.decision,
            evidence_ref: row.evidence_ref
          })

          decision_to_map(row)

        {:error, changeset} ->
          Repo.rollback({:invalid_decision, changeset})
      end
    end
  end

  def effect_decisions(effect_id, revision \\ nil) do
    query =
      from(d in EffectDecision,
        where: d.effect_id == ^effect_id,
        order_by: [asc: d.created_at_ms]
      )

    query =
      if is_nil(revision),
        do: query,
        else: from(d in query, where: d.effect_revision == ^revision)

    {:ok, Enum.map(Repo.all(query), &decision_to_map/1)}
  rescue
    error -> {:error, {:store_error, error}}
  end

  def begin_effect_commit(effect_id, required_decisions) when is_list(required_decisions) do
    with {:ok, preliminary} <- effect_row(effect_id) do
      Repo.transaction(fn ->
        episode = lock_episode!(preliminary.episode_id)
        effect = lock_effect!(effect_id)
        lease = lock_lease!(effect.lease_id)
        now = Canonical.now()

        validate_commit_horizon!(episode, effect, lease, now)
        validate_required_decisions!(effect, required_decisions, now)

        attempt = Canonical.id()
        key = effect.idempotency_key || "autonomic-#{effect.id}"

        {:ok, updated} =
          effect
          |> Effect.changeset(%{
            state: "commit_intent",
            commit_attempt_id: attempt,
            idempotency_key: key,
            version_vector_at_commit: effect.version_vector,
            commit_started_at_ms: now
          })
          |> Repo.update()

        append_event_locked!(episode, :effect_commit_intent, %{
          effect_id: effect.id,
          revision: effect.revision,
          commit_attempt_id: attempt,
          idempotency_key: key,
          version_vector: effect.version_vector
        })

        effect_from_row(updated)
      end)
      |> tx_result()
    end
  end

  def mark_committing(effect_id), do: transition(effect_id, :committing, :effect_committing, %{})

  def complete_effect(effect_id, outcome, details \\ %{})

  def complete_effect(effect_id, :committed, details) do
    terminal_transition(
      effect_id,
      "committed",
      %{
        committed_at_ms: Canonical.now(),
        external_receipt: plain(Map.get(details, :receipt, %{})),
        external_receipt_ref: Map.get(details, :receipt_ref),
        failure: nil
      },
      :effect_committed
    )
  end

  def complete_effect(effect_id, :failed, details) do
    terminal_transition(
      effect_id,
      "failed",
      %{failure: plain(Map.get(details, :failure, details))},
      :effect_failed
    )
  end

  def complete_effect(effect_id, :commit_unknown, details) do
    terminal_transition(
      effect_id,
      "commit_unknown",
      %{failure: plain(Map.get(details, :failure, details))},
      :effect_commit_unknown
    )
  end

  def reconcile_effect(effect_id, outcome, details \\ %{}) do
    with_locked_effect(effect_id, fn episode, effect ->
      unless effect.state in @commit_states do
        Repo.rollback(:not_reconcilable)
      end

      attrs =
        case outcome do
          :committed ->
            %{
              state: "committed",
              committed_at_ms: Canonical.now(),
              external_receipt: plain(Map.get(details, :receipt, %{})),
              external_receipt_ref: Map.get(details, :receipt_ref),
              failure: nil
            }

          :not_committed ->
            %{state: "ready", commit_attempt_id: nil, commit_started_at_ms: nil, failure: nil}

          :unknown ->
            %{
              state: "commit_unknown",
              failure: plain(Map.get(details, :failure, %{reason: "reconciliation_unknown"}))
            }

          :failed ->
            %{state: "failed", failure: plain(Map.get(details, :failure, details))}
        end

      {:ok, updated} = effect |> Effect.changeset(attrs) |> Repo.update()

      append_event_locked!(episode, :effect_reconciled, %{
        effect_id: effect.id,
        outcome: outcome,
        details: plain(details)
      })

      effect_from_row(updated)
    end)
  end

  def pending_reconciliation do
    rows =
      from(e in Effect, where: e.state in ^@commit_states, order_by: [asc: e.updated_at])
      |> Repo.all()

    {:ok, Enum.map(rows, &effect_from_row/1)}
  rescue
    error -> {:error, {:store_error, error}}
  end

  def put_checkpoint(%EpisodeCheckpoint{} = checkpoint) do
    attrs = checkpoint_to_attrs(checkpoint)

    Repo.transaction(fn ->
      episode = lock_episode!(checkpoint.episode_id)

      if episode.current_epoch != checkpoint.epoch do
        Repo.rollback(:stale_checkpoint_epoch)
      end

      case %Checkpoint{} |> Checkpoint.changeset(attrs) |> Repo.insert() do
        {:ok, row} ->
          update_stable_checkpoint(episode, row, checkpoint.trust_level)

          append_event_locked!(episode, :checkpoint_recorded, %{
            checkpoint_id: row.id,
            epoch: row.epoch,
            filesystem_digest: row.filesystem_digest,
            trust_level: row.trust_level
          })

          checkpoint_from_row(row)

        {:error, changeset} ->
          Repo.rollback({:invalid_checkpoint, changeset})
      end
    end)
    |> tx_result()
  end

  defp update_stable_checkpoint(episode, row, :stable) do
    {:ok, _} = episode |> Episode.changeset(%{current_checkpoint_id: row.id}) |> Repo.update()
  end

  defp update_stable_checkpoint(_episode, _row, _trust), do: :ok

  def latest_stable_checkpoint(episode_id) do
    query =
      from(c in Checkpoint,
        where: c.episode_id == ^episode_id and c.trust_level == "stable",
        order_by: [desc: c.created_at_ms],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :not_found
      row -> {:ok, checkpoint_from_row(row)}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def checkpoint(id) do
    case Repo.get(Checkpoint, id) do
      nil -> :not_found
      row -> {:ok, checkpoint_from_row(row)}
    end
  end

  def update_trajectory(episode_id, homeostatic_state) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      version = Map.fetch!(homeostatic_state, :trajectory_version)
      state_epoch = Map.fetch!(homeostatic_state, :epoch)

      if state_epoch != episode.current_epoch, do: Repo.rollback(:stale_trajectory_epoch)

      if version < episode.trajectory_version do
        Repo.rollback(:stale_trajectory)
      end

      attrs = %{
        trajectory_version: version,
        trajectory_regime: homeostatic_state.regime |> to_string(),
        trajectory_state: plain(homeostatic_state)
      }

      {:ok, updated} = episode |> Episode.changeset(attrs) |> Repo.update()

      append_event_locked!(updated, :trajectory_updated, %{
        version: version,
        regime: attrs.trajectory_regime
      })

      :ok
    end)
    |> tx_result()
  end

  def record_observation(frame) do
    semantic =
      Enum.map(frame.semantic, fn
        %SemanticObservation{} = observation -> plain(Map.from_struct(observation))
        other -> plain(other)
      end)

    canonical = %{
      episode_id: frame.episode_id,
      epoch: frame.epoch,
      sequence: frame.sequence,
      observed_at: frame.observed_at,
      deterministic: frame.deterministic,
      semantic: semantic,
      resource: frame.resource,
      effect_context: frame.effect_context,
      dropped_low_priority_count: frame.dropped_low_priority_count,
      metadata: frame.metadata
    }

    attrs = %{
      episode_id: frame.episode_id,
      epoch: frame.epoch,
      sequence: frame.sequence,
      observed_at_ms: frame.observed_at,
      deterministic: plain(frame.deterministic),
      semantic: semantic,
      resource: plain(frame.resource),
      effect_context: plain(frame.effect_context),
      dropped_low_priority_count: frame.dropped_low_priority_count,
      evidence_digest: Canonical.digest(canonical),
      metadata: plain(frame.metadata)
    }

    case %ObservationFrame{} |> ObservationFrame.changeset(attrs) |> Repo.insert() do
      {:ok, row} -> {:ok, "observation:#{row.id}:#{row.evidence_digest}"}
      {:error, changeset} -> {:error, {:invalid_observation, changeset}}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def record_recovery(attrs) do
    attrs = Map.merge(%{id: Canonical.id(), created_at_ms: Canonical.now(), metadata: %{}}, attrs)
    attrs = Map.update(attrs, :metadata, %{}, &plain/1)

    case %RecoveryRecord{} |> RecoveryRecord.changeset(attrs) |> Repo.insert() do
      {:ok, row} -> {:ok, row.id}
      {:error, changeset} -> {:error, {:invalid_recovery_record, changeset}}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  def claim_episode(episode_id, owner_node, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      now = DateTime.utc_now()
      expires = DateTime.add(now, ttl_ms, :millisecond)

      if is_nil(episode.owner_lease_expires_at) or
           DateTime.compare(episode.owner_lease_expires_at, now) == :lt or
           episode.owner_node == owner_node do
        token = Canonical.id()

        {:ok, _} =
          episode
          |> Episode.changeset(%{
            owner_node: owner_node,
            owner_lease_token: token,
            owner_lease_expires_at: expires
          })
          |> Repo.update()

        token
      else
        Repo.rollback(:owned_elsewhere)
      end
    end)
    |> tx_result()
  end

  def renew_episode_owner(episode_id, token, ttl_ms) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      if episode.owner_lease_token != token, do: Repo.rollback(:owner_token_mismatch)
      expires = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
      {:ok, _} = episode |> Episode.changeset(%{owner_lease_expires_at: expires}) |> Repo.update()
      :ok
    end)
    |> tx_result()
  end

  @impl true
  def append_event(episode_id, kind, payload) do
    Repo.transaction(fn ->
      episode = lock_episode!(episode_id)
      append_event_locked!(episode, kind, payload)
    end)
    |> tx_result()
  end

  defp transition(effect_id, to, event, metadata) do
    with_locked_effect(effect_id, fn episode, effect ->
      from_state = EffectState.parse_state(effect.state)

      if not EffectState.allowed?(from_state, to),
        do: Repo.rollback({:invalid_effect_transition, from_state, to})

      {:ok, updated} = effect |> Effect.changeset(%{state: to_string(to)}) |> Repo.update()

      append_event_locked!(
        episode,
        event,
        Map.merge(%{effect_id: effect_id, from: from_state, to: to}, plain(metadata))
      )

      effect_from_row(updated)
    end)
  end

  defp terminal_transition(effect_id, to, attrs, event) do
    with_locked_effect(effect_id, fn episode, effect ->
      from_state = EffectState.parse_state(effect.state)
      to_state = EffectState.parse_state(to)

      if not EffectState.allowed?(from_state, to_state),
        do: Repo.rollback({:invalid_effect_transition, from_state, to_state})

      {:ok, updated} = effect |> Effect.changeset(Map.put(attrs, :state, to)) |> Repo.update()

      append_event_locked!(episode, event, %{
        effect_id: effect_id,
        from: from_state,
        to: to_state,
        details: plain(attrs)
      })

      effect_from_row(updated)
    end)
  end

  defp validate_decision_binding!(episode, effect, decision) do
    now = Canonical.now()
    expected = effect.version_vector

    checks = [
      {episode.current_epoch == effect.epoch, :stale_authority},
      {Map.get(decision, :effect_revision, effect.revision) == effect.revision,
       :stale_effect_revision},
      {Map.get(decision, :epoch, effect.epoch) == effect.epoch, :stale_decision_epoch},
      {Map.get(decision, :policy_version, expected["policy_version"]) ==
         expected["policy_version"], :stale_decision_policy},
      {Map.get(decision, :trajectory_version, expected["trajectory_version"]) ==
         expected["trajectory_version"], :stale_decision_trajectory},
      {Map.get(decision, :payload_digest, effect.payload_digest) == effect.payload_digest,
       :stale_decision_payload},
      {is_nil(Map.get(decision, :expires_at)) or Map.get(decision, :expires_at) > now,
       :expired_decision}
    ]

    case Enum.find(checks, fn {ok?, _} -> not ok? end) do
      nil -> :ok
      {_, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_commit_horizon!(episode, effect, lease, now) do
    vector = effect.version_vector

    checks = [
      {episode.current_epoch == effect.epoch, :stale_authority},
      {effect.state == "ready", :effect_not_ready},
      {lease.episode_id == effect.episode_id and lease.epoch == effect.epoch, :stale_lease},
      {is_nil(lease.revoked_at_ms) and lease.expires_at_ms > now, :expired_or_revoked_lease},
      {vector["epoch"] == episode.current_epoch, :stale_version_epoch},
      {vector["policy_version"] == episode.policy_version, :stale_policy},
      {vector["trajectory_version"] == episode.trajectory_version, :stale_trajectory},
      {vector["effect_revision"] == effect.revision, :stale_effect_revision},
      {is_nil(effect.expires_at_ms) or effect.expires_at_ms > now, :effect_expired}
    ]

    case Enum.find(checks, fn {ok?, _} -> not ok? end) do
      nil -> :ok
      {_, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_required_decisions!(effect, required, now) do
    rows =
      from(d in EffectDecision,
        where: d.effect_id == ^effect.id and d.effect_revision == ^effect.revision,
        order_by: [asc: d.created_at_ms]
      )
      |> Repo.all()

    if Enum.any?(rows, &(&1.decision == "deny")), do: Repo.rollback(:decision_denied)

    valid =
      Enum.filter(rows, fn row ->
        valid_decision?(row, effect, now)
      end)
      |> MapSet.new(& &1.kind)

    missing = required |> Enum.map(&to_string/1) |> Enum.reject(&MapSet.member?(valid, &1))
    if missing != [], do: Repo.rollback({:missing_decisions, missing})
  end

  defp valid_decision?(row, effect, now) do
    row.decision == "allow" and
      row.epoch == effect.epoch and
      row.policy_version == effect.version_vector["policy_version"] and
      row.trajectory_version == effect.version_vector["trajectory_version"] and
      row.payload_digest == effect.payload_digest and
      (is_nil(row.expires_at_ms) or row.expires_at_ms > now)
  end

  defp same_decision?(row, attrs) do
    row.decision == attrs.decision and
      row.epoch == attrs.epoch and
      row.policy_version == attrs.policy_version and
      row.trajectory_version == attrs.trajectory_version and
      row.payload_digest == attrs.payload_digest and
      row.evidence_ref == attrs.evidence_ref
  end

  # Every effect mutation locks the episode before the effect, preserving one lock order.
  defp with_locked_effect(effect_id, operation) do
    with {:ok, preliminary} <- effect_row(effect_id) do
      Repo.transaction(fn ->
        episode = lock_episode!(preliminary.episode_id)
        effect = lock_effect!(effect_id)
        operation.(episode, effect)
      end)
      |> tx_result()
    end
  end

  defp require_checks!(checks) do
    case Enum.find(checks, fn {ok?, _} -> not ok? end) do
      nil -> :ok
      {_, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_episode!(episode_id) do
    from(e in Episode, where: e.id == ^episode_id, lock: "FOR UPDATE") |> Repo.one!()
  end

  defp lock_effect!(effect_id) do
    from(e in Effect, where: e.id == ^effect_id, lock: "FOR UPDATE") |> Repo.one!()
  end

  defp lock_lease!(lease_id) do
    from(l in LeaseRow, where: l.id == ^lease_id, lock: "FOR UPDATE") |> Repo.one!()
  end

  defp effect_row(effect_id) do
    case Repo.get(Effect, effect_id) do
      nil -> :not_found
      row -> {:ok, row}
    end
  rescue
    error -> {:error, {:store_error, error}}
  end

  defp append_event_locked!(episode, kind, payload) do
    previous =
      from(e in EpisodeEvent,
        where: e.episode_id == ^episode.id,
        order_by: [desc: e.sequence],
        limit: 1
      )
      |> Repo.one()

    sequence = if previous, do: previous.sequence + 1, else: 1
    previous_hash = if previous, do: previous.entry_hash, else: nil
    now = Canonical.now()

    body = %{
      episode_id: episode.id,
      sequence: sequence,
      kind: to_string(kind),
      payload: plain(payload),
      previous_hash: previous_hash,
      created_at_ms: now
    }

    entry_hash = Canonical.digest(body)

    attrs = Map.put(body, :entry_hash, entry_hash)
    {:ok, row} = %EpisodeEvent{} |> EpisodeEvent.changeset(attrs) |> Repo.insert()
    row.sequence
  end

  defp effect_to_attrs(effect) do
    %{
      id: effect.id,
      episode_id: effect.episode_id,
      epoch: effect.epoch,
      lease_id: effect.lease_id,
      revision: effect.revision || effect.version_vector.effect_revision,
      class: to_string(effect.class),
      kind: to_string(effect.kind),
      target: plain(effect.target),
      payload_ref: effect.payload_ref,
      payload_digest: effect.payload_digest || effect.payload_ref,
      reversible: effect.reversible?,
      state: to_string(effect.state),
      version_vector: plain(Map.from_struct(effect.version_vector)),
      idempotency_key: effect.idempotency_key,
      commit_attempt_id: effect.commit_attempt_id,
      expires_at_ms: effect.expires_at,
      committed_at_ms: effect.committed_at,
      external_receipt_ref: effect.external_receipt_ref,
      failure: plain(effect.failure),
      created_at_ms: effect.created_at,
      metadata: plain(effect.metadata)
    }
  end

  defp effect_from_row(row) do
    vector = row.version_vector

    %ProposedEffect{
      id: row.id,
      episode_id: row.episode_id,
      epoch: row.epoch,
      lease_id: row.lease_id,
      class: String.to_existing_atom(row.class),
      kind: safe_kind(row.kind),
      target: row.target,
      payload_ref: row.payload_ref,
      payload_digest: row.payload_digest,
      revision: row.revision,
      reversible?: row.reversible,
      state: String.to_existing_atom(row.state),
      version_vector: %VersionVector{
        episode_id: vector["episode_id"],
        epoch: vector["epoch"],
        policy_version: vector["policy_version"],
        snapshot_ancestry: vector["snapshot_ancestry"] || [],
        trajectory_version: vector["trajectory_version"],
        trajectory_regime: String.to_existing_atom(vector["trajectory_regime"]),
        lease_id: vector["lease_id"],
        effect_revision: vector["effect_revision"]
      },
      expires_at: row.expires_at_ms,
      idempotency_key: row.idempotency_key,
      commit_attempt_id: row.commit_attempt_id,
      committed_at: row.committed_at_ms,
      external_receipt_ref: row.external_receipt_ref,
      failure: row.failure,
      created_at: row.created_at_ms,
      approvals: [],
      verifications: [],
      metadata: Map.put(row.metadata || %{}, "external_receipt", row.external_receipt)
    }
  end

  defp lease_to_attrs(lease) do
    %{
      id: lease.id,
      episode_id: lease.episode_id,
      epoch: lease.epoch,
      policy_version: lease.policy_version,
      capabilities: Enum.map(lease.capabilities, &plain(Map.from_struct(&1))),
      max_effect_class: to_string(lease.max_effect_class),
      issued_at_ms: lease.issued_at,
      expires_at_ms: lease.expires_at,
      revoked_at_ms: lease.revoked_at,
      authority_source: to_string(lease.authority_source),
      authority_ref: lease.authority_ref,
      reason: lease.reason,
      metadata: plain(lease.metadata)
    }
  end

  defp lease_from_row(row) do
    capabilities =
      Enum.map(row.capabilities || [], fn capability ->
        %Capability{
          kind: safe_kind(capability["kind"]),
          scope: capability["scope"],
          constraints: atomize_known_constraint_keys(capability["constraints"] || %{})
        }
      end)

    %CapabilityLease{
      id: row.id,
      episode_id: row.episode_id,
      epoch: row.epoch,
      policy_version: row.policy_version,
      capabilities: capabilities,
      max_effect_class: String.to_existing_atom(row.max_effect_class),
      issued_at: row.issued_at_ms,
      expires_at: row.expires_at_ms,
      authority_source: String.to_existing_atom(row.authority_source),
      authority_ref: row.authority_ref,
      reason: row.reason,
      revoked_at: row.revoked_at_ms,
      metadata: row.metadata || %{}
    }
  end

  defp checkpoint_to_attrs(checkpoint) do
    checkpoint
    |> Map.from_struct()
    |> Map.put(:id, checkpoint.id || Canonical.id())
    |> Map.put(
      :trust_level,
      if(checkpoint.trust_level, do: to_string(checkpoint.trust_level), else: nil)
    )
    |> Map.put(:created_at_ms, checkpoint.created_at)
    |> Map.delete(:created_at)
    |> Map.update!(:metadata, &plain/1)
  end

  defp checkpoint_from_row(row) do
    %EpisodeCheckpoint{
      id: row.id,
      episode_id: row.episode_id,
      epoch: row.epoch,
      domain_generation: row.domain_generation,
      filesystem_ref: row.filesystem_ref,
      filesystem_digest: row.filesystem_digest,
      git_base_ref: row.git_base_ref,
      git_patch_digest: row.git_patch_digest,
      trajectory_version: row.trajectory_version,
      trajectory_ref: row.trajectory_ref,
      policy_version: row.policy_version,
      capability_state_ref: row.capability_state_ref,
      environment_digest: row.environment_digest,
      dependency_lock_digest: row.dependency_lock_digest,
      parent_checkpoint_id: row.parent_checkpoint_id,
      trust_level: if(row.trust_level, do: String.to_existing_atom(row.trust_level), else: nil),
      created_at: row.created_at_ms,
      pending_effect_ids: row.pending_effect_ids || [],
      metadata: row.metadata || %{}
    }
  end

  defp decision_to_map(row) do
    %{
      id: row.id,
      effect_id: row.effect_id,
      effect_revision: row.effect_revision,
      kind: row.kind,
      decision: row.decision,
      source_ref: row.source_ref,
      episode_id: row.episode_id,
      epoch: row.epoch,
      policy_version: row.policy_version,
      trajectory_version: row.trajectory_version,
      snapshot_ref: row.snapshot_ref,
      expires_at: row.expires_at_ms,
      payload_digest: row.payload_digest,
      evidence_ref: row.evidence_ref,
      signature: row.signature,
      created_at: row.created_at_ms,
      metadata: row.metadata || %{}
    }
  end

  defp episode_to_map(row) do
    %{
      id: row.id,
      state: safe_kind(row.state),
      current_epoch: row.current_epoch,
      policy_id: row.policy_id,
      policy_version: row.policy_version,
      policy_digest: row.policy_digest,
      policy: row.policy,
      hard_envelope: row.hard_envelope,
      origin_intent_digest: row.origin_intent_digest,
      current_checkpoint_id: row.current_checkpoint_id,
      domain_ref: row.domain_ref,
      domain_generation: row.domain_generation,
      domain_os_ref: row.domain_os_ref,
      domain_metadata: row.domain_metadata || %{},
      trajectory_version: row.trajectory_version,
      trajectory_regime: String.to_existing_atom(row.trajectory_regime),
      trajectory_state: row.trajectory_state || %{},
      owner_node: row.owner_node,
      owner_lease_token: row.owner_lease_token,
      owner_lease_expires_at: row.owner_lease_expires_at,
      metadata: row.metadata || %{}
    }
  end

  defp safe_kind(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize_known_constraint_keys(map) do
    Map.new(map, fn
      {"max_effect_class", value} when is_binary(value) -> {:max_effect_class, safe_kind(value)}
      {"max_effect_class", value} -> {:max_effect_class, value}
      {key, value} -> {key, value}
    end)
  end

  defp fetch(map, key), do: Map.fetch!(map, key)
  defp plain(nil), do: nil
  defp plain(value), do: Canonical.plain(value)

  defp tx_result({:ok, :ok}), do: :ok
  defp tx_result({:ok, value}), do: {:ok, value}
  defp tx_result({:error, reason}), do: {:error, reason}
end
