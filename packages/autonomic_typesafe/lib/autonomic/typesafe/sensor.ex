defmodule Autonomic.Typesafe.Sensor do
  @moduledoc "Autonomic.SemanticSensor adapter backed exclusively by the TypeSafeSDK 0.4 public semantic API."
  @behaviour Autonomic.SemanticSensor

  @doc """
  Evaluates a control frame through the supervised TypeSafe semantic sensor bank.

  Returns semantic observations or a typed error.
  """
  @impl true
  def observe(frame, opts \\ []), do: Autonomic.Typesafe.Bank.observe(frame, opts)
end
