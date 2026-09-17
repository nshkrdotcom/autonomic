import Config

config :autonomic_typesafe,
  timeout_ms: 3000,
  required_capabilities: [],
  allowed_models: [],
  model: "jev-latest",
  evidence_limit: 32_768,
  request_limit: 65_536

config :logger, level: :info
import_config "#{config_env()}.exs"
