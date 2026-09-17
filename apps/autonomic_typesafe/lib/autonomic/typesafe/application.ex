defmodule Autonomic.Typesafe.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Autonomic.Typesafe.Bank, []}],
      strategy: :one_for_one,
      name: Autonomic.Typesafe.Supervisor
    )
  end
end
