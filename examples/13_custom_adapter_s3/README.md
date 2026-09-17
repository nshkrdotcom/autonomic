# 13 · Custom S3-compatible adapter

| | |
| :--- | :--- |
| **Demonstrates** | A complete object-storage EffectAdapter template with scope validation, conditional idempotency, reconciliation, and contract checks. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | EffectAdapter contract and broker integration. |
| **Simulated** | S3 transport via an in-memory object client. |
| **Do not copy** | Replace the example object client with a bounded authenticated client. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
