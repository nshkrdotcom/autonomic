# 12 · Replay and idempotency

| | |
| :--- | :--- |
| **Demonstrates** | Logical replay is idempotent and moved-target evidence prevents accidental overwrite. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Effect identity/commit reconciliation shape. |
| **Simulated** | External target. |
| **Do not copy** | Do not infer exactly-once delivery from idempotency. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
