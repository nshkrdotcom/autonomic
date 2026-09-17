defmodule Autonomic.Typesafe.Sensor do
  @moduledoc "Autonomic.SemanticSensor adapter backed exclusively by the TypeSafeSDK 0.2 strict public API."
  @behaviour Autonomic.SemanticSensor

  @impl true
  def observe(frame, opts \\ []), do: Autonomic.Typesafe.Bank.observe(frame, opts)
end
