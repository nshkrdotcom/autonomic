import Config

config :autonomic_typesafe,
  autostart: true,
  timeout_ms: 3000,
  slow_timeout_ms: 10_000,
  max_in_flight: 8,
  required_capabilities: [],
  allowed_models: [],
  model: "jev-latest",
  evidence_limit: 32_768,
  request_limit: 65_536

config :logger, level: :info
import_config "#{config_env()}.exs"
