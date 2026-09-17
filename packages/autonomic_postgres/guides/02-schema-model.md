# PostgreSQL Schema Model

The Ecto schemas in `autonomic_postgres` model the durable kernel state:

- `Autonomic.Store.Schema.Episode` — The root episode lifecycle record, epoch counter, and envelope.
- `Autonomic.Store.Schema.CapabilityLease` — Active and revoked capability grants bound to an episode epoch.
- `Autonomic.Store.Schema.Checkpoint` — Incremental filesystem, git, and state tree checkpoints.
- `Autonomic.Store.Schema.Effect` — Proposed, validating, prepared, and committed external side effects.
- `Autonomic.Store.Schema.EffectDecision` — Signed authorization tokens authorizing effect execution.
- `Autonomic.Store.Schema.EpisodeEvent` — Append-only chronological audit log.
- `Autonomic.Store.Schema.ObservationFrame` — Recorded observations and sensor telemetry.
- `Autonomic.Store.Schema.RecoveryRecord` — Diagnostic data from failure containment and recovery.
