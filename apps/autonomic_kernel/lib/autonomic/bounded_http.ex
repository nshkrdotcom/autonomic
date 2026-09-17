defmodule Autonomic.BoundedHTTP do
  @moduledoc "Streaming HTTP response collection with an enforced byte ceiling."

  def request(method, url, headers, body, target) do
    limit = Map.get(target, "max_response_bytes", 1_048_576)
    timeout = Map.get(target, "timeout_ms", 10_000)

    request =
      Finch.build(
        method,
        url,
        Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end),
        body
      )

    initial = %{status: nil, headers: [], chunks: [], bytes: 0, limit: limit, error: nil}

    case Finch.stream_while(request, Autonomic.HTTPPool, initial, &collect/2,
           receive_timeout: timeout,
           request_timeout: timeout,
           pool_timeout: timeout
         ) do
      {:ok, %{error: nil} = response} ->
        {:ok, response.status, response.headers,
         response.chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, %{error: error}} ->
        {:error, error}

      {:error, reason, _partial} ->
        {:error, {:transport, reason}}
    end
  end

  defp collect({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp collect({:headers, headers}, acc) do
    if :erlang.external_size(headers) > 65_536 do
      {:halt, %{acc | error: :http_headers_too_large}}
    else
      {:cont, %{acc | headers: headers}}
    end
  end

  defp collect({:data, chunk}, acc) do
    bytes = acc.bytes + byte_size(chunk)

    if bytes > acc.limit do
      {:halt, %{acc | error: :http_response_too_large, chunks: []}}
    else
      {:cont, %{acc | bytes: bytes, chunks: [chunk | acc.chunks]}}
    end
  end

  defp collect({:trailers, _headers}, acc), do: {:cont, acc}
end
