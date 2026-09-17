import Config

config :autonomic_kernel,
  store: Autonomic.Store.Postgres,
  domain_backend: Autonomic.Linux.Backend,
  sensor: Autonomic.Typesafe.Sensor,
  state_dir: Path.expand("../var", __DIR__),
  effect_adapters: %{
    "git_commit" => {Autonomic.Adapters.Git, :class_3_authoritative_external_mutation},
    "git_remote" => {Autonomic.Adapters.GitRemote, :class_3_authoritative_external_mutation},
    "http_read" => {Autonomic.Adapters.HTTP, :class_2_external_observable_or_compensatable},
    "http_mutation" => {Autonomic.Adapters.HTTP, :class_3_authoritative_external_mutation},
    "publish" => {Autonomic.Adapters.Artifact, :class_4_irreversible_high_impact}
  },
  targets: %{},
  policy_keys: %{},
  decision_keys: %{},
  effect_concurrency: 8,
  sensor_queue: 64,
  speculation_ms: 15_000,
  max_repairs: 3,
  owner_ttl_ms: 15_000,
  automatic_verification: true

config :autonomic_store, ecto_repos: [Autonomic.Store.Repo]

config :autonomic_store, Autonomic.Store.Repo,
  url: "ecto://autonomic:autonomic@127.0.0.1/autonomic_dev",
  pool_size: 12,
  queue_target: 1000,
  queue_interval: 1000,
  migration_primary_key: [name: :id, type: :string]

config :autonomic_linux,
  enabled: false,
  executable: "/usr/local/libexec/autonomic_launcher",
  sudo: true,
  rootfs: "/opt/autonomic/rootfs",
  state_root: "/var/lib/autonomic"

config :autonomic_typesafe,
  timeout_ms: 3000,
  required_capabilities: [],
  allowed_models: [],
  model: "jev-latest",
  evidence_limit: 32_768,
  request_limit: 65_536

config :logger, level: :info
import_config "#{config_env()}.exs"
