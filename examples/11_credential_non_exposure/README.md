# 11 · Credential non-exposure

| | |
| :--- | :--- |
| **Demonstrates** | Worker-visible proposals and persisted example artifacts never contain the broker-owned credential. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Trusted target separation and public target redaction. |
| **Simulated** | HTTP credential use; no network request is made. |
| **Do not copy** | Do not pass credentials in proposal payloads or targets. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
