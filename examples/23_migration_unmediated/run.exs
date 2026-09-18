alias Autonomic.ExecutionDomain
alias Autonomic.Dev.{Support, TargetStore}

Support.reset!()

# Step 0: representative unmediated harness. Kept local to this demo only.
naive_workspace = Path.join(System.tmp_dir!(), "autonomic-naive-migration")
File.rm_rf!(naive_workspace)
File.mkdir_p!(naive_workspace)
File.write!(Path.join(naive_workspace, "result.txt"), "direct shell write")
:ok = TargetStore.put({"external", "release"}, "DIRECT-MUTATION")

Support.assert_equal!(
  TargetStore.get({"external", "release"}),
  "DIRECT-MUTATION",
  "naive direct external mutation occurred without policy"
)

IO.puts("STEP 0 naive: shell and external mutation APIs are directly reachable")

# Step 1/2: local computation moves into an execution domain and external authority behind EffectBroker.
TargetStore.reset()

Support.install_adapter!("http_read", :class_2_external_observable_or_compensatable, %{
  "id" => "demo",
  "object_key" => "release"
})

{spec, runtime} =
  Support.start_episode!(
    max_class: :class_2_external_observable_or_compensatable,
    kinds: ["http_read", "shell_bounded", "workspace_write"]
  )

{:ok, execution} =
  runtime.domain.backend.exec(runtime.domain, %ExecutionDomain.Command{
    argv: ["/bin/sh", "-c", "printf mediated > mediated.txt && cat mediated.txt"]
  })

Support.assert_equal!(execution.exit_status, 0, "mediated local execution")
prepared = Support.prepare!(spec, runtime, :http_read, "brokered external mutation")
Support.assert_equal!(prepared.state, :prepared, "external action is first a proposal")
Support.assert_equal!(TargetStore.get({"demo", "release"}), nil, "prepare must not mutate target")
committed = prepared |> Support.evaluate!() |> Support.commit!()

Support.assert_equal!(
  committed.state,
  :committed,
  "brokered mutation commits after policy/evaluation"
)

Support.assert_equal!(
  TargetStore.get({"demo", "release"}),
  committed.payload_digest,
  "target receives only committed digest"
)

IO.puts("STEP 1 local shell -> ExecutionDomain")
IO.puts("STEP 2 direct external client -> EffectBroker proposal/evaluate/commit")

IO.puts(
  "ASSERTION PASSED: migration removes the direct authoritative mutation path instead of leaving a bypass beside the broker"
)
