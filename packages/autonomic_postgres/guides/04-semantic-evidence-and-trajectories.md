# Semantic Evidence and Trajectories

This guide connects `autonomic_typesafe` output to the PostgreSQL durability model.

## Three different durable things

Do not collapse these into one "AI decision" record:

1. **Observation evidence** — what deterministic/resource/semantic sensors observed.
2. **Trajectory state** — what Homeostat derived over time from observation history.
3. **Effect decision** — whether a specific effect revision satisfied a required semantic decision floor.

They answer different audit questions.

## Observation frames

The TypeSafe adapter returns normalized `Autonomic.SemanticObservation` structs. They are placed on `Autonomic.ObservationFrame` alongside deterministic facts, resources, effect context, and sequence/epoch identity.

The observation provenance makes later analysis possible:

```text
Which model produced this answer?
Which TypeSafe request produced it?
Which prepared semantic contract was active?
What confidence/distribution was returned?
Which bank version interpreted it?
How long did it take and what usage was reported?
```

## Trajectory persistence

`Autonomic.Homeostat` consumes semantic observations temporally. It updates state such as drift, uncertainty, authority pressure, destructive pressure, autonomy balance, and the current regime.

Persisting trajectory state means a BEAM process restart does not imply semantic amnesia or a free reset to `stable`.

## Effect-decision persistence

When `EffectBroker` requires semantic authorization, the decision record is tied to:

```text
effect ID
exact effect revision
episode epoch
policy version
trajectory version
payload digest
semantic evidence digest/reference
```

That is materially different from storing "TypeSafe said yes." It records that a particular semantic evaluation contributed to authorization of a particular proposal under a particular authority generation.

## Separation of concerns

`autonomic_typesafe` owns semantic measurement.

`autonomic` owns interpretation and authority policy.

`autonomic_postgres` owns durability and concurrency/fencing.

Keeping those responsibilities separate prevents the database adapter from becoming a hidden second semantic policy engine.
