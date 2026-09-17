defmodule Autonomic.Dev.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Autonomic.Dev.MemoryStore,
      Autonomic.Dev.ScriptedSensor,
      Autonomic.Dev.Recorder,
      Autonomic.Dev.TargetStore
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Autonomic.Dev.Supervisor)
  end
end
