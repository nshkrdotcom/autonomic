# 01 · First episode

| | |
| :--- | :--- |
| **Demonstrates** | A complete local episode bootstrap, Class 1 workspace command, lease inspection, and clean completion. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Core episode/controller/lease lifecycle. |
| **Simulated** | OS isolation via `UnsafeLocalDomain`. |
| **Do not copy** | Never run untrusted commands through `UnsafeLocalDomain`. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
