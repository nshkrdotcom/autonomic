import Config

config :autonomic_postgres,
  ecto_repos: [Autonomic.Store.Repo]

config :autonomic_postgres, Autonomic.Store.Repo,
  url: "ecto://autonomic:autonomic@127.0.0.1/autonomic_dev",
  pool_size: 12,
  queue_target: 1000,
  queue_interval: 1000,
  migration_primary_key: [name: :id, type: :string]

config :logger, level: :info
import_config "#{config_env()}.exs"
