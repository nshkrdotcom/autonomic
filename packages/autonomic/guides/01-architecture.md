# Kernel Architecture

`autonomic` is the implementation-independent BEAM/OTP control plane. It owns episode lifecycle, authority, effect mediation, trajectory regulation, verification contracts, and the behaviours implemented by the three companion packages.

The core package deliberately does **not** depend on Linux, PostgreSQL, or TypeSafeSDK. That is a package-boundary decision, not a statement that those systems are unimportant to the reference composition. The repository's full reference composition is:

```text
                         trusted control plane

  +------------------+      +----------------------+      +----------------------+
  |    autonomic     |<-----| autonomic_postgres   |      | autonomic_typesafe   |
  |                  |      | durable authority    |      | TypeSafe semantic    |
  | EffectBroker     |      | + observation ledger |      | sensor bank          |
  | Homeostat        |<-----------------------------------|                      |
  | AuthorityGovernor|      +----------------------+      +----------------------+
  +--------+---------+
           ^
           |
  +--------+---------+
  | autonomic_linux  |
  | ExecutionDomain  |
  +------------------+
```

Dependency arrows point from concrete adapters to `autonomic`; runtime data flow is different. The application configures implementations of `Autonomic.Store`, `Autonomic.ExecutionDomain`, and `Autonomic.SemanticSensor`.

## The TypeSafe data path

The semantic path is not a detached observability feature. A configured `Autonomic.Typesafe.Sensor` supplies typed semantic observations to two core consumers:

```text
observable worker/effect state
        |
        v
Autonomic.SemanticSensor
        |
        | TypeSafe-backed implementation
        v
SemanticObservation[]
        |
        +------------------------+
        |                        |
        v                        v
   Homeostat                EffectBroker
 temporal trajectory        per-effect semantic
 regulation                 authorization evidence
        |                        |
        v                        v
continue / yield /          allow / deny semantic
narrow / preempt            decision for exact revision
```

`SemanticObservation` preserves the sensor value, confidence, probability distribution, requested and actual model, request ID, SDK version, sensor-bank version, semantic-contract fingerprint, usage, retries, latency, observation time, and sensor-specific metadata.

The production TypeSafe bank lives in `autonomic_typesafe` and currently defines five sensors:

- `scope_drift` — Noul
- `authority_escalation` — Noul
- `evidence_sufficiency` — Score
- `irreversibility` — Score
- `trajectory_regime` — Choice

See [TypeSafe Control Loop](05-typesafe-control-loop.md) for the exact consumption semantics in core.

## Key subsystems

### `Autonomic.AuthorityGovernor`

Owns epoch-fenced capability leases. Semantic evidence can never mint a capability, advance an epoch, or expand a signed hard envelope.

### `Autonomic.EffectBroker`

Mediates Class 2+ effects. It binds proposals and decisions to exact effect revisions, epoch, policy version, trajectory version, lease, and payload digest. When policy requires semantic evaluation it builds an `ObservationFrame`, calls the configured semantic sensor in slow mode, records the semantic allow/deny decision, and still requires every other decision class demanded by policy.

### `Autonomic.Homeostat`

Consumes deterministic facts, TypeSafe-derived semantic observations, and resource pressure over time. It maintains exponentially smoothed drift, volatility, uncertainty, scope pressure, authority pressure, and destructive pressure. Regimes produce concrete controller actions:

| Regime | Core action |
| --- | --- |
| `stable` | continue |
| `uncertain` | yield |
| `drifting` | narrow to Class 1 isolated mutable effects |
| `unstable` | preempt with semantic trajectory exit |
| `containment` | deterministic hard-containment path |

Recovery from risky regimes is hysteretic; one reassuring frame does not immediately erase sustained drift.

### `Autonomic.SensorArray`

Provides bounded sensor ingestion and backpressure. Critical deterministic facts are not intentionally dropped. Semantic work can degrade without becoming authority.

### `Autonomic.Store`

Owns the durable contract implemented by `autonomic_postgres`: episodes, epochs, leases, effects, decisions, observation frames, trajectory state, checkpoints, and recovery lineage.

### `Autonomic.ExecutionDomain`

Owns the execution-domain contract implemented today by `autonomic_linux`. The current Linux backend is host-local shared-kernel containment; it is not a remote worker-fleet protocol or a hardware-virtualized trust boundary. See the `autonomic_linux` HexDocs for the exact boundary.

## Precedence is a dominance lattice

The architecture does not average semantic confidence against deterministic facts:

```text
Kernel denial
  > capability violation
  > deterministic invariant
  > signed policy
  > human authority
  > semantic observation
```

A high-confidence TypeSafe answer can cause narrowing, yielding, preemption, or a semantic effect denial. It cannot turn a forbidden target, stale epoch, invalid lease, or seccomp violation into an allowed operation.
