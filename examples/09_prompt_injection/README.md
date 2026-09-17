# 09 · Prompt injection cannot escalate

| | |
| :--- | :--- |
| **Demonstrates** | Malicious repository instructions plus approving semantic evidence cannot escape deterministic target policy. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Policy/capability denial before effect execution. |
| **Simulated** | Repository content and semantic evidence. |
| **Do not copy** | Do not place secrets in the worker workspace. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
