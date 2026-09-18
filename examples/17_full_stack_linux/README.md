# 17 · Full stack Linux

| | |
| :--- | :--- |
| **Demonstrates** | A runnable production-host checklist that verifies prerequisites before invoking the real provisioning/preflight path. |
| **Requires** | privileged Linux, PostgreSQL 16+, Rust/Elixir toolchains. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Production host provisioning, launcher/rootfs build, and preflight sequence. |
| **Simulated** | nothing when all prerequisites are present |
| **Do not copy** | Do not downgrade failed isolation/preflight gates. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.

This example's small Mix wrapper uses the repository's core/example harness because its purpose is to drive host provisioning and preflight. It is **not** the canonical consumer `mix.exs` for the production stack. A real application using the official production stack declares all four Hex packages:

```elixir
[
  {:autonomic, "~> 0.1.0"},
  {:autonomic_linux, "~> 0.1.0"},
  {:autonomic_postgres, "~> 0.1.0"},
  {:autonomic_typesafe, "~> 0.1.0"}
]
```

The repository's direct all-four-package composition is `integration/autonomic_acceptance`. See [`../../docs/PACKAGE_COMPOSITION.md`](../../docs/PACKAGE_COMPOSITION.md).
