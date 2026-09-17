# 16 · Worker SDK: Python

| | |
| :--- | :--- |
| **Demonstrates** | A worker-side client implements the AF_UNIX broker framing/protocol, including chunked response verification. |
| **Requires** | Python 3; live socket optional. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Effect socket wire format and digest checks. |
| **Simulated** | A live episode socket unless configured. |
| **Do not copy** | Do not add direct Internet access to workers as a shortcut. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
