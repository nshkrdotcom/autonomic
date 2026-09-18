defmodule Autonomic.Typesafe.Application do
  use Application

  alias Autonomic.Typesafe.Bank

  @impl true
  def start(_type, _args) do
    max_in_flight = Application.get_env(:autonomic_typesafe, :max_in_flight, 8)

    children = [
      {Task.Supervisor, name: Autonomic.Typesafe.Tasks, max_children: max_in_flight}
    ]

    children =
      if Application.get_env(:autonomic_typesafe, :autostart, true) do
        case Bank.configured_client() do
          {:ok, client} -> children ++ [{Bank, client: client}]
          :not_configured -> children
        end
      else
        children
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Autonomic.Typesafe.Supervisor
    )
  end
end
