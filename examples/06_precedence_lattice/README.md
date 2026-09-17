# 06 · Precedence lattice

| | |
| :--- | :--- |
| **Demonstrates** | Deny-dominant signal precedence and semantic contraction without authority expansion. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | `Autonomic.Policy.precedence/1` and authority narrowing rules. |
| **Simulated** | Semantic evidence. |
| **Do not copy** | Do not combine authority signals as a weighted average. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
