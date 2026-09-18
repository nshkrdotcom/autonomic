alias Autonomic.{EpisodeController, ExecutionDomain}
alias Autonomic.Dev.Support

Support.reset!()

{spec, runtime} =
  Support.start_episode!(
    max_class: :class_1_isolated_mutable,
    kinds: ["workspace_write", "shell_bounded"]
  )

IO.puts("controller: #{inspect(EpisodeController.state(spec.id))}")

IO.puts(
  "lease: #{runtime.lease.id} epoch=#{runtime.lease.epoch} ttl_ms=#{runtime.lease.expires_at - runtime.lease.issued_at} max=#{runtime.lease.max_effect_class}"
)

IO.inspect(runtime.lease.capabilities, label: "capabilities")

command = %ExecutionDomain.Command{
  argv: ["/bin/sh", "-c", "printf 'hello from autonomic\\n' > greeting.txt && cat greeting.txt"]
}

{:ok, execution} = runtime.domain.backend.exec(runtime.domain, command)
IO.write(execution.metadata.stdout)

Support.assert_equal!(execution.exit_status, 0, "local command exit status")

Support.assert!(
  String.contains?(execution.metadata.stdout, "hello from autonomic"),
  "workspace command must produce expected output"
)

Support.complete_episode!(spec.id)

Support.assert!(
  match?({:completed, _}, EpisodeController.state(spec.id)),
  "episode must complete"
)

IO.puts("ASSERTION PASSED: episode ran and completed under an epoch-fenced lease")
