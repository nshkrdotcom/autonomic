defmodule Autonomic.Linux.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Autonomic.Linux.Launcher, []}],
      strategy: :one_for_one,
      name: Autonomic.Linux.Supervisor
    )
  end
end
