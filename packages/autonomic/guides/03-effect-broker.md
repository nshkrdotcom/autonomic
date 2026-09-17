# EffectBroker and Mutation Horizons

`Autonomic.EffectBroker` arbitrates all external side effects requested by an untrusted worker.

## Effect Classes

- **Class 1 (Sandbox Internal)**: Process execution within disposable overlay, ephemeral file writes. Never crosses broker.
- **Class 2 (Observable / Compensatable External)**: External read queries, cache lookups, bounded HTTP reads (`Autonomic.Adapters.HTTP`).
- **Class 3 (Authoritative External Mutation)**: Git commits, branch creation, database writes, bounded HTTP mutations.
- **Class 4 (Irreversible High-Impact)**: Artifact publication, remote tag push, credential updates. Requires explicit human horizon or exact cryptographic approval.

## Protocol States

An effect traverses a strict deterministic state machine:
`proposed` → `validating` → `prepared` → `authorizing` → `commit_intent` → `committing` → `committed` (or `aborted` / `commit_unknown`).
