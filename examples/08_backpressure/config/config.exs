import Config

config :autonomic,
  store: Autonomic.Dev.MemoryStore,
  domain_backend: Autonomic.Dev.UnsafeLocalDomain,
  sensor: Autonomic.Dev.ScriptedSensor,
  state_dir: Path.expand("../.state", __DIR__),
  targets: %{},
  effect_concurrency: 8,
  sensor_queue: 64

config :autonomic,
  effect_concurrency: 1,
  sensor_queue: 2
