# 08 · Backpressure and saturation

| | |
| :--- | :--- |
| **Demonstrates** | EffectBroker saturation rejects work and SensorArray preserves critical deterministic frames under pressure. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | EffectBroker and SensorArray backpressure. |
| **Simulated** | External work and semantic frames. |
| **Do not copy** | Do not replace bounded queues with unbounded buffering. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
