# Effect Adapter Authoring

Adapters implement `Autonomic.EffectAdapter` with `validate/2`, `commit/2`, and `reconcile/2`. The untrusted worker never invokes them directly.

## Required Properties

- Target configuration comes from trusted application configuration through `Autonomic.Runtime.target/1`; never accept a host path, base URL, or credential source solely from the worker.
- `validate/2` is side-effect free and checks the exact proposal shape/target scope.
- `commit/2` is called only after durable `commit_intent`. Prefer native idempotency or compare-and-swap. Return `{:unknown, reason}` whenever execution may have happened but cannot be proven.
- `reconcile/2` must distinguish `{:committed, receipt}`, `:not_committed`, and `{:unknown, reason}` without mutating blindly.
