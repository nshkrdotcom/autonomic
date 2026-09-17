# Effect adapter authoring

Adapters implement `Autonomic.EffectAdapter` with `validate/2`, `commit/2`, and `reconcile/2`. The worker never invokes them directly.

## Required properties

- Target configuration comes from trusted `Application` configuration through `Runtime.target/1`; never accept a host path, base URL or credential source solely from the worker.
- `validate/2` is side-effect free and checks the exact proposal shape/target scope.
- `commit/2` is called only after durable `commit_intent`. Prefer native idempotency or compare-and-swap. Return `{:unknown, reason}` whenever execution may have happened but cannot be proven.
- `reconcile/2` must distinguish `{:committed, receipt}`, `:not_committed`, and `{:unknown, reason}` without mutating blindly.
- Receipts must exclude credentials/sensitive raw bodies and be bounded.

## Classes

Class 2 reads/actions remain brokered. Class 3 requires semantic + slow verification by default. Class 4 additionally requires high-precedence signed human approval. Never make a new adapter reduce the required decision floor.

Existing reference adapters are local Git CAS, remote Git force-with-lease, brokered HTTP, and create-only/content-idempotent artifact publication.
