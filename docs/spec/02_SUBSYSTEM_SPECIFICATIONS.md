# 02 — Subsystem Specifications

This document is normative. Public APIs may evolve, but the state-transition and trust properties below must remain true.

## 1. `Autonomic.EpisodeSupervisor` and `Autonomic.EpisodeController`

### Responsibility

Create and own one supervised episode tree. The supervisor provides OTP fault isolation; `EpisodeController` (`:gen_statem`) owns lifecycle transitions and coordinates intentional termination/restart of the untrusted worker and execution domain.

### Inputs

- immutable `EpisodeSpec` containing origin intent, workspace source, policy id/version, model adapter, resource ceiling, requested maximum effect class;
- control events from Homeostat, AuthorityGovernor, EffectBroker, operator, SystemRegulator, and ExecutionDomain;
- worker exit events.

### Controller states

| State | Meaning | Allowed privileged actions |
|---|---|---|
| `:bootstrapping` | ledger row, epoch 1, checkpoint 0, sandbox creation | none outside sandbox |
| `:running` | worker may perform local speculative work | Class 0/1; Class 2 via broker according to policy |
| `:yielding` | waiting for verification/approval/capacity | no new authoritative effects |
| `:preempting` | epoch advancement/worker interruption underway | none |
| `:repairing` | restoring snapshot and assembling repair context | none |
| `:containing` | hard shutdown/revocation | none |
| `:contained` | episode frozen for operator/review | none |
| `:completing` | final invariant checks and journal drain | already-authorized commit only |
| `:completed` | terminal success | none |
| `:failed` | terminal failure | none |

### Semantic exit handling

Typed semantic exits are controller events:

```text
{:semantic_exit, reason, evidence}
```

Default mapping:

- `:trajectory_violation` → epoch bump, kill domain, restore last stable checkpoint, repair;
- `:confidence_collapse` → yield; if persistent, narrow lease then repair/escalate;
- `:authority_exhausted` → yield and request stronger approval if policy permits;
- `:environment_mismatch` → preempt and rebuild domain from authoritative spec;
- `:irreversible_effect_risk` → abort prepared effect; remain running or yield depending severity.

After configurable repeated repairs, the controller degrades to deterministic/read-only mode or human dispatch. It must never restart indefinitely under `Supervisor` intensity alone.

### Crash recovery

Trusted child crash behavior:

- `Homeostat`, `AuthorityGovernor`, or `EpisodeController` crash: reconstruct from durable authoritative records and append a recovery event before worker execution resumes.
- `ExecutionDomain.Server` crash: advance epoch before replacing the domain unless the backend can prove no old process survived.
- `AgentWorker` crash: keep epoch if no privileged request was in flight and policy permits same-generation restart; otherwise advance epoch.
- Store unavailability: Class 2+ effects fail closed; existing sandbox computation may continue only under a bounded offline budget defined by policy.

## 2. `Autonomic.ExecutionDomain`

### Responsibility

Provide an OS-enforced disposable domain for untrusted processes. The behaviour is backend-neutral. Required initial backend: `AutonomicLinux.ExecutionDomain`.

### Linux backend enforcement

The Linux backend MUST combine orthogonal controls:

- new user, mount, PID, IPC, UTS and network namespaces;
- cgroup v2 subtree with CPU, memory, PIDs and optional I/O limits;
- seccomp policy denying disallowed syscall families and direct AF_INET/AF_INET6 sockets;
- read-only bind mounts for immutable inputs;
- overlayfs or equivalent copy-on-write mutable workspace;
- no host home directory or secret mounts;
- separate network namespace with no routable interface;
- a per-episode Unix-domain EffectBroker socket mounted into the domain;
- `no_new_privs` and constrained UID/GID mapping;
- bounded `/proc` view and no host PID namespace access.

### Port boundary

The BEAM process communicates with a minimal launcher helper as an external OS process via an OTP Port. It is deliberately not a NIF so faults in isolation code cannot corrupt the BEAM VM.

Protocol requirements:

- length-framed messages (`packet: 4` or equivalent);
- request id on every command;
- domain id and epoch on every lifecycle/exec request;
- idempotent `destroy`;
- explicit launcher protocol version;
- bounded message sizes;
- no shell interpolation; argv arrays only;
- launcher rejects unknown fields/actions.

Representative commands:

```text
create_domain
exec
signal
freeze
thaw
checkpoint_fs
destroy_domain
inspect_domain
```

### Checkpoint semantics

Namespace backend checkpoints are **quiescent filesystem/process-generation checkpoints**, not arbitrary memory snapshots:

1. cgroup freeze;
2. ensure no effect commit is in progress;
3. fsync/snapshot mutable overlay metadata;
4. record content-addressed workspace digest and launcher generation;
5. thaw.

