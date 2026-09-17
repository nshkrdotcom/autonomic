defmodule Autonomic.Store.EffectSocketHTTPTest do
  use ExUnit.Case, async: false

  alias Autonomic.{AuthorityGovernor, Canonical, EffectSocket}
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
    old_dir = Application.fetch_env!(:autonomic, :state_dir)

    state_dir =
      Path.join(System.tmp_dir!(), "autonomic-broker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    Application.put_env(:autonomic, :state_dir, state_dir)

    on_exit(fn ->
      Application.put_env(:autonomic, :targets, old_targets)
      Application.put_env(:autonomic, :state_dir, old_dir)
      File.rm_rf(state_dir)
    end)

    :ok
  end

  test "real AF_UNIX broker mediates an HTTP read and materializes a bounded response" do
    {listener, port, server} = start_http_server(~s({"source":"trusted-broker","ok":true}))

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    target_id = "local-http"

    target = %{
      "base_url" => "http://127.0.0.1:#{port}",
      "host" => "127.0.0.1",
      "allow_http" => true,
      "path_prefix" => "/public/",
      "methods" => ["GET"],
      "max_response_bytes" => 4_096,
      "rate_limit" => 8,
      "rate_window_ms" => 10_000,
      "credential_required" => false
    }

    Application.put_env(:autonomic, :targets, %{target_id => target})

    episode_id = Canonical.id()

    policy = %{
      "id" => "broker-http-policy",
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

    assert {:ok, _episode} =
             Postgres.create_episode(%{
               id: episode_id,
               state: "running",
               current_epoch: 1,
               policy_id: policy["id"],
               policy_version: 1,
               policy: policy,
               hard_envelope: envelope,
               origin_intent_digest: Canonical.digest("read public fixture"),
               trajectory_version: 0,
               trajectory_regime: :stable,
               metadata: %{}
             })

    start_supervised!(
      {AuthorityGovernor, episode_id: episode_id, policy: policy, hard_envelope: envelope}
    )

    start_supervised!({EffectSocket, episode_id: episode_id})

    assert {:ok, lease} =
             AuthorityGovernor.issue(episode_id, %{
               authority_source: :signed_policy,
               capabilities: envelope["capabilities"],
               max_effect_class: :class_2_external_observable_or_compensatable,
               ttl_ms: 60_000,
               reason: "integration read"
             })

    socket = EffectSocket.path(episode_id)

    assert %{"ok" => true, "result" => prepared} =
             broker_call(socket, %{
               "protocol" => 1,
               "request_id" => Canonical.id(),
               "epoch" => 1,
               "action" => "prepare",
               "lease_id" => lease.id,
               "kind" => "http_read",
               "target_id" => target_id,
               "target" => %{"path" => "/public/status", "method" => "GET"},
               "payload_b64" => Base.encode64("")
             })

    effect_id = prepared["id"]
    assert prepared["state"] == "prepared"

    assert %{"ok" => true, "result" => evaluated} =
             broker_call(socket, %{
               "protocol" => 1,
               "request_id" => Canonical.id(),
               "epoch" => 1,
               "action" => "evaluate",
               "effect_id" => effect_id
             })

    assert evaluated["state"] == "ready"

    assert %{"ok" => true, "result" => committed} =
             broker_call(socket, %{
               "protocol" => 1,
               "request_id" => Canonical.id(),
               "epoch" => 1,
               "action" => "commit",
               "effect_id" => effect_id
             })

    assert committed["state"] == "committed"
    assert committed["receipt"]["status"] == 200
    refute Map.has_key?(committed["receipt"], "body")

    assert %{"ok" => true, "result" => chunk} =
             broker_call(socket, %{
               "protocol" => 1,
               "request_id" => Canonical.id(),
               "epoch" => 1,
               "action" => "fetch_response",
               "effect_id" => effect_id,
               "offset" => 0,
               "limit" => 128
             })

    assert Base.decode64!(chunk["chunk_b64"]) == "{\"source\":\"trusted-broker\",\"ok\":true}"
    assert chunk["eof"] == true
    assert chunk["body_digest"] == Canonical.hash(Base.decode64!(chunk["chunk_b64"]))
  end

  defp broker_call(path, request) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: String.to_charlist(path)})
    payload = Jason.encode!(request)

    :ok =
      :socket.send(socket, <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>)

    {:ok, <<size::unsigned-big-integer-size(32)>>} = recv_exact(socket, 4, <<>>)
    {:ok, response} = recv_exact(socket, size, <<>>)
    :socket.close(socket)
    Jason.decode!(response)
  end

  defp recv_exact(_socket, 0, acc), do: {:ok, acc}

  defp recv_exact(socket, remaining, acc) do
    case :socket.recv(socket, remaining, 10_000) do
      {:ok, data} -> recv_exact(socket, remaining - byte_size(data), acc <> data)
      other -> other
    end
  end

  defp start_http_server(body) do
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
        {:ok, client} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(client, 0, 5_000)

        if not String.starts_with?(request, "GET /public/status "),
          do: exit({:unexpected_request, request})

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(client, response)
        :gen_tcp.close(client)
      end)

    {listener, port, server}
  end
end
