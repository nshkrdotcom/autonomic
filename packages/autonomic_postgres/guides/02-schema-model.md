# PostgreSQL Schema Model

The Ecto schemas in `autonomic_postgres` mirror the durable control-plane model rather than the disposable worker filesystem.

| Schema | Responsibility |
| --- | --- |
| `Episode` | lifecycle root, current epoch, policy, trajectory state |
| `CapabilityLease` | epoch/policy-bound authority grant and revocation state |
| `Checkpoint` | filesystem/Git/state recovery metadata |
| `Effect` | proposed external action, exact revision, payload identity, state machine |
| `EffectDecision` | semantic/verifier/human decision bound to an exact effect revision/version vector |
| `EpisodeEvent` | chronological audit/event stream |
| `ObservationFrame` | deterministic/resource/semantic observations and provenance |
| `RecoveryRecord` | failure/repair lineage and containment evidence |

## Semantic observation persistence

`Autonomic.SemanticObservation` is intentionally richer than a boolean flag. It can carry:

- sensor name/value;
- confidence;
- probability map;
- actual and requested model;
- TypeSafe request ID;
- SDK version;
- sensor-bank version;
- Prepared semantic-contract fingerprint;
- usage/retry/latency provenance;
- sensor-family metadata.

The PostgreSQL package stores observation frames as durable evidence; it does not reinterpret TypeSafe semantics. Meaning remains core policy's responsibility.

## Effect decisions

A semantic allow/deny recorded by `EffectBroker` is not detached from the action it evaluated. Decision persistence binds it to the effect revision, epoch, policy version, trajectory version, and payload digest. A revised proposal therefore cannot reuse stale semantic approval.

## Trajectory state

Homeostat state is durable enough to recover the current trajectory version/regime and continue conservative recovery after process failure. PostgreSQL is not performing semantic inference; it stores the resulting control-plane state and provenance.
