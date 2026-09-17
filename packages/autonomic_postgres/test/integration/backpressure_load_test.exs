defmodule Autonomic.Store.BackpressureLoadTest do
  use ExUnit.Case, async: false

  alias Autonomic.{AuthorityGovernor, Canonical, EffectBroker, SystemRegulator}
  alias Autonomic.Store.{Postgres, Repo}

  @moduletag :postgres
  @moduletag timeout: 60_000

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE effect_decisions, effects, capability_leases, observation_frames, checkpoints, recovery_records, episode_events, episodes RESTART IDENTITY CASCADE",
      []
    )

    old_targets = Application.get_env(:autonomic, :targets, %{})

    for source <- [:semantic, :store, :launcher], do: SystemRegulator.health(source, :healthy)

    for source <- [:semantic_queue, :effect_queue, :verifier_queue],
        do: SystemRegulator.report(source, 0.0)

    await_mode(:normal)

    on_exit(fn ->
      Application.put_env(:autonomic, :targets, old_targets)
      SystemRegulator.report(:effect_queue, 0.0)
    end)

    :ok
  end

  test "real broker load is bounded and pressure propagates then recovers" do
    limit = EffectBroker.stats().limit
    assert limit >= 2

    {listener, port, server} = start_slow_http_server(limit)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    target_id = "slow-local-http"

    Application.put_env(:autonomic, :targets, %{
      target_id => %{
        "base_url" => "http://127.0.0.1:#{port}",
        "host" => "127.0.0.1",
        "allow_http" => true,
        "path_prefix" => "/slow/",
        "methods" => ["GET"],
        "max_response_bytes" => 4_096,
        "rate_limit" => 100,
        "rate_window_ms" => 10_000,
        "credential_required" => false,
        "timeout_ms" => 10_000
      }
    })

    episode_id = Canonical.id()

    policy = %{
      "id" => "backpressure-policy",
      "version" => 1,
      "max_effect_class" => 2,
      "capabilities" => [%{"kind" => "http_read", "scope" => %{"id" => target_id}}]
    }

    envelope = %{
      "max_effect_class" => 2,
      "capabilities" => [
        %{
          "kind" => "http_read",
          "scope" => %{"id" => target_id},
          "constraints" => %{"max_effect_class" => 2}
        }
      ]
    }

    assert {:ok, _} =
             Postgres.create_episode(%{
               id: episode_id,
               state: "running",
               current_epoch: 1,
               policy_id: policy["id"],
               policy_version: 1,
               policy: policy,
               hard_envelope: envelope,
               origin_intent_digest: Canonical.digest("exercise broker backpressure"),
               trajectory_version: 0,
               trajectory_regime: :stable,
               metadata: %{}
             })

    start_supervised!(
      {AuthorityGovernor, episode_id: episode_id, policy: policy, hard_envelope: envelope}
    )

    assert {:ok, lease} =
             AuthorityGovernor.issue(episode_id, %{
               authority_source: :signed_policy,
               capabilities: envelope["capabilities"],
               max_effect_class: :class_2_external_observable_or_compensatable,
               ttl_ms: 60_000,
               reason: "load gate"
             })

    effects =
      for index <- 1..(limit + 1) do
        assert {:ok, effect} =
                 EffectBroker.prepare(%{
                   episode_id: episode_id,
                   lease_id: lease.id,
                   kind: :http_read,
                   target_id: target_id,
                   target: %{"path" => "/slow/#{index}", "method" => "GET"},
                   payload: ""
                 })

        assert {:ok, ready} = EffectBroker.evaluate(effect.id)
        ready
      end

    {active, overflow} = Enum.split(effects, limit)

    tasks =
      Enum.map(active, fn effect -> Task.async(fn -> EffectBroker.commit(effect.id) end) end)

    await_broker_active(limit)
    await_restricted_mode()
    assert {:error, :effect_broker_saturated} = EffectBroker.commit(hd(overflow).id)

    for task <- tasks do
      assert {:ok, %{state: :committed}} = Task.await(task, 15_000)
    end

    await_broker_active(0)
    await_mode(:normal)
  end

  defp start_slow_http_server(expected_requests) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        accept_slow_clients(listener, expected_requests)
      end)

    {listener, port, server}
  end

  defp accept_slow_clients(listener, expected_requests) do
    Enum.each(1..expected_requests, fn _ ->
      {:ok, client} = :gen_tcp.accept(listener)

      handler = spawn_link(fn -> serve_slow_client(client) end)
      :ok = :gen_tcp.controlling_process(client, handler)
      send(handler, :socket_ready)
    end)
  end

  defp serve_slow_client(client) do
    receive do: (:socket_ready -> :ok)
    {:ok, request} = :gen_tcp.recv(client, 0, 5_000)

    if not String.starts_with?(request, "GET /slow/"),
      do: exit({:unexpected_request, request})

    Process.sleep(1_500)
    body = ~s({"ok":true})

    response =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    :ok = :gen_tcp.send(client, response)
    :gen_tcp.close(client)
  end

  defp await_broker_active(expected, attempts \\ 200)
  defp await_broker_active(_expected, 0), do: flunk("broker active count did not converge")

  defp await_broker_active(expected, attempts) do
    if EffectBroker.stats().active == expected do
      :ok
    else
      Process.sleep(10)
      await_broker_active(expected, attempts - 1)
    end
  end

  defp await_restricted_mode(attempts \\ 200)
  defp await_restricted_mode(0), do: flunk("system regulator did not observe broker saturation")

  defp await_restricted_mode(attempts) do
    if SystemRegulator.mode() in [:no_sensitive_commits, :admission_closed] do
      :ok
    else
      Process.sleep(10)
      await_restricted_mode(attempts - 1)
    end
  end

  defp await_mode(expected, attempts \\ 200)
  defp await_mode(_expected, 0), do: flunk("system regulator mode did not converge")

  defp await_mode(expected, attempts) do
    if SystemRegulator.mode() == expected do
      :ok
    else
      Process.sleep(25)
      await_mode(expected, attempts - 1)
    end
  end
end
