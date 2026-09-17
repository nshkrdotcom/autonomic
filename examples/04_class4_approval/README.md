# 04 · Class 4 approval horizon

| | |
| :--- | :--- |
| **Demonstrates** | Class 4 approvals fail when missing, payload-mismatched, or signed by an untrusted key and succeed only when exactly bound. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Ed25519 approval verification, payload/revision binding, EffectBroker decisions. |
| **Simulated** | Semantic evidence and external publish target. |
| **Do not copy** | Do not embed example private keys in real deployments. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
