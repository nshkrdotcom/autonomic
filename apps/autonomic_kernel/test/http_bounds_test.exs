defmodule Autonomic.HTTPBoundsTest do
  use ExUnit.Case, async: false
  alias Autonomic.Adapters.HTTP
  alias Autonomic.Canonical

  test "trusted origin includes its port and scheme" do
    effect = %{kind: :http_read, target: %{"path" => "http://127.0.0.1:9999/public/data"}}

    target = %{
      "base_url" => "http://127.0.0.1:8888",
      "host" => "127.0.0.1",
      "allow_http" => true,
      "path_prefix" => "/public/"
    }

    assert {:error, :http_target_denied} = HTTP.validate(effect, trusted_target: target)
  end

  test "oversized unfinished response is stopped before the server completes it" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(client, 0, 1_000)

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 200 OK\r\nContent-Length: 100000000\r\n\r\n" <> String.duplicate("a", 8192)
          )

        receive do: (:stop -> :ok)
        :gen_tcp.close(client)
      end)

    on_exit(fn ->
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    effect = %{
      id: Canonical.id(),
      episode_id: Canonical.id(),
      kind: :http_read,
      class: :class_2_external_observable_or_compensatable,
      target: %{"path" => "/public/data"}
    }

    target = %{
      "base_url" => "http://127.0.0.1:#{port}",
      "host" => "127.0.0.1",
      "allow_http" => true,
      "path_prefix" => "/public/",
      "max_response_bytes" => 1024,
      "timeout_ms" => 2000
    }

    assert {:error, :http_response_too_large} = HTTP.commit(effect, trusted_target: target)
  end
end
