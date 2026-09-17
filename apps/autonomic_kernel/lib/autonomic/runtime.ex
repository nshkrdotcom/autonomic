defmodule Autonomic.Runtime do
  @moduledoc "Concrete implementation selection lives in operator configuration, not core dependencies."
  def store, do: Application.fetch_env!(:autonomic_kernel, :store)
  def domain, do: Application.fetch_env!(:autonomic_kernel, :domain_backend)
  def sensor, do: Application.fetch_env!(:autonomic_kernel, :sensor)
  def via(id, role), do: {:via, Registry, {Autonomic.Registry, {id, role}}}
  def root, do: Application.fetch_env!(:autonomic_kernel, :state_dir)
  def target(id) when is_binary(id), do: Map.fetch(Application.fetch_env!(:autonomic_kernel, :targets), id)
  def adapter(kind) when is_binary(kind), do: Map.fetch(Application.fetch_env!(:autonomic_kernel, :effect_adapters), kind)
end
