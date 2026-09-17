defmodule Autonomic.Runtime do
  @moduledoc "Concrete implementation selection lives in operator configuration, not core dependencies."
  def store, do: Application.fetch_env!(:autonomic, :store)
  def domain, do: Application.fetch_env!(:autonomic, :domain_backend)
  def sensor, do: Application.fetch_env!(:autonomic, :sensor)
  def via(id, role), do: {:via, Registry, {Autonomic.Registry, {id, role}}}
  def root, do: Application.fetch_env!(:autonomic, :state_dir)

  def target(id) when is_binary(id),
    do: Map.fetch(Application.fetch_env!(:autonomic, :targets), id)

  def adapter(kind) when is_binary(kind),
    do: Map.fetch(Application.fetch_env!(:autonomic, :effect_adapters), kind)
end
