# Host Provisioning Prerequisites

Running isolated Linux worker domains requires specific host kernel features.

## Prerequisites

- Ubuntu 24.04+ or compatible Linux kernel (6.8+ recommended).
- Unified cgroup v2 mounted at `/sys/fs/cgroup` with `cpu`, `memory`, and `pids` controllers enabled.
- User, mount, PID, network, IPC, and UTS namespaces enabled.
- OverlayFS module loaded (`modprobe overlay`).
- Seccomp filter support enabled in kernel.
- Rust and Cargo (for compiling `native/autonomic_launcher` from source).
