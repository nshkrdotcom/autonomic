# PostgreSQL persistence and recovery

The reference store is `Autonomic.Store.Postgres` using Ecto/Postgrex. Migration `apps/autonomic_store/priv/repo/migrations/20260917000000_create_autonomic_tables.exs` creates episodes, capability leases, checkpoints, effects, exact-revision decisions, hash-chained episode events, normalized observation frames and recovery records.

## Lock order

Every authority-changing transaction follows one order:

1. episode row (`FOR UPDATE`)
2. effect row when applicable
3. lease row when applicable
4. target-specific CAS/lock only after the DB commit horizon transaction

Epoch advance locks the episode first, increments monotonically, revokes older leases, stales older uncommitted effects and records any older in-flight commit intents for reconciliation.

## Effect durability

`put_effect/1` stores `proposed`; `prepare_existing_effect/1` checks durable epoch, live lease, policy/trajectory/revision vector and moves to `prepared`. Decisions bind to effect revision, epoch, policy version, trajectory version and payload digest. `begin_effect_commit/2` locks episode/effect/lease, validates all bindings and writes a globally unique commit attempt plus stable idempotency key before target actuation.

After `commit_intent`, generic adapter errors are **not** interpreted as non-execution. They become `commit_unknown` unless the adapter returns a positive receipt. Startup reconciliation scans nonterminal commit states.

## Checkpoints

Checkpoint bytes are supplied by the execution backend and addressed by digest. PostgreSQL stores the reference/digest plus epoch, domain generation, Git base, trajectory/policy version and ancestry. A stable checkpoint updates the episode's current checkpoint only in the same transaction that records the checkpoint and ledger event.

Repair advances epoch first, proves the old cgroup empty, restores a verified checkpoint into a new domain generation, rebases Homeostat, creates a constrained repair lease and records recovery lineage. Scratchpad/hidden reasoning is not replayed; the repair context contains bounded trusted facts only.

## DB outage

There is no in-memory authority fallback. Store failure prevents fresh epoch proof, lease validation and Class 2+ commit authorization. This is deliberate: availability does not outrank authority correctness.
