defmodule Autonomic.EpisodeSupervisor do
  @moduledoc "Supervised per-episode control tree and trusted episode admission entrypoint."
  use Supervisor

  alias Autonomic.{Canonical, EpisodeSpec, Runtime, SystemRegulator}

  def start_episode(%EpisodeSpec{} = spec) do
    ceiling = spec.requested_effect_ceiling || :class_1_isolated_mutable

    with :ok <- validate_spec(spec),
         true <- SystemRegulator.admit?(ceiling),
         :ok <- ensure_episode_record(spec) do
      DynamicSupervisor.start_child(Autonomic.Episodes, {__MODULE__, spec: spec})
    else
      false -> {:error, :admission_closed}
      {:error, _} = error -> error
    end
  end

  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)
    Supervisor.start_link(__MODULE__, spec, name: Runtime.via(spec.id, :episode_supervisor))
  end

  @impl true
  def init(spec) do
    {:ok, epoch} = Runtime.store().current_epoch(spec.id)

    children = [
      {Autonomic.AuthorityGovernor,
       episode_id: spec.id, policy: spec.policy, hard_envelope: spec.hard_envelope},
      {Autonomic.EffectSocket, episode_id: spec.id},
      {Autonomic.SensorArray, episode_id: spec.id},
      {Autonomic.Homeostat, episode_id: spec.id, epoch: epoch},
      {Autonomic.SensorConsumer, episode_id: spec.id},
      {Autonomic.EpisodeController, spec: spec}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def child_spec(opts) do
    spec = Keyword.fetch!(opts, :spec)

    %{
      id: {__MODULE__, spec.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :supervisor
    }
  end

  defp validate_episode_record(episode, spec) do
    expected_policy_digest = Canonical.digest(spec.policy)
    expected_envelope = Canonical.plain(spec.hard_envelope)
    expected_intent = Canonical.digest(spec.origin_intent)

    cond do
      episode.policy_digest != expected_policy_digest -> {:error, :episode_policy_mismatch}
      episode.hard_envelope != expected_envelope -> {:error, :episode_envelope_mismatch}
      episode.origin_intent_digest != expected_intent -> {:error, :episode_intent_mismatch}
      true -> :ok
    end
  end

  defp ensure_episode_record(spec) do
    case Runtime.store().fetch_episode(spec.id) do
      {:ok, episode} ->
        validate_episode_record(episode, spec)

      :not_found ->
        case Runtime.store().create_episode(%{
               id: spec.id,
               state: "bootstrapping",
               current_epoch: 1,
               policy_id: Map.get(spec.policy, "id"),
               policy_version: Map.get(spec.policy, "version", 1),
               policy: spec.policy,
               hard_envelope: spec.hard_envelope,
               origin_intent_digest: Canonical.digest(spec.origin_intent),
               trajectory_version: 0,
               trajectory_regime: :stable,
               metadata: spec.metadata
             }) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_spec(spec) do
    cond do
      not Regex.match?(~r/\A[0-9a-f]{32}\z/, spec.id) ->
        {:error, :episode_id_must_be_128_bit_hex}

      not is_map(spec.policy) or not is_integer(Map.get(spec.policy, "version")) ->
        {:error, :invalid_policy}

      not is_map(spec.hard_envelope) ->
        {:error, :invalid_hard_envelope}

      not is_map(spec.workspace) ->
        {:error, :invalid_workspace}

      true ->
        :ok
    end
  end
end
