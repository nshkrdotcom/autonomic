# TypeSafe/Jev semantic sensors

`autonomic_typesafe` is a greenfield TypeSafeSDK 0.4.0 integration. The package
uses the SDK's public semantic/OTP facilities and does not carry a 0.2/0.3
compatibility path, local HTTP client, retry engine or legacy contract shim.

## Prepared bank and contract identity

`Autonomic.Typesafe.SensorBank` defines five required semantic questions:

- `scope_drift` — Noul
- `authority_escalation` — Noul
- `evidence_sufficiency` — Score
- `irreversibility` — Score
- `trajectory_regime` — Choice (`stable | uncertain | drifting | unstable`)

The bank is prepared once for each `Autonomic.Typesafe.Bank` process. The
semantic-contract ID is the native versioned
`TypeSafeSDK.Prepared.fingerprint/1`; Autonomic no longer hashes a duplicate local
manifest to emulate an SDK feature. The human bank version remains separate
provenance.

## Bounded execution

The bank uses `TypeSafeSDK.OTP.Server` with the package-owned `Autonomic.Typesafe.Tasks`
`Task.Supervisor`. Semantic network latency therefore does not block the bank
GenServer or consume task slots used by core effect/episode control work. `max_in_flight` bounds concurrent evaluations; overload returns a
typed TypeSafe runtime-capability error and semantic health degrades.

The adapter always requires `:unary_cancellation` and `:cancellation_cleanup`; configured `required_capabilities` are additive and cannot remove that base contract.
TypeSafe delegates discovery to Pristine; the supplied Pristine 0.4.0 Finch
transport reports both supported. Custom transports fail closed when the required
contract is unsupported or unverified.

## Evidence and request budgets

Only observable state is sent: deterministic facts, resource summaries, effect
context and explicitly emitted/visible worker state. Secret-shaped keys/text are
redacted and the state is byte-bounded by `Autonomic.Typesafe.Evidence` before the
SDK boundary.

The final full request is independently bounded by TypeSafeSDK's
`max_request_bytes:` support. This measures the actual serialized request value
before transport egress, replacing the old state-bytes-plus-manifest estimate.

## Response contracts and provenance

The adapter configures TypeSafeSDK strict response contracts:

- unexpected answer IDs are errors;
- a configured non-empty `allowed_models` list is exact-membership policy; and
- a future answer type under a required requested key remains fail-closed at the
  Autonomic bank because the production sensor set requires known Noul/Choice/Score
  answer families.

Normalization uses `TypeSafeSDK.Response`, `TypeSafeSDK.Answer.*` and stable
`Response.metadata/1`. Bank status stores SDK failures through privacy-safe
`TypeSafeSDK.Error.metadata/1` rather than exposing raw error bodies. Semantic observations persist SDK version, requested and
actual model, request ID, usage, retries, timing, bank version and Prepared
fingerprint. TypeSafe 0.4 also emits privacy-safe per-answer telemetry after
validation; Autonomic does not duplicate that telemetry layer.

## Testing

`TypeSafeSDK.Test` component tests exercise real SDK serialization, request budget,
response contract, runtime capability and transport seams deterministically. They
also prove that a blocked semantic request does not block bank status handling and
that `max_in_flight` rejects additional work.

The mandatory live gate is
`packages/autonomic_typesafe/test/live_gate_test.exs`; it records non-secret
provenance to `artifacts/typesafe_live_gate.json`.
