alias Autonomic.Dev.Support
Support.reset!()
repo = Path.expand("../..", __DIR__)
required = ["scripts/provision_host.sh", "scripts/build_launcher.sh", "scripts/build_rootfs.py", "scripts/preflight.sh"]
Enum.each(required, fn rel -> Support.assert!(File.exists?(Path.join(repo, rel)), "missing production gate #{rel}") end)
linux? = match?({:unix, :linux}, :os.type())
opt_in? = System.get_env("AUTONOMIC_RUN_PRIVILEGED") == "1"
if linux? and opt_in? do
  {out, status} = System.cmd("bash", [Path.expand("run_full_stack.sh", __DIR__)], stderr_to_stdout: true)
  IO.write(out); Support.assert_equal!(status, 0, "privileged full-stack gate")
else
  IO.puts("QUALIFIED SKIP: production execution requires privileged Linux. Set AUTONOMIC_RUN_PRIVILEGED=1 on a disposable qualified host to execute run_full_stack.sh.")
  IO.puts("Verified that every referenced production provisioning/build/preflight script exists.")
end
IO.puts("ASSERTION PASSED: this example never substitutes UnsafeLocalDomain for the production Linux isolation gate")
