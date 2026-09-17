import Config

if url = System.get_env("DATABASE_URL"),
  do: config(:autonomic_store, Autonomic.Store.Repo, url: url)

if root = System.get_env("AUTONOMIC_STATE_DIR"),
  do: config(:autonomic_kernel, state_dir: Path.expand(root))

if System.get_env("AUTONOMIC_LINUX") == "1", do: config(:autonomic_linux, enabled: true)
if path = System.get_env("AUTONOMIC_LAUNCHER"), do: config(:autonomic_linux, executable: path)

if path = System.get_env("AUTONOMIC_ROOTFS"),
  do: config(:autonomic_linux, rootfs: Path.expand(path))

if path = System.get_env("AUTONOMIC_LINUX_STATE_ROOT"),
  do: config(:autonomic_linux, state_root: Path.expand(path))

if System.get_env("AUTONOMIC_NO_SUDO") == "1", do: config(:autonomic_linux, sudo: false)
if key = System.get_env("TYPESAFE_API_KEY"), do: config(:autonomic_typesafe, api_key: key)
if model = System.get_env("TYPESAFE_MODEL"), do: config(:autonomic_typesafe, model: model)
# Trusted operator file; never accept configuration, signing keys or target paths from a worker.
if file = System.get_env("AUTONOMIC_CONFIG") do
  document = file |> File.read!() |> Jason.decode!()

  config :autonomic_kernel,
    targets: Map.fetch!(document, "targets"),
    policy_keys: Map.fetch!(document, "policy_keys"),
    decision_keys: Map.fetch!(document, "decision_keys"),
    signer: Map.fetch!(document, "signer"),
    domain_spec: Map.fetch!(document, "domain_spec")

  config :autonomic_typesafe,
    allowed_models: Map.get(document, "allowed_models", []),
    required_capabilities:
      Enum.map(Map.get(document, "required_capabilities", []), fn
        "bounded_queue" -> :bounded_queue
        "max_response_bytes" -> :max_response_bytes
        "bounded_outstanding_requests" -> :bounded_outstanding_requests
        "deterministic_overload" -> :deterministic_overload
        "cancellation_cleanup" -> :cancellation_cleanup
        _ -> raise "Unrecognized required transport capability"
      end)
end
