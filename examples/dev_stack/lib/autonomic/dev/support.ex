defmodule Autonomic.Dev.Support do
  @moduledoc "Shared helpers for the runnable examples. Never use this module in production."

  alias Autonomic.{Canonical, EffectBroker, EpisodeController, EpisodeSpec, EpisodeSupervisor, Policy}
  alias Autonomic.Dev.{MemoryStore, Recorder, ScriptedSensor, TargetStore}

  @default_target "demo"

  def reset! do
    :ok = MemoryStore.reset()
    :ok = ScriptedSensor.reset()
    :ok = Recorder.reset()
    :ok = TargetStore.reset()
    :ok
  end

  def assert!(true, _message), do: :ok
  def assert!(false, message), do: raise("example assertion failed: #{message}")

  def assert_equal!(actual, expected, label) do
    assert!(actual == expected, "#{label}: expected #{inspect(expected)}, got #{inspect(actual)}")
    actual
  end

  def await!(fun, description, attempts \\ 100) when is_function(fun, 0) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case fun.() do
        {:ok, value} -> {:halt, value}
        true -> {:halt, true}
        _ -> Process.sleep(10); {:cont, nil}
      end
    end) || raise("timed out waiting for #{description}")
  end

  def default_policy(max_class \\ :class_4_irreversible_high_impact, kinds \\ ["http_read", "http_mutation", "publish", "git_remote", "git_commit"], target_id \\ @default_target) do
    %{
      "id" => "examples-policy",
      "version" => 1,
      "max_effect_class" => Atom.to_string(max_class),
      "semantic" => %{"max_risk" => 0.65},
      "capabilities" =>
        Enum.map(kinds, fn kind ->
          %{"kind" => kind, "scope" => %{"id" => target_id}, "max_class" => Atom.to_string(max_class)}
        end)
    }
  end

  def hard_envelope(max_class \\ :class_4_irreversible_high_impact, kinds \\ [:http_read, :http_mutation, :publish, :git_remote, :git_commit], target_id \\ @default_target) do
    %{
      "capabilities" =>
        Enum.map(kinds, fn kind ->
          %{
            "kind" => Atom.to_string(kind),
            "scope" => %{"id" => target_id},
            "constraints" => %{"max_effect_class" => Atom.to_string(max_class)}
          }
        end),
      "max_effect_class" => Atom.to_string(max_class)
    }
  end

  def spec(opts \\ []) do
    id = Keyword.get(opts, :id, Canonical.id())
    max_class = Keyword.get(opts, :max_class, :class_4_irreversible_high_impact)
    target_id = Keyword.get(opts, :target_id, @default_target)
    kinds = Keyword.get(opts, :kinds, ["http_read", "http_mutation", "publish", "git_remote", "git_commit"])
    atom_kinds = Enum.map(kinds, &String.to_existing_atom/1)

    %EpisodeSpec{
      id: id,
      origin_intent: Keyword.get(opts, :origin_intent, "Run a deterministic Autonomic example"),
      workspace: Keyword.get(opts, :workspace, %{}),
      policy: Keyword.get(opts, :policy, default_policy(max_class, kinds, target_id)),
      hard_envelope: Keyword.get(opts, :hard_envelope, hard_envelope(max_class, atom_kinds, target_id)),
      requested_effect_ceiling: max_class,
      worker_argv: [],
      metadata: %{example: true}
    }
  end

  def start_episode!(opts \\ []) do
    spec = spec(opts)
    {:ok, _pid} = EpisodeSupervisor.start_episode(spec)

    await!(fn ->
      case EpisodeController.state(spec.id) do
        {:running, _} -> {:ok, EpisodeController.trusted_runtime(spec.id)}
        _ -> false
      end
    end, "episode #{spec.id} to enter :running")
    |> then(&{spec, &1})
  end

  def complete_episode!(episode_id) do
    EpisodeController.complete(episode_id)

    await!(fn ->
      case EpisodeController.state(episode_id) do
        {:completed, data} -> {:ok, data}
        _ -> false
      end
    end, "episode #{episode_id} to complete")
  end

  def install_adapter!(kind, class, target_opts \\ %{}, adapter \\ Autonomic.Dev.MemoryAdapter) do
    targets = Application.get_env(:autonomic, :targets, %{})
    adapters = Application.get_env(:autonomic, :effect_adapters, %{})
    id = Map.get(target_opts, "id", @default_target)

    Application.put_env(:autonomic, :targets, Map.put(targets, id, Map.put(target_opts, "id", id)))
    Application.put_env(:autonomic, :effect_adapters, Map.put(adapters, to_string(kind), {adapter, class}))
    :ok
  end

  def prepare!(spec, runtime, kind, payload, opts \\ []) do
    target_id = Keyword.get(opts, :target_id, @default_target)
    target = Keyword.get(opts, :target, %{})

    attrs = %{
      episode_id: spec.id,
      lease_id: runtime.lease.id,
      kind: kind,
      target_id: target_id,
      target: target,
      payload: payload,
      reversible?: Keyword.get(opts, :reversible?, true),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, effect} = EffectBroker.prepare(attrs)
    effect
  end

  def evaluate!(effect, opts \\ []) do
    {:ok, ready} = EffectBroker.evaluate(effect.id, opts)
    ready
  end

  def commit!(effect, opts \\ []) do
    {:ok, committed} = EffectBroker.commit(effect.id, opts)
    committed
  end

  def human_approval(effect, key_id, private) do
    document = %{
      "effect_id" => effect.id,
      "effect_revision" => effect.revision,
      "episode_id" => effect.episode_id,
      "epoch" => effect.epoch,
      "payload_digest" => effect.payload_digest,
      "decision" => "allow"
    }

    signed = Policy.sign(document, key_id, private, "human-approval")

    %{
      document: signed["document"],
      key_id: signed["key_id"],
      signature: signed["signature"],
      source_ref: "example:operator"
    }
  end

  def ed25519_keypair! do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {public, private}
  end

  def print_effect(label, effect) do
    IO.puts("\n#{label}")
    IO.inspect(effect, pretty: true, limit: :infinity)
    effect
  end

  def safe_semantic_script(count \\ 1) do
    List.duplicate(ScriptedSensor.safe(), count)
  end
end
