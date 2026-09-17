# 05 · commit_unknown reconciliation

| | |
| :--- | :--- |
| **Demonstrates** | An ambiguous post-mutation result is never blindly retried and is resolved only from authoritative evidence. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | EffectBroker commit_unknown and reconciliation semantics. |
| **Simulated** | External target. |
| **Do not copy** | Do not automatically retry commit_unknown effects. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
