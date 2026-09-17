# 19 · Operator console

| | |
| :--- | :--- |
| **Demonstrates** | A terminal operator view exercises the read model: episode/epoch/regime/effects and containment. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Store/controller read paths and operator containment action. |
| **Simulated** | Terminal UI instead of Phoenix LiveView. |
| **Do not copy** | Do not expose signing keys or secrets in operator views. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.

This repository does not currently depend on Phoenix. The runnable artifact is therefore the **operator read/control model** rendered in the terminal, not a fake LiveView. The handoff identifies wrapping these exact read paths in Phoenix LiveView as an optional UI follow-up rather than introducing Phoenix into the core package graph merely for an example.
