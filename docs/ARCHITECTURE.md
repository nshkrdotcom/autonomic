# Architecture and kernel invariants

The normative architecture is in `docs/spec/01_SYSTEM_ARCHITECTURE.md`; this document describes how the repository realizes it.

## Trusted and untrusted planes

`Autonomic.EpisodeSupervisor` owns a per-episode rest-for-one tree: `AuthorityGovernor`, `EffectSocket`, `SensorArray`, `Homeostat`, `SensorConsumer`, and the `:gen_statem` `EpisodeController`. Global trusted services are the registry, task supervisor, rate limiter, system regulator and `EffectBroker`.

The worker runs only through `Autonomic.Linux.Backend`. The backend speaks a bounded packet-4 JSON protocol to the privileged external Rust launcher. The launcher creates a separate user/mount/PID/network/IPC/UTS namespace set, a cgroup-v2 subtree, a read-only rootfs, and a disposable overlayfs workspace. The sandbox receives one broker-owned Unix socket at `/run/autonomic/effect.sock`; it receives no host home, secrets, Docker socket, cloud credentials or authoritative Git checkout.

## Authority flow

1. Admission validates an `EpisodeSpec` against the signed/deterministic hard envelope.
2. PostgreSQL creates/fetches the episode and durable epoch.
3. `AuthorityGovernor` issues a finite lease for the current epoch and policy version.
4. Class 0/1 work executes inside the disposable domain.
5. Class 2+ work is proposed to `EffectBroker` with an exact payload digest and version vector.
6. The store persists `proposed`, then `prepared`; required decisions are recorded against the exact revision.
7. At commit, the store locks **episode → effect → lease**, rereads the durable epoch/policy/trajectory/revision, verifies unexpired decisions, and persists `commit_intent` before adapter actuation.
8. Adapter success becomes `committed`; ambiguous post-intent failures become `commit_unknown` and require reconciliation/operator handling.

## Precedence

Dominance is not weighted voting:

`Kernel Denial ≻ Capability Violation ≻ Deterministic Invariant ≻ Signed Policy ≻ Human Authority ≻ Semantic Observation`

A seccomp or forbidden-path violation is a hard deterministic observation and bypasses Homeostat smoothing. TypeSafe/Jev may recommend continue/narrow/yield/preempt but cannot expand a lease or hard envelope.

## Recovery

A repair durably advances epoch, which revokes old leases and stales old uncommitted effects. The old cgroup must be destroyed and proven empty before the old upperdir is accepted as gone. The latest stable checkpoint is digest-verified, restored into a **new epoch/generation**, a reduced repair lease is minted, and recovery lineage is persisted. Controller restart uses persisted domain identity and takes the same conservative recovery path.

## Backpressure

`SensorArray` is demand-driven through GenStage. Critical deterministic frames are never intentionally dropped; low-priority semantic work may be shed under configured pressure. `SystemRegulator` aggregates semantic/verifier/effect pressure into admission modes. Sensitive effects yield instead of bypassing a required verifier.

## Bounded broker execution

`Autonomic.EffectBroker` keeps no in-memory authority, but it does bound concurrent orchestration work. Calls are dispatched to the supervised task pool up to `:effect_concurrency`; excess work is rejected with `:effect_broker_saturated` instead of building an unbounded internal queue. Active pressure is reported to `SystemRegulator`, whose hysteretic modes propagate saturation to admission and sensitive-commit policy. PostgreSQL row locks and durable state transitions—not task scheduling—remain the race/fencing authority.
