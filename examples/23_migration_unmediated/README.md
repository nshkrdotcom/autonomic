# 23 · Migration from unmediated harness

| | |
| :--- | :--- |
| **Demonstrates** | A naive direct shell/effect harness is refactored into execution-domain and broker boundaries step by step. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Kernel routing and policy boundaries. |
| **Simulated** | External target. |
| **Do not copy** | Do not retain direct mutation paths beside the broker. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
