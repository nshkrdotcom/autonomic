# 17 · Full stack Linux

| | |
| :--- | :--- |
| **Demonstrates** | A runnable production-host checklist that verifies prerequisites before invoking the real provisioning/preflight path. |
| **Requires** | privileged Linux, PostgreSQL 16+, Rust/Elixir toolchains. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Production packages and verification sequence. |
| **Simulated** | nothing when all prerequisites are present |
| **Do not copy** | Do not downgrade failed isolation/preflight gates. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
