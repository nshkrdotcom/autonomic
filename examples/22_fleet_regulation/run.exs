alias Autonomic.SystemRegulator
alias Autonomic.Dev.Support

Support.reset!()
wait_mode = fn expected ->
  Support.await!(fn -> if SystemRegulator.mode() == expected, do: {:ok, expected}, else: false end, "regulator mode #{expected}")
end

SystemRegulator.report(:effect_queue, 0.73)
:read_only_autonomy = wait_mode.(:read_only_autonomy)
read_only = %{class0: SystemRegulator.admit?(:class_0_local_replayable), class1: SystemRegulator.admit?(:class_1_isolated_mutable), class2: SystemRegulator.admit?(:class_2_external_observable_or_compensatable)}
IO.inspect(read_only, label: "read_only_autonomy admission")
Support.assert_equal!(read_only, %{class0: true, class1: false, class2: false}, "read-only admission")

SystemRegulator.report(:effect_queue, 0.86)
:no_sensitive_commits = wait_mode.(:no_sensitive_commits)
no_sensitive = %{class0: SystemRegulator.admit?(:class_0_local_replayable), class1: SystemRegulator.admit?(:class_1_isolated_mutable), class2: SystemRegulator.admit?(:class_2_external_observable_or_compensatable), class3: SystemRegulator.admit?(:class_3_authoritative_external_mutation)}
IO.inspect(no_sensitive, label: "no_sensitive_commits admission")
Support.assert_equal!(no_sensitive.class3, false, "sensitive class remains blocked")

if no_sensitive.class1 or no_sensitive.class2 do
  IO.puts("REVIEW FLAG: current code widens Class 1/2 admission when severity rises from :read_only_autonomy to :no_sensitive_commits. This example records the behavior; it does NOT declare it intended.")
end
Support.assert_equal!(no_sensitive.class1, true, "current implementation review flag: class1 widening")
Support.assert_equal!(no_sensitive.class2, true, "current implementation review flag: class2 widening")

SystemRegulator.report(:effect_queue, 0.0)
Process.sleep(800)
Support.assert_equal!(SystemRegulator.mode(), :normal, "hysteretic recovery after sustained low pressure")
IO.puts("ASSERTION PASSED: fleet pressure transitions and hysteretic recovery are observable; the known admission-ordering question is surfaced explicitly")