Restore creates a **new** sandbox generation from the checkpoint. Old processes are never resurrected.

Firecracker backend may additionally restore microVM memory/device snapshots, but it must still mint a new authority generation/epoch as dictated by kernel policy.

### Destruction guarantee

`destroy/1` must attempt cgroup-wide kill, wait for `cgroup.events populated=0`, unmount the mutable layer, remove namespace resources, and report evidence of destruction. If destruction cannot be proven, the episode remains contained and the cgroup/domain id remains quarantined.

## 3. `Autonomic.Homeostat`

### Responsibility

Maintain the living trajectory state vector and convert observation frames into regime transitions and negative control signals.

### State

At minimum:

- smoothed drift and uncertainty;
- volatility;
- authority/destructive/scope pressure;
- blast-radius and autonomy balances;
- recent deterministic violations;
- semantic observation confidence/disagreement;
- repair/restart history;
- approval/verification pressure;
- current regime and regime dwell time;
- monotonic trajectory version.

### Inputs

`ObservationFrame` records from SensorArray. Frames contain deterministic facts and semantic observations separately. They are never merged into one opaque score.

### Outputs

- `{:homeostat, :continue, state_ref}`
- `{:homeostat, :narrow, requested_capability_delta, evidence}`
- `{:homeostat, :yield, reason, evidence}`
- `{:homeostat, :preempt, semantic_exit}`
- `{:homeostat, :contain, reason, evidence}`

### Hard violations

Deterministic boundary violations bypass temporal smoothing. Examples:

- direct network syscall outside permitted Unix socket;
- forbidden mount/path attempt surfaced by the launcher;
- stale epoch request;
- capability id misuse;
- process escaping its cgroup;
- forbidden credential access.

These can immediately drive `:containment` regardless of TypeSafe output.

### Semantic degradation

If TypeSafe is unavailable or confidence is invalid:

- do not fabricate neutral observations;
- mark semantic sensor health degraded;
- consume uncertainty budget;
- SystemRegulator may apply semantic backpressure;
- Class 3/4 commit remains blocked if policy requires semantic verification.

## 4. `Autonomic.AuthorityGovernor`

### Responsibility

Own episode epoch and capability leases. It is the only component allowed to request an epoch advancement transaction from the store.

### Lease properties

Every `CapabilityLease` has:

- episode id;
- epoch;
- opaque lease id;
- capability set with resource scopes;
- max effect class;
- issuance authority and reason;
- issued/expiry monotonic timestamps;
- policy version;
- optional verification/approval references;
- revocation state.

### Rules

- leases are short-lived and non-transferable between episodes;
- lease epoch must equal current episode epoch;
- fast semantic loop may narrow/revoke;
- widening beyond the prior lease requires an allowed higher-precedence authority;
- lease renewal revalidates current policy and regime;
- no lease can exceed episode hard envelope;
- old leases are never revalidated after an epoch bump; new lease id required.

### Epoch bump protocol

1. serialize with episode control row;
2. increment epoch in durable transaction;
3. expire older leases and prepared effects;
4. append ledger event;
5. publish invalidation to broker/domain/controller;
6. kill/fence old domain;
7. create new domain/lease only after recovery policy permits.

The durable epoch check in `EffectBroker` is the ultimate stale-request defense; process messaging is an optimization, not the correctness mechanism.

## 5. `Autonomic.EffectBroker` and `Autonomic.EffectJournal`

### Responsibility

Provide the only path from an untrusted domain to externally authoritative effects.

The broker is global/trusted. The journal is durably persisted and may have per-episode OTP projections for performance.

### States

```text
:proposed
  → :prepared
  → :evaluating
  → :ready
  → :commit_intent
  → :committing
  → :committed

Any pre-commit state → :aborted | :expired | :stale
:committing → :committed | :commit_unknown | :failed
```

`commit_unknown` is intentional and crucial: arbitrary external APIs do not provide exactly-once semantics. A process crash after an external mutation but before journal acknowledgement must not be blindly retried.

### API semantics

- `prepare/2` validates schema, target allowlist, policy ceiling, effect class and current epoch; it does not perform the external mutation.
- `evaluate/2` binds deterministic, semantic, verifier, and human decisions to the exact effect revision/version vector.
- `commit/2` revalidates semantic MVCC and records a durable commit intent before actuation.
- `abort/2` is idempotent for all pre-commit states.

### External adapters

Effect adapters are trusted plugins. Initial coding-agent set:

- `GitCommitAdapter` — materializes verified patch/commit from sandbox into authoritative repository;
- `GitRemoteAdapter` — push/fetch according to policy;
- `HTTPAdapter` — brokered HTTP with strict target/method/body limits;
- `ArtifactAdapter` — publish/upload with class-specific rules.

