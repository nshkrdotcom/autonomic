# PostgreSQL Durable Authority

`autonomic_postgres` implements the `Autonomic.Store` behaviour using Ecto and PostgreSQL.

It serves as the definitive source of truth for all durable authority, leases, effects, checkpoints, and episode state. Worker sandboxes are disposable; PostgreSQL reconstructs the episode.

## Core Invariants Enforced

- **Epoch Fencing**: Leases and effect intents are bound to an explicit episode epoch. Stale epoch mutations are rejected atomically.
- **Commit Horizon**: Class 3 and 4 mutations enter a durable `commit_intent` row before any adapter executes the mutation.
- **Auditable Ledger**: Episode events and observation frames are appended immutably with hash-chained integrity.
