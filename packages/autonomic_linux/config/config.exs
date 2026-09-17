import Config

config :autonomic_linux,
  enabled: false,
  sudo: true,
  rootfs: "/opt/autonomic/rootfs",
  state_root: "/var/lib/autonomic"

config :logger, level: :info
import_config "#{config_env()}.exs"
