# Kernel Architecture

`autonomic` is the foundational, implementation-independent BEAM/OTP control plane for running untrusted coding workers inside disposable execution domains while keeping durable authority, policy, effects, verification, recovery, and audit state in a trusted control plane.

## Key Subsystems

- `Autonomic.AuthorityGovernor` — Epoch fencing, lease lifecycle, decision signing.
- `Autonomic.EffectBroker` — Strict mediation of external side effects; enforces speculation-before-commitment.
- `Autonomic.Homeostat` & `Autonomic.SystemRegulator` — Dynamic supervision, trajectory monitoring, and health maintenance.
- `Autonomic.SensorArray` & `Autonomic.SemanticSensor` — Streaming sensor ingestion and boundary checks.
- `Autonomic.VerificationRunner` & `Autonomic.RepairManager` — Multi-tiered verification execution and episode repair.
- `Autonomic.EpisodeSupervisor` & `Autonomic.EpisodeController` — Per-episode process tree management.
- `Autonomic.Store` — Behaviours for persistence and ledger durability (implemented by `autonomic_postgres`).
- `Autonomic.ExecutionDomain` — Behaviours for sandbox containment (implemented by `autonomic_linux`).
