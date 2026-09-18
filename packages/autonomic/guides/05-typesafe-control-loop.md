# TypeSafe Control Loop

This guide documents what `autonomic` actually does with TypeSafe-derived semantic observations. The TypeSafe API client and question bank live in the separate `autonomic_typesafe` package; the **meaning** of those observations is owned here in core.

## Reference composition

A TypeSafe-centered Autonomic application installs the four publishable packages and configures the reference implementations:

```elixir
config :autonomic,
  store: Autonomic.Store.Postgres,
  domain_backend: Autonomic.Linux.Backend,
  sensor: Autonomic.Typesafe.Sensor
```

The package split keeps the kernel reusable. The reference runtime still routes semantic evaluation through TypeSafe.

## Observation contract

Core receives a list of `Autonomic.SemanticObservation` structs. The reference TypeSafe adapter produces five on every successful evaluation:

| Sensor | TypeSafe answer family | Core-facing value |
| --- | --- | --- |
| `scope_drift` | Noul | boolean plus confidence/probabilities |
| `authority_escalation` | Noul | boolean plus confidence/probabilities |
| `evidence_sufficiency` | Score | expected label plus score distribution and normalized score in metadata |
| `irreversibility` | Score | normalized value plus score distribution/ranking metadata |
| `trajectory_regime` | Choice | selected regime plus full choice probabilities/ranking/margin |

The observation also carries reproducibility provenance: actual/requested model, request ID, SDK version, bank version, Prepared fingerprint, usage, retry count, latency, and observation timestamp.

## Consumer 1: Homeostat

`Autonomic.Homeostat` turns semantic observations into a temporal state vector.

### Risk extraction

- scope drift becomes `scope_pressure` and contributes to drift;
- authority escalation becomes `authority_pressure`;
- irreversibility becomes `destructive_pressure`;
- evidence sufficiency becomes uncertainty;
- trajectory regime becomes a regime-risk contribution.

Confidence is not treated as certainty. `semantic_risk/1` pulls low-confidence observations toward a neutral risk of `0.5` rather than pretending a low-confidence false answer means zero risk.

### Temporal smoothing

The Homeostat uses EWMA state rather than making every TypeSafe response a direct command. It tracks:

```text
drift
volatility
uncertainty
scope_pressure
authority_pressure
destructive_pressure
verification_pressure
approval_pressure
blast_radius_remaining
autonomy_balance
```

This allows a sequence of weak-but-consistent signals to matter while avoiding instant oscillation from one response.

### Regime actions

Current thresholds are explicit core policy:

- risk `>= 0.82` -> `unstable`;
- drift or authority pressure `>= 0.58` -> `drifting`;
- uncertainty `>= 0.42` or unhealthy semantic service -> `uncertain`;
- otherwise -> `stable`.

The resulting controller signal is concrete:

```text
stable    -> continue
uncertain -> yield
 drifting -> narrow max effect class to Class 1
unstable  -> preempt episode
```

Deterministic hard violations bypass this smoothing and move directly to containment.

## Consumer 2: EffectBroker

For effects whose decision floor includes `semantic`, `EffectBroker` asks the semantic sensor to evaluate the exact effect context in slow mode.

The current broker policy consumes scope drift, authority escalation, and evidence sufficiency. A semantic decision is persisted as an exact-revision decision. TypeSafe outage or contract failure prevents required semantic authorization rather than producing an implicit safe result.

The same evaluation also returns irreversibility and trajectory-regime observations, but the broker's current allow/deny function does not use their full probability distributions. Those richer fields remain available in the observations and are consumed more broadly by the Homeostat path.

## SystemRegulator coupling

Semantic service health is itself a control signal. A TypeSafe transport failure, request timeout, response-contract violation, request-budget violation, runtime-capability failure, or overload marks semantic health degraded/unavailable. Sensitive commits can then be paused by `SystemRegulator` instead of silently bypassing the sensor requirement.

## What this design is and is not

It **is** a typed semantic feedback loop in which TypeSafe observations can change runtime authority and effect decisions.

It is **not** a claim that TypeSafe is the authority source, a formal safety proof, or a Bayesian fusion engine. The adapter preserves rich probability distributions, but current core policy mostly consumes normalized values and confidence. That separation keeps the present behavior inspectable and leaves room for future calibrated policies without pretending they already exist.

## Follow the implementation

Read these in order:

1. `autonomic_typesafe: Autonomic.Typesafe.SensorBank` — the five TypeSafe questions.
2. `autonomic_typesafe: Autonomic.Typesafe.Bank` — SDK execution and answer normalization.
3. `autonomic: Autonomic.SemanticObservation` — core observation contract.
4. `autonomic: Autonomic.Homeostat` — temporal semantic regulation.
5. `autonomic: Autonomic.EffectBroker` — semantic effect authorization.
6. `autonomic_postgres` — durable observation/trajectory/decision persistence.
