# TypeSafe/Jev semantic sensors

`autonomic_typesafe` integrates only through the public TypeSafeSDK 0.2.x strict semantic API. It does not call Pristine internals or implement a second HTTP client.

## Prepared bank

`Autonomic.Typesafe.SensorBank` declares and prepares once:

- `scope_drift` — Noul
- `authority_escalation` — Noul
- `evidence_sufficiency` — Score
- `irreversibility` — Score
- `trajectory_regime` — Choice (`stable | uncertain | drifting | unstable`)

The application semantic-contract ID is `sha256` of the canonical declarative manifest, not opaque `Prepared` internals. The prepared bank is reused for `TypeSafeSDK.evaluate/4` calls.

## Evidence and transport

Only observable state is sent: deterministic facts, resource summaries, effect context and explicitly emitted/visible worker state. Secret-shaped keys/text are redacted and state is byte-bounded before the SDK boundary. A second whole-request budget includes the manifest.

The adapter uses `TypeSafeSDK.Response` and `TypeSafeSDK.Answer.*` helpers to normalize Noul/Choice/Score output. It persists SDK version, requested/actual model, request ID, usage, retries, latency, bank version and semantic-contract ID. Required unknown future answer tags are unavailable/degraded, not safe. Configured concrete-model drift also degrades/fails policy evaluation.

`TypeSafeSDK.RuntimeCapabilities.check/2` is called for deployment-required transport guarantees. Capability advertisement is not treated as independent proof; the underlying transport must still be tested.

## Testing

`TypeSafeSDK.Test` component tests exercise the real SDK serialization/validation seam deterministically. They do not count as the mandatory live gate. The live gate is `apps/autonomic_typesafe/test/live_gate_test.exs` and records non-secret provenance to `artifacts/typesafe_live_gate.json`.
