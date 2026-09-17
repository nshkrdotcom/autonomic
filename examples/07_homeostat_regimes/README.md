# 07 · Homeostat regimes

| | |
| :--- | :--- |
| **Demonstrates** | Trajectory risk moves through regimes and recovery uses hysteresis. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Homeostat EWMA/regime logic. |
| **Simulated** | Semantic observations. |
| **Do not copy** | Do not copy example thresholds as a universal calibration. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
