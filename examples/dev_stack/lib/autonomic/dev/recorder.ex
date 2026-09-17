defmodule Autonomic.Dev.Recorder do
  @moduledoc "In-memory narration/event recorder used only by the examples suite."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
  def record(event), do: Agent.update(__MODULE__, &[event | &1])
  def all, do: Agent.get(__MODULE__, &Enum.reverse/1)
end
