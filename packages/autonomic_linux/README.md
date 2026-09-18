<p align="center">
  <img src="assets/autonomic_linux.svg" alt="Autonomic Linux Logo" width="200" height="200">
</p>

# autonomic_linux

<p align="center">
  <a href="https://github.com/nshkrdotcom/autonomic"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fautonomic-24292e?logo=github" alt="GitHub"/></a>
  <a href="https://hex.pm/packages/autonomic_linux"><img src="https://img.shields.io/hexpm/v/autonomic_linux.svg" alt="Hex.pm"/></a>
  <a href="https://hexdocs.pm/autonomic_linux"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
</p>

Linux isolation and execution-domain backend for the Autonomic Kernel.

---

## What is this package?

`autonomic_linux` implements the `Autonomic.ExecutionDomain` behaviour for Linux. It manages disposable execution domains using user/mount/PID/network namespaces, cgroup v2 resource limits, overlayfs filesystems, and seccomp filters via an external native launcher daemon.

## When should I install it?

Install `autonomic_linux` when deploying the Autonomic Kernel on Linux hosts to run untrusted coding workers inside bounded, disposable sandboxes.

## What does it depend on?

- `autonomic` (~> 0.1.0)
- Host Linux environment with cgroup v2, overlayfs, user namespaces, and seccomp.
- Rust / Cargo (for compiling the included `native/autonomic_launcher` executable from source).

## Installation

Add `autonomic_linux` to your `mix.exs`:

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_linux, "~> 0.1.0"}
  ]
end
```

## How do I configure it?

In your `config/config.exs` or `config/runtime.exs`:

```elixir
config :autonomic,
  domain_backend: Autonomic.Linux.Backend

config :autonomic_linux,
  enabled: true,
  executable: "/usr/local/libexec/autonomic_launcher",
  rootfs: "/opt/autonomic/rootfs",
  state_root: "/var/lib/autonomic",
  sudo: true
```

## Security Boundary & Isolation

`autonomic_linux` implements host-level containment for untrusted workers using:
- **Namespaces**: User, mount, PID, network, IPC, and UTS isolation.
- **cgroup v2**: Strict resource controls (CPU quota, memory limits, process limits).
- **OverlayFS & Read-only rootfs**: Ephemeral copy-on-write workspace layers that discard worker filesystem mutations upon domain teardown.
- **Seccomp Filters**: System call filtering that denies privilege escalation, traps raw network socket creation, and converts violations into deterministic evidence.
- **External Native Launcher**: A standalone Rust helper communicating over length-prefixed JSON IPC without executing worker-controlled shell commands.

For details on configuration and host prerequisites, see [Linux Isolation](guides/01-linux-isolation.md) and [Host Provisioning](guides/03-host-provisioning.md).

## What public modules and concepts does it own?

- `Autonomic.Linux.Backend` — Implements `Autonomic.ExecutionDomain` lifecycle callbacks.
- `Autonomic.Linux.Launcher` — Manages the Port communication to the external native daemon.
- `Autonomic.Linux.Preflight` — Verifies host kernel prerequisites (cgroups, namespaces, seccomp).
- `Autonomic.Linux.Application` — OTP application supervisor.

## How does it fit into Autonomic?

`autonomic_linux` provides the reference execution containment backend:

```text
       autonomic_linux                      other backends
              │                                     │
              └──────────────────┬──────────────────┘
                                 ▼
                      ┌─────────────────────┐
                      │      autonomic      │
                      └─────────────────────┘
```

This package implements `Autonomic.ExecutionDomain` and is configured via `:domain_backend` in your application configuration.

## Where are the full system docs?

See the repository root at [GitHub](https://github.com/nshkrdotcom/autonomic) and [HexDocs](https://hexdocs.pm/autonomic_linux).
