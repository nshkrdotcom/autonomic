# 14 · Custom SQLite store

| | |
| :--- | :--- |
| **Demonstrates** | A SQLite-backed store extension shape and reusable store conformance checks. |
| **Requires** | `sqlite3` executable. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Store contract and conformance expectations. |
| **Simulated** | Production HA/durability guarantees. |
| **Do not copy** | Do not claim SQLite has PostgreSQL cluster semantics. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
