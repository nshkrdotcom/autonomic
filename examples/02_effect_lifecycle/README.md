# 02 · Effect lifecycle

| | |
| :--- | :--- |
| **Demonstrates** | A Class 2 effect walking through prepare, evaluate, commit, then rejecting a second commit. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | EffectBroker state machine and version vector checks. |
| **Simulated** | External target via `MemoryAdapter`. |
| **Do not copy** | Do not treat the memory target as durable or authoritative. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
