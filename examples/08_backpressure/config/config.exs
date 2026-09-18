import Config

config :autonomic,
  store: Autonomic.Dev.MemoryStore,
  domain_backend: Autonomic.Dev.UnsafeLocalDomain,
  sensor: Autonomic.Dev.ScriptedSensor,
  state_dir:
    Path.join(
      System.get_env("AUTONOMIC_EXAMPLE_STATE_ROOT", "/tmp/autonomic-examples"),
      Path.basename(Path.expand("..", __DIR__))
    ),
  targets: %{},
  effect_concurrency: 8,
  sensor_queue: 64

config :autonomic,
  effect_concurrency: 1,
  sensor_queue: 2
