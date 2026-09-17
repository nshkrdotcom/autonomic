alias Autonomic.ExecutionDomain
alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{"id" => "demo"})
{spec, runtime} = Support.start_episode!(max_class: :class_2_external_observable_or_compensatable, kinds: ["http_read", "shell_bounded", "workspace_write"])

defmodule ExampleAgentModel do
  @callback next(map()) :: {:ok, map()} | {:error, term()}
end

defmodule ExampleAgentModel.Scripted do
  @behaviour ExampleAgentModel
  def next(%{step: 0}), do: {:ok, %{tool: :local_exec, argv: ["/bin/sh", "-c", "printf agent-local > agent.txt && cat agent.txt"]}}
  def next(%{step: 1}), do: {:ok, %{tool: :effect, kind: :http_read, target_id: "demo", payload: "brokered request"}}
  def next(_), do: {:ok, %{tool: :done}}
end

state = %{step: 0, transcript: []}
state = Enum.reduce_while(1..4, state, fn _, st ->
  {:ok, turn} = ExampleAgentModel.Scripted.next(st)
  case turn do
    %{tool: :local_exec, argv: argv} ->
      {:ok, execution} = runtime.domain.backend.exec(runtime.domain, %ExecutionDomain.Command{argv: argv})
      Support.assert_equal!(execution.exit_status, 0, "agent local tool")
      IO.inspect(execution.metadata.stdout, label: "local tool output")
      {:cont, %{st | step: st.step + 1, transcript: st.transcript ++ [turn]}}
    %{tool: :effect, kind: kind, target_id: target_id, payload: payload} ->
      effect = Support.prepare!(spec, runtime, kind, payload, target_id: target_id) |> Support.evaluate!() |> Support.commit!()
      IO.inspect(%{id: effect.id, state: effect.state, kind: effect.kind}, label: "brokered tool result")
      Support.assert_equal!(effect.state, :committed, "agent external action must cross broker")
      {:cont, %{st | step: st.step + 1, transcript: st.transcript ++ [turn]}}
    %{tool: :done} -> {:halt, st}
  end
end)

Support.assert_equal!(length(state.transcript), 2, "agent loop tool count")
Support.assert!(Enum.any?(state.transcript, &(&1.tool == :effect)), "loop must route an external action through EffectBroker")
IO.puts("ASSERTION PASSED: local computation stays in ExecutionDomain; external authority crosses EffectBroker")
