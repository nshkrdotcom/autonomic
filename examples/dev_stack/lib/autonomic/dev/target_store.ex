defmodule Autonomic.Dev.TargetStore do
  @moduledoc "Authoritative-looking in-memory target used by failure-mode examples."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))
  def all, do: Agent.get(__MODULE__, & &1)
end
