# 21 · Policy signing CLI

| | |
| :--- | :--- |
| **Demonstrates** | Generate Ed25519 keys, sign/verify policy documents, and produce an exact Class 4 approval. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Canonical signing primitives and approval document shape. |
| **Simulated** | Key storage/HSM. |
| **Do not copy** | Do not store production private keys in source or shell history. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
