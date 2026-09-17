import Config
config :logger, level: :warning
config :autonomic_kernel, automatic_verification: false
config :autonomic_store, Autonomic.Store.Repo,
  url: System.get_env("AUTONOMIC_TEST_DATABASE_URL") || "ecto://autonomic:autonomic@127.0.0.1/autonomic_test",
  pool_size: 24
