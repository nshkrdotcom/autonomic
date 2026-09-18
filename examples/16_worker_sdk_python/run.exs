alias Autonomic.Dev.Support
Support.reset!()
python = System.find_executable("python3")
Support.assert!(is_binary(python), "Python 3 is required")

{out, status} =
  System.cmd(python, [Path.expand("worker_sdk.py", __DIR__), "--self-test"],
    stderr_to_stdout: true
  )

IO.write(out)
Support.assert_equal!(status, 0, "Python SDK self-test")
source = File.read!(Path.expand("worker_sdk.py", __DIR__))

for required <- [
      "struct.pack(\">I\"",
      '"protocol": PROTOCOL',
      '"fetch_response"',
      "hashlib.sha256"
    ] do
  Support.assert!(
    String.contains?(source, to_string(required)),
    "SDK source must include #{inspect(required)}"
  )
end

IO.puts(
  "ASSERTION PASSED: worker SDK implements protocol 1 framing, six broker actions, chunk reassembly, and digest verification"
)
