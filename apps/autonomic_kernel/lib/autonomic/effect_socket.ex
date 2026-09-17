defmodule Autonomic.EffectSocket do
  @moduledoc "Per-episode bounded AF_UNIX ingress. Direct INET is never provided to the sandbox."
  use GenServer

  alias Autonomic.{EffectBroker, Runtime}

  @protocol 1
  @max_frame 1_048_576

  def start_link(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    GenServer.start_link(__MODULE__, opts, name: Runtime.via(episode_id, :effect_socket))
  end

  def path(episode_id), do: GenServer.call(Runtime.via(episode_id, :effect_socket), :path)

  @impl true
  def init(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    dir = Path.join(Runtime.root(), "sockets")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, episode_id <> ".sock")

    with :ok <- safe_remove_socket(path),
         {:ok, socket} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.bind(socket, %{family: :local, path: String.to_charlist(path)}),
         :ok <- :socket.listen(socket, 32) do
      File.chmod!(path, 0o600)
      state = %{episode_id: episode_id, path: path, socket: socket}
      send(self(), :accept)
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:effect_socket_failed, reason}}
    end
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_info(:accept, state) do
    parent = self()
    socket = state.socket
    episode_id = state.episode_id

    Task.Supervisor.start_child(Autonomic.Tasks, fn ->
      case :socket.accept(socket) do
        {:ok, client} ->
          handle_client(client, episode_id)
          :socket.close(client)

        _ ->
          :ok
      end

      send(parent, :accept)
    end)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :socket.close(state.socket)
    File.rm(state.path)
    :ok
  end

  defp handle_client(socket, episode_id) do
    case recv_frame(socket) do
      {:ok, payload} ->
        response = payload |> decode_request() |> dispatch(episode_id) |> encode_response()
        _ = send_frame(socket, response)

      {:error, reason} ->
        _ = send_frame(socket, encode_response({:error, reason}))
    end
  end

  defp decode_request(payload) do
    with {:ok, request} <- Jason.decode(payload),
         true <- is_map(request),
         @protocol <- Map.get(request, "protocol"),
         id when is_binary(id) <- Map.get(request, "request_id"),
         epoch when is_integer(epoch) and epoch > 0 <- Map.get(request, "epoch"),
         action
         when action in ["prepare", "evaluate", "commit", "abort", "status", "fetch_response"] <-
           Map.get(request, "action") do
      {:ok, request}
    else
      _ -> {:error, :invalid_broker_request}
    end
  end

  defp dispatch({:error, _} = error, _), do: error

  defp dispatch({:ok, request}, episode_id) do
    with {:ok, current_epoch} <- Runtime.store().current_epoch(episode_id),
         true <- request["epoch"] == current_epoch do
      dispatch_current(request, episode_id)
    else
      false -> {:error, :stale_request_epoch}
      {:error, _} = error -> error
    end
  end

  defp dispatch_current(request, episode_id) do
    case request["action"] do
      "prepare" ->
        attrs = %{
          episode_id: episode_id,
          lease_id: request["lease_id"],
          kind: request["kind"],
          target_id: request["target_id"],
          target: request["target"] || %{},
          payload: decode_payload(request["payload_b64"]),
          metadata: %{broker_request_id: request["request_id"]}
        }

        EffectBroker.prepare(attrs)

      "evaluate" ->
        with {:ok, effect} <- effect_for_episode(request["effect_id"], episode_id) do
          EffectBroker.evaluate(effect.id)
        end

      "commit" ->
        with {:ok, effect} <- effect_for_episode(request["effect_id"], episode_id) do
          EffectBroker.commit(effect.id)
        end

      "abort" ->
        with {:ok, effect} <- effect_for_episode(request["effect_id"], episode_id) do
          EffectBroker.abort(effect.id, :worker_abort)
        end

      "status" ->
        effect_for_episode(request["effect_id"], episode_id)

      "fetch_response" ->
        fetch_response(request, episode_id)
    end
  rescue
    _ -> {:error, :invalid_broker_request}
  end

  defp fetch_response(request, episode_id) do
    with {:ok, effect} <- effect_for_episode(request["effect_id"], episode_id),
         true <- effect.kind == :http_read and effect.state == :committed,
         receipt when is_map(receipt) <- Map.get(effect.metadata, "external_receipt", %{}),
         ref when is_binary(ref) <-
           Map.get(receipt, "response_ref") || Map.get(receipt, :response_ref),
         {:ok, bytes} <- Autonomic.Payloads.get(episode_id, ref) do
      offset = bounded_integer(request["offset"], 0, 0, byte_size(bytes))
      limit = bounded_integer(request["limit"], 262_144, 1, 524_288)
      remaining = max(byte_size(bytes) - offset, 0)
      chunk = binary_part(bytes, offset, min(limit, remaining))

      {:ok,
       %{
         offset: offset,
         bytes: byte_size(chunk),
         total_bytes: byte_size(bytes),
         body_digest: Autonomic.Canonical.hash(bytes),
         eof: offset + byte_size(chunk) >= byte_size(bytes),
         chunk_b64: Base.encode64(chunk)
       }}
    else
      false -> {:error, :response_not_available}
      _ -> {:error, :response_not_available}
    end
  end

  defp effect_for_episode(id, episode_id) when is_binary(id) do
    case Runtime.store().fetch_effect(id) do
      {:ok, %{episode_id: ^episode_id} = effect} -> {:ok, effect}
      {:ok, _} -> {:error, :effect_episode_mismatch}
      other -> other
    end
  end

  defp effect_for_episode(_, _), do: {:error, :invalid_effect_id}

  defp decode_payload(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> bytes
      :error -> raise ArgumentError, "invalid payload encoding"
    end
  end

  defp decode_payload(_), do: raise(ArgumentError, "payload required")

  defp bounded_integer(value, _default, low, high) when is_integer(value),
    do: value |> max(low) |> min(high)

  defp bounded_integer(_, default, _low, _high), do: default

  defp encode_response({:ok, value}), do: Jason.encode!(%{ok: true, result: safe_result(value)})
  defp encode_response(:ok), do: Jason.encode!(%{ok: true, result: nil})

  defp encode_response({:error, reason}),
    do: Jason.encode!(%{ok: false, error: inspect(reason, limit: 20, printable_limit: 1_024)})

  defp encode_response(other),
    do: Jason.encode!(%{ok: false, error: inspect(other, limit: 20, printable_limit: 1_024)})

  defp safe_result(%Autonomic.ProposedEffect{} = effect) do
    receipt =
      if effect.kind == :http_read do
        effect.metadata
        |> Map.get("external_receipt")
        |> then(&(&1 || %{}))
        |> Map.take(["status", "body_digest", "body_bytes", "response_ref", "receipt_ref"])
      else
        nil
      end

    %{
      id: effect.id,
      episode_id: effect.episode_id,
      epoch: effect.epoch,
      revision: effect.revision,
      class: effect.class,
      kind: effect.kind,
      state: effect.state,
      payload_digest: effect.payload_digest,
      commit_attempt_id: effect.commit_attempt_id,
      committed_at: effect.committed_at,
      external_receipt_ref: effect.external_receipt_ref,
      receipt: receipt
    }
  end

  defp safe_result(value) when is_map(value),
    do: value |> Map.drop([:failure, "failure", :metadata, "metadata"])

  defp safe_result(value), do: value

  defp recv_frame(socket) do
    with {:ok, <<size::unsigned-big-integer-size(32)>>} <- recv_exact(socket, 4),
         true <- size > 0 and size <= @max_frame,
         {:ok, payload} <- recv_exact(socket, size) do
      {:ok, payload}
    else
      false -> {:error, :frame_too_large}
      {:error, _} = error -> error
      _ -> {:error, :invalid_frame}
    end
  end

  defp recv_exact(socket, size), do: recv_exact(socket, size, <<>>)
  defp recv_exact(_socket, 0, acc), do: {:ok, acc}

  defp recv_exact(socket, remaining, acc) do
    case :socket.recv(socket, remaining, 15_000) do
      {:ok, data} when byte_size(data) > 0 ->
        recv_exact(socket, remaining - byte_size(data), acc <> data)

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :closed}
    end
  end

  defp send_frame(socket, payload) when byte_size(payload) <= @max_frame do
    :socket.send(socket, <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>)
  end

  defp safe_remove_socket(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other}} -> File.rm(path)
      {:ok, _} -> {:error, :refuse_to_replace_non_socket_path}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
