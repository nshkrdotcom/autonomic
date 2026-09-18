# TypeSafe-Centered Semantic Control Loop

Autonomic's reference semantic path is built around `autonomic_typesafe` and TypeSafeSDK 0.4. The core package remains adapter-neutral for publication and testing, but the full reference composition configures `Autonomic.Typesafe.Sensor` as the semantic implementation.

This document is the cross-package map. Each package also publishes a package-local HexDocs guide with the details it owns.

## Package responsibilities

| Package | TypeSafe-related responsibility |
| --- | --- |
| `autonomic` | owns `SemanticObservation`, Homeostat temporal regulation, EffectBroker semantic decision policy, and SystemRegulator consequences |
| `autonomic_typesafe` | owns evidence redaction/bounding, prepared TypeSafe question bank, SDK execution, strict response contracts, normalization, provenance, and semantic health reporting |
| `autonomic_postgres` | persists observation frames, trajectory state, exact-revision effect decisions, and recovery/audit lineage |
| `autonomic_linux` | produces real execution/boundary evidence from the contained worker; TypeSafe remains in the trusted control plane |

## End-to-end flow

```text
untrusted worker / proposed effect
            |
            | observable output, resource facts,
            | deterministic violations, effect context
            v
    Autonomic.ObservationFrame
            |
            v
 Autonomic.Typesafe.Evidence
   redact + bound observable state
            |
            v
      TypeSafeSDK 0.4
   prepared five-question bank
            |
            v
 Autonomic.SemanticObservation[]
            |
            +-------------------------+
            |                         |
            v                         v
      Autonomic.Homeostat       Autonomic.EffectBroker
       temporal control          exact-effect semantic gate
            |                         |
            v                         v
 continue / narrow /           semantic allow / deny
 yield / preempt               bound to exact revision
            |                         |
            +------------+------------+
                         v
                 durable PostgreSQL
            observations / trajectory /
                decisions / audit
```

## The five TypeSafe questions

The production bank is defined in `packages/autonomic_typesafe/lib/autonomic/typesafe/sensor_bank.ex`:

1. `scope_drift` — Noul: has the worker materially moved outside the declared task?
2. `authority_escalation` — Noul: is it seeking unnecessary resources/authority?
3. `evidence_sufficiency` — Score: insufficient / partial / sufficient.
4. `irreversibility` — Score: local / reversible / external / authoritative / high-impact.
5. `trajectory_regime` — Choice: stable / uncertain / drifting / unstable.

The bank is prepared once with `TypeSafeSDK.prepare!/1`; `TypeSafeSDK.Prepared.fingerprint/1` is the machine semantic-contract identity.

## Rich answer preservation

The adapter does not discard TypeSafe's answer structure at the SDK boundary.

### Noul

The normalized observation retains a boolean decision, confidence, and both sides of the Noul distribution.

### Score

Score answers retain probability maps plus expected, modal, ranked, and normalized interpretations. `evidence_sufficiency` exposes the expected label as its value; `irreversibility` exposes a normalized numeric value.

### Choice

`trajectory_regime` retains the selected choice, confidence, complete choice-probability map, ranking, and margin.

All five carry model/request/SDK/bank/fingerprint/usage/retry/latency provenance.

## What the core actually does with it

### Homeostat

Homeostat converts the five observations into smoothed control state:

- scope drift -> drift + scope pressure;
- authority escalation -> authority pressure;
- irreversibility -> destructive pressure;
- evidence sufficiency -> uncertainty;
- trajectory regime -> regime risk.

It uses EWMA and hysteresis, then emits concrete controller actions: continue, yield, narrow authority, or preempt. Deterministic hard violations bypass semantic smoothing and contain immediately.

### EffectBroker

When the decision floor requires `semantic`, EffectBroker sends the exact effect context to the semantic sensor in slow mode. The current broker decision uses scope drift, authority escalation, and evidence sufficiency. The result is persisted as an exact-revision decision alongside other required decision classes.

This is intentionally simpler than the rich TypeSafe response object. The adapter preserves more information than current broker policy consumes.

## SDK mechanics used directly

The integration uses:

- Noul / Score / Choice question constructors;
- prepared banks and native fingerprints;
- `TypeSafeSDK.OTP.Server`;
- exact final `max_request_bytes` enforcement;
- strict response contracts and concrete-model allow sets;
- response/answer normalization helpers;
- runtime capability checks;
- Pristine-backed unary cancellation and cleanup requirements;
- privacy-safe response/error metadata;
- TypeSafe per-answer telemetry;
- `TypeSafeSDK.Test` at the real SDK seam;
- a separate live endpoint gate.

It deliberately does not implement a second HTTP client, retry engine, or cancellation layer.

## Failure semantics

Missing configuration, transport failure, timeout, model drift, request-budget failure, response-contract failure, Prepared-fingerprint mismatch, unknown required answer family, runtime-capability failure, and OTP overload all become semantic degradation/unavailability. They never become synthetic safe observations.

## Security boundary

TypeSafe is an evidence producer, not a root of trust. Deterministic policy/authority always dominates semantic output.

The current `autonomic_linux` backend is same-host shared-kernel containment. TypeSafe runs on the trusted side of that boundary. This repository does not currently implement a remote worker fleet or microVM backend; see `autonomic_linux` HexDocs for the exact present limitation.
