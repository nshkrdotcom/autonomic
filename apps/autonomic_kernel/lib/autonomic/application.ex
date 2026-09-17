defmodule Autonomic.Application do
  use Application
  @impl true
  def start(_, _) do
    children = [
      {Registry, keys: :unique, name: Autonomic.Registry},
      {Task.Supervisor, name: Autonomic.Tasks, max_children: 32},
      {Finch, name: Autonomic.HTTPPool, pools: %{default: [size: 8, protocols: [:http1]]}},
      Autonomic.RateLimiter,
      Autonomic.SystemRegulator,
      Autonomic.EffectBroker,
      {DynamicSupervisor, strategy: :one_for_one, name: Autonomic.Episodes}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Autonomic.Supervisor)
  end
end
