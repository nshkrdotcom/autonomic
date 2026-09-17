defmodule Autonomic.Postgres.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Autonomic.Store.Repo],
      strategy: :one_for_one,
      name: Autonomic.Store.Supervisor
    )
  end
end

defmodule Autonomic.Store.Application do
  @moduledoc false
  defdelegate start(type, args), to: Autonomic.Postgres.Application
end
