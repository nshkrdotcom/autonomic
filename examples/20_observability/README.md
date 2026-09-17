# 20 · Observability

| | |
| :--- | :--- |
| **Demonstrates** | Telemetry events/spans/metrics vocabulary around effect transitions with a runnable local handler. |
| **Requires** | nothing. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | BEAM telemetry integration and core state transitions. |
| **Simulated** | Prometheus/Grafana export. |
| **Do not copy** | Do not log payloads or credentials as labels/metadata. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.

The current core declares `:telemetry` but does not yet emit a normative event vocabulary. This example deliberately emits **example-scoped** events around the public broker API instead of pretending core events already exist. A future core instrumentation change should preserve the no-payload/no-secret metadata discipline shown here.
