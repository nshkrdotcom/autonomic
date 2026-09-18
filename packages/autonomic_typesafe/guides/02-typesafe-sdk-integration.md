# TypeSafeSDK 0.4 Integration

The production adapter uses TypeSafeSDK 0.4.0 as the only semantic client layer.
It does not implement a parallel TypeSafe HTTP stack or retry engine.

## SDK-owned mechanics used directly

- `TypeSafeSDK.prepare!/1` and `TypeSafeSDK.Prepared.fingerprint/1`
- `TypeSafeSDK.evaluate/4` via `TypeSafeSDK.OTP.Server`
- `response_contract: [on_unknown_answer: :error, allowed_models: ...]`
- `max_request_bytes:` for exact serialized request sizing
- `TypeSafeSDK.Response` and `TypeSafeSDK.Answer.*` normalization helpers
- `TypeSafeSDK.Response.metadata/1` for bounded stable provenance
- `TypeSafeSDK.Error.metadata/1` for privacy-safe bank status diagnostics
- `TypeSafeSDK.RuntimeCapabilities` for fail-closed runtime requirements
- privacy-safe TypeSafe evaluation and per-answer telemetry
- `TypeSafeSDK.Test` at the real SDK transport seam for deterministic tests

## Bounded OTP execution

`Autonomic.Typesafe.Bank` is implemented with `TypeSafeSDK.OTP.Server` and uses
`Autonomic.Typesafe.Tasks`, a Task.Supervisor owned by the adapter application.
This prevents the bank GenServer from serializing all network latency while
keeping a finite `max_in_flight` bound. The TypeSafe wrapper creates private
Pristine cancellation scopes and performs the actual evaluations outside the
bank process.

Keeping semantic tasks off the core `Autonomic.Tasks` supervisor prevents semantic latency from consuming task slots used by effect and episode control work. This dedicated supervisor is a task-lifecycle boundary, not an HTTP pool or queue.

The kernel does not use `TypeSafeSDK.Batch` as a replacement for GenStage or
`SystemRegulator` backpressure. Batch APIs solve independent SDK fan-out; kernel
pressure and authority remain Autonomic concerns.

## Required runtime capabilities

The adapter always requires:

```elixir
[:unary_cancellation, :cancellation_cleanup]
```

TypeSafeSDK delegates that report to Pristine. The supplied Pristine 0.4.0 Finch
transport advertises both as supported. Any custom transport that does not prove
them fails bank startup instead of silently weakening the execution contract.

## Tests and live gate

Unit/component tests use `TypeSafeSDK.Test` only. The live gate is
`packages/autonomic_typesafe/test/live_gate_test.exs` and requires
`TYPESAFE_API_KEY`. It records request/model/usage/timing/fingerprint/capability
provenance without credentials, state text or raw bodies.
