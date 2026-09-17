# 22 · Fleet regulation

| | |
| :--- | :--- |
| **Demonstrates** | SystemRegulator admission under aggregate pressure, including an explicit assertion for the currently flagged mode-ordering behavior. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | SystemRegulator pressure/hysteresis/admission logic. |
| **Simulated** | Multi-node fleet pressure. |
| **Do not copy** | Do not encode the flagged widening as intended policy without review. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.

**Design review flag:** the supplied implementation admits only Class 0 in `:read_only_autonomy`, then admits Classes 0–2 in the nominally more severe `:no_sensitive_commits` mode. `run.exs` makes that widening visible and labels it unresolved; it does not treat the ordering as a safety invariant.
