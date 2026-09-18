alias Autonomic.{Canonical, ExecutionDomain}
alias Autonomic.Dev.{ExecutionDomainCase, Support}

Support.reset!()

defmodule ExampleMicroVMBackend do
  @behaviour Autonomic.ExecutionDomain
  alias Autonomic.ExecutionDomain

  # This is deliberately a backend-author skeleton: no call returns a fake isolated domain.
  def create(%ExecutionDomain.Spec{}), do: {:error, :backend_not_configured}

  def exec(%ExecutionDomain.Domain{}, %ExecutionDomain.Command{}),
    do: {:error, :backend_not_configured}

  def signal(%ExecutionDomain.Domain{}, _signal), do: {:error, :backend_not_configured}
  def checkpoint(%ExecutionDomain.Domain{}), do: {:error, :backend_not_configured}
  def restore(%ExecutionDomain.CheckpointRef{}), do: {:error, :backend_not_configured}
  def destroy(%ExecutionDomain.Domain{}), do: {:error, :destruction_not_proven}
  def inspect_domain(%ExecutionDomain.Domain{}), do: {:error, :backend_not_configured}
end

spec = %ExecutionDomain.Spec{
  episode_id: Canonical.id(),
  epoch: 1,
  workspace: %{},
  hard_envelope: %{},
  resource_limits: %{},
  environment: %{},
  effect_socket: nil
}

:ok = ExecutionDomainCase.verify_skeleton!(ExampleMicroVMBackend, spec)

Support.assert_equal!(
  ExampleMicroVMBackend.create(spec),
  {:error, :backend_not_configured},
  "unconfigured backend must not pretend isolation"
)

IO.puts(
  "Backend author owns: stale-generation rejection, launch isolation, checkpoint generation fencing, cgroup/VM-wide destruction, and proof of emptiness before cleanup."
)

IO.puts(
  "ASSERTION PASSED: the skeleton fails closed until a real microVM/systemd-nspawn backend proves the required invariants"
)
