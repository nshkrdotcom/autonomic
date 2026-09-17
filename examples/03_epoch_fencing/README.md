# 03 · Epoch fencing

| | |
| :--- | :--- |
| **Demonstrates** | A prepared effect becomes stale after an epoch advance; a new-epoch effect succeeds. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Epoch and lease fencing in the kernel. |
| **Simulated** | Persistence and external target. |
| **Do not copy** | Do not substitute MemoryStore for a durable authority store. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
