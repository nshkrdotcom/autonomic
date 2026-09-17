# 24 · Benchmark and overhead profile

| | |
| :--- | :--- |
| **Demonstrates** | A local measurement harness separates kernel bookkeeping from simulated semantic latency and labels results non-production. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Local episode/effect timing harness. |
| **Simulated** | Production Linux/Postgres/model latency. |
| **Do not copy** | Do not publish local-dev numbers as production benchmarks. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
