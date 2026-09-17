import Config

if System.get_env("AUTONOMIC_LINUX") == "1", do: config(:autonomic_linux, enabled: true)
if path = System.get_env("AUTONOMIC_LAUNCHER"), do: config(:autonomic_linux, executable: path)

if path = System.get_env("AUTONOMIC_ROOTFS"),
  do: config(:autonomic_linux, rootfs: Path.expand(path))

if path = System.get_env("AUTONOMIC_LINUX_STATE_ROOT"),
  do: config(:autonomic_linux, state_root: Path.expand(path))

if System.get_env("AUTONOMIC_NO_SUDO") == "1", do: config(:autonomic_linux, sudo: false)
