defmodule Autonomic.Dev.ExecutionDomainCase do
  @moduledoc "Runnable ownership checks for example `Autonomic.ExecutionDomain` backends."

  alias Autonomic.{ExecutionDomain}
  alias Autonomic.Dev.Support

  def verify_skeleton!(backend, spec) do
    result = backend.create(spec)
    Support.assert!(match?({:error, :backend_not_configured}, result) or match?({:ok, %ExecutionDomain.Domain{}}, result), "backend must fail explicitly or return a typed Domain")
    :ok
  end
end
