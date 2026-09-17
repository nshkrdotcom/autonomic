defmodule Autonomic.RateLimiter do
  @moduledoc "Trusted fixed-window limiter for broker-owned external targets."
  use GenServer

  @default_limit 60
  @default_window_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec check(term(), pos_integer(), pos_integer()) ::
          :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(key, limit \\ @default_limit, window_ms \\ @default_window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    GenServer.call(__MODULE__, {:check, key, limit, window_ms})
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:check, key, limit, window_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)

    {started_at, count} =
      case Map.get(state, key) do
        {started_at, count} when now - started_at < window_ms -> {started_at, count}
        _ -> {now, 0}
      end

    if count < limit do
      {:reply, :ok, Map.put(state, key, {started_at, count + 1})}
    else
      retry_after = max(0, window_ms - (now - started_at))
      {:reply, {:error, {:rate_limited, retry_after}}, Map.put(state, key, {started_at, count})}
    end
  end
end
