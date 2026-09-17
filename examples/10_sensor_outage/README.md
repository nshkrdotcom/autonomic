# 10 · Semantic outage

| | |
| :--- | :--- |
| **Demonstrates** | Semantic unavailability and malformed/out-of-contract evidence degrade health and block sensitive effects rather than fail open. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | EffectBroker semantic gate and SystemRegulator health circuit breaker. |
| **Simulated** | Semantic provider. |
| **Do not copy** | Do not bypass semantic requirements to restore throughput. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
