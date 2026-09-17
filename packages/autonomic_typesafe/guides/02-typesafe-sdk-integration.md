# TypeSafeSDK Strict Integration

`autonomic_typesafe` communicates strictly with `TypeSafeSDK`:

- Never imports Pristine or internal testing mocks in production.
- Uses `TypeSafeSDK.Test` only during test suites for deterministic simulation.
- Supports the mandatory live gate using real `TYPESAFE_API_KEY` credentials via `packages/autonomic_typesafe/test/live_gate_test.exs`.
