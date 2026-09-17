# 15 · Custom microVM domain

| | |
| :--- | :--- |
| **Demonstrates** | An ExecutionDomain backend skeleton that makes backend-owned fencing and destruction evidence explicit. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | ExecutionDomain contract/conformance checks. |
| **Simulated** | Actual Firecracker/systemd-nspawn launch. |
| **Do not copy** | The skeleton is not an isolation boundary. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.
