# The disposable verification domain never shares a build directory with another
# Mix OS process. Disable only Mix's cross-process TCP build notification listener.
# Compilation and ExUnit execution remain the upstream Mix implementations.
defmodule Mix.PubSub.Subscriber do
  def start_link(_opts), do: :ignore
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def flush, do: :ok
end
