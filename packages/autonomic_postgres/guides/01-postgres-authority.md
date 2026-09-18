# PostgreSQL Durable Authority

`autonomic_postgres` implements `Autonomic.Store` with Ecto/PostgreSQL. It is the durable authority and audit layer for the reference composition; worker state and sandbox state are disposable.

## What becomes durable

The store persists the control-plane objects that must survive worker or BEAM-process failure:

- episode identity and current epoch;
- signed policy/version state;
- capability leases;
- checkpoints and recovery lineage;
- proposed effects and exact effect revisions;
- effect decisions and commit state;
- observation frames;
- trajectory state;
- append-only episode events;
- recovery records.

## Semantic evidence is not ephemeral telemetry

When the TypeSafe-backed sensor produces `Autonomic.SemanticObservation` values, the surrounding `ObservationFrame` can be recorded by the store. Homeostat trajectory updates are persisted as part of episode state, and EffectBroker semantic decisions are recorded against exact effect revisions.

That gives the operator a durable chain from:

```text
observable state
  -> TypeSafe semantic observations
  -> trajectory/effect decision
  -> authority consequence
```

without making the semantic model itself authoritative.

## Core invariants enforced

- **Epoch fencing:** stale leases/effects cannot cross into a newer episode epoch.
- **Commit horizon:** authoritative mutations persist `commit_intent` before adapter actuation.
- **Exact-revision decisions:** semantic/verifier/human decisions are bound to the effect revision and version vector they evaluated.
- **Auditable observation history:** observation frames and episode events provide durable evidence for trajectory and recovery analysis.

See [Semantic Evidence and Trajectories](04-semantic-evidence-and-trajectories.md) for the TypeSafe-specific persistence path.