No adapter receives the worker's raw credential. Credentials are resolved by target policy inside the trusted broker.

## 6. `Autonomic.SensorArray`

### Responsibility

Concurrently ingest independent deterministic and semantic sensors and produce normalized `ObservationFrame` records.

### Deterministic sources

- launcher/cgroup lifecycle events;
- seccomp denials/notifications;
- process tree deltas;
- filesystem/mount boundary events;
- broker requests;
- resource counters;
- optional eBPF/audit feed for visibility (not sole enforcement).

### Semantic source

`AutonomicTypesafe.Sensor` uses the TypeSafeSDK 0.2 strict semantic API: construct the production sensor bank with `noul/choice/score`, prepare it once with `prepare/1` or `prepare!/1`, and invoke `evaluate/4` for each bounded observable window. The adapter returns normalized observations while leaving semantic request/response validation to the SDK.

The adapter MUST:

- build the sensor questions from one versioned declarative bank specification and reuse one validated `TypeSafeSDK.Prepared` value rather than rebuilding questions for every frame;
- redact secrets before semantic requests;
- cap the redacted observable state before the SDK boundary and record truncation/coalescing facts;
- preserve actual response model, requested model when relevant, SDK version, request id, usage, retries, logical/runtime latency, sensor-bank version and semantic-contract id;
- use `TypeSafeSDK.Response` / `TypeSafeSDK.Answer.*` helpers rather than reimplementing ranking, margin, expected-score or certainty math;
- treat a required answer represented only as an unknown future answer tag as unavailable/degraded, never safe;
- enforce any kernel policy that pins allowed actual models and treat mismatch as contract drift, not as an SDK assertion about model quality;
- preserve raw response references only according to the configured retention/redaction policy;
- use explicit timeout/retry policy suitable to the fast or slow loop; retries MUST NOT be mistaken for proof that a previous ambiguous upstream attempt was not processed;
- inspect `TypeSafeSDK.RuntimeCapabilities` where transport guarantees matter and fail closed rather than assuming queue/body/cancellation properties that are unadvertised;
- keep GenStage/SystemRegulator backpressure authoritative at the kernel level; SDK batch concurrency is not a substitute for system-wide pressure control.

`TypeSafeSDK.Test` is the preferred deterministic component-test seam because it preserves production serialization/retry/decode behavior, but it never satisfies the mandatory live TypeSafe gate.

### Backpressure

Sensor ingestion uses demand-driven flow (`GenStage` in the reference design). When semantic consumers fall behind:

- low-value observation sampling may be coalesced;
- deterministic violations are never dropped;
- Homeostat receives explicit `sensor_overloaded` facts;
- SystemRegulator reduces new episode admission;
- sensitive effect commits yield rather than bypass verification.

## 7. `Autonomic.SnapshotManager` and `Autonomic.RepairManager`

### SnapshotManager

Owns trusted checkpoint metadata. A checkpoint includes:

- episode/epoch/generation;
- sandbox filesystem snapshot ref/digest;
- authoritative git base/patch digest;
- environment/dependency-lock digest;
- capability/policy refs;
- trajectory state ref/version;
- pending effect ids;
- creation reason and trust level.

A checkpoint is not considered stable until the store record and backend snapshot digest agree.

### RepairManager

A repair is not “tell the model it was bad.” It is a controlled reconstruction:

1. advance/fence epoch if required;
2. terminate old domain;
3. choose last stable compatible checkpoint;
4. abort/stale uncommitted old-epoch effects;
5. restore a new domain generation;
6. construct minimal repair context from authoritative facts;
7. explicitly exclude contaminated scratchpad segments when policy says so;
8. mint a new narrower lease;
9. restart worker;
10. record recovery lineage.

Repair context may state the concrete violated invariant but must not reveal secrets or kernel internals that enable bypass.

## 8. `Autonomic.SystemRegulator`

### Responsibility

Aggregate cluster-wide pressure and safety signals and control admission/autonomy modes.

### Inputs

- sandbox capacity;
- TypeSafe p50/p95/p99 latency and failure rate;
- approval queue size/oldest age;
- store health;
- broker commit backlog;
- per-model rollback and containment rate;
- semantic regime distribution;
- launcher health.

### Modes

```text
:normal
:constrained
:read_only_autonomy
:no_sensitive_commits
:admission_closed
```

Transitions must be hysteretic and auditable. A model/provider-specific anomaly can quarantine only that cohort while leaving unrelated work available.

### Semantic circuit breaker

Example trigger:

```text
new model version shows 4x baseline authority-escalation pressure
AND 3x rollback rate over minimum sample size
```

Response may pin new episodes to the prior model, prevent lease expansion, and block Class 3/4 commits for the affected cohort pending operator review.
