# TypeSafe/Jev Semantic Sensors

`autonomic_typesafe` is the reference semantic implementation for Autonomic and targets TypeSafeSDK 0.4.0. It uses TypeSafe as a typed semantic measurement layer feeding the core control loop—not as a free-form chatbot call and not as the authority source.

For the multi-package picture, start with [`TYPESAFE_CONTROL_LOOP.md`](TYPESAFE_CONTROL_LOOP.md).

## Production bank

`Autonomic.Typesafe.SensorBank` defines one prepared five-question contract:

| Sensor | TypeSafe family | Question/scale | Main core consumer |
| --- | --- | --- | --- |
| `scope_drift` | Noul | materially outside declared task/scope? | Homeostat + EffectBroker |
| `authority_escalation` | Noul | seeking unnecessary resources/authority? | Homeostat + EffectBroker |
| `evidence_sufficiency` | Score | insufficient / partial / sufficient | Homeostat + EffectBroker |
| `irreversibility` | Score | local -> high-impact | Homeostat |
| `trajectory_regime` | Choice | stable / uncertain / drifting / unstable | Homeostat |

The ordered bank is created with `TypeSafeSDK.noul/1`, `TypeSafeSDK.score/2`, and `TypeSafeSDK.choice/2`, then prepared once with `TypeSafeSDK.prepare!/1`.

The semantic contract is identified by `TypeSafeSDK.Prepared.fingerprint/1`. The human bank version (`coding-v1`) is separate provenance.

## Evidence window

`Autonomic.Typesafe.Evidence` constructs a new bounded state map from approved observable data:

- episode / epoch / sequence / timestamp;
- deterministic facts;
- resource summaries;
- proposed-effect context;
- explicitly visible worker state.

It recursively redacts secret-shaped keys and strings, bounds collection sizes/nesting/string length, and applies `evidence_limit` before the SDK boundary.

TypeSafeSDK then independently enforces `max_request_bytes` over the actual final serialized request.

## OTP execution

`Autonomic.Typesafe.Bank` is built on `TypeSafeSDK.OTP.Server` and uses the package-owned `Autonomic.Typesafe.Tasks` supervisor. Semantic HTTP latency therefore does not serialize the bank callback or occupy core episode/effect task slots.

`max_in_flight` bounds local concurrency. Saturation is an error/degradation state, not an unbounded queue.

The adapter always requires runtime capabilities for unary cancellation and cancellation cleanup. Additional configured capabilities are additive.

## Response contract

The adapter configures TypeSafeSDK with:

```elixir
response_contract: [
  on_unknown_answer: :error,
  allowed_models: allowed_models_or_nil
]
```

After SDK validation, Autonomic additionally verifies the Prepared fingerprint and rejects an unknown future answer family for any required bank key.

No missing/unknown answer becomes a false, zero, stable, or sufficient default.

## Normalized observations

Each result becomes an `Autonomic.SemanticObservation` carrying shared provenance:

- actual and requested model;
- request ID;
- TypeSafeSDK version;
- sensor-bank version;
- Prepared fingerprint;
- usage;
- retries;
- latency;
- observation timestamp.

Family-specific structure is preserved:

- Noul: boolean, confidence, true/false probabilities;
- Score: confidence, probability map, expected level/label, modal/ranked levels, normalized value;
- Choice: selected choice, confidence, full probabilities, ranked choices, margin.

## Core semantics

### Homeostat

The Homeostat transforms semantic observations into a temporal risk/control state, smooths them over time, and emits continue/yield/narrow/preempt actions. A semantic outage increases uncertainty and can prevent sensitive progress.

### EffectBroker

For a policy requiring semantic evidence, EffectBroker asks the configured semantic sensor to evaluate the exact proposed effect. Its current allow/deny policy uses scope drift, authority escalation, and evidence sufficiency against an explicit risk threshold. The semantic decision is persisted for the exact effect revision.

The richer probability distributions remain available in the observations even though current broker policy does not fuse all of them.

## Persistence

With `autonomic_postgres`, observation frames and trajectory state are durable, and semantic effect decisions are bound to effect revision/epoch/policy/trajectory/payload identity. This allows later audit of which TypeSafe contract/model/request contributed to an authority decision.

## Failure behavior

Transport errors, timeouts, request/response contract failures, model drift, fingerprint mismatch, unknown required answer families, runtime-capability failures, request-budget failures, and OTP overload all return errors and mark semantic health degraded/unavailable. No path fabricates a safe observation.

## Tests

Component tests use `TypeSafeSDK.Test` so they exercise the real SDK serialization/contract seam deterministically. The live gate requires an authorized endpoint:

```bash
cd packages/autonomic_typesafe
TYPESAFE_API_KEY=... mix test test/live_gate_test.exs --include live
```

The live artifact records non-secret structural provenance only.
