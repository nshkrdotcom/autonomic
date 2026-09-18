# 01 — System Architecture

## 1. System worldview

`autonomic_kernel` is not middleware that asks an LLM whether another LLM is safe. It is a trusted execution kernel that treats probabilistic workers as untrusted programs.

The analogy to an operating system is structural rather than cosmetic. The runtime owns:

- process and sandbox lifecycle;
- capability issuance and revocation;
- resource budgets;
- deterministic security boundaries;
- system-call/effect mediation;
- temporal semantic supervision;
- admission and backpressure;
- checkpoint/restart;
- crash containment;
- durable authoritative state;
- transaction-like commit semantics for external effects.

A worker may be computationally healthy while semantically unhealthy. Therefore ordinary process liveness is insufficient. The runtime supervises both **execution health** and **trajectory health**.

The fundamental object is an **episode**: one bounded unit of autonomous work with immutable origin intent, mutable trajectory state, monotonically increasing authority epoch, deterministic policy version, current snapshot ancestry, and an effect ledger.

## 2. Trust and boundary model

```text
┌──────────────────────────────── TRUSTED HOST ────────────────────────────────┐
│                                                                              │
│  ┌────────────────────────── AUTONOMIC KERNEL ───────────────────────────┐   │
│  │ EpisodeController      AuthorityGovernor      Homeostat               │   │
│  │ EffectBroker           EffectJournal          SnapshotManager         │   │
│  │ SystemRegulator        Ledger/Store           Sensor fusion           │   │
│  │                                                                      │   │
│  │ Deterministic policy is authoritative. Semantic evidence is advisory │   │
│  │ within the policy envelope and may trigger contraction/preemption.   │   │
│  └──────────────┬───────────────────────┬──────────────────────┬─────────┘   │
│                 │                       │                      │             │
│        control/epoch             brokered effects       semantic sensor     │
│                 │                       │                      │             │
│  ┌──────────────▼──────────────┐  ┌─────▼────────────┐  ┌──────▼────────┐   │
│  │ LINUX EXECUTION BACKEND     │  │ EFFECT ADAPTERS │  │ TypeSafe/Jev  │   │
│  │ namespaces + cgroup v2      │  │ Git / HTTP /    │  │ sensor only   │   │
│  │ seccomp + overlayfs         │  │ artifact APIs   │  │ no authority  │   │
│  └──────────────┬──────────────┘  └─────┬────────────┘  └───────────────┘   │
│                 │                       │                                    │
│       ┌─────────▼────────────────┐      │                                    │
│       │ UNTRUSTED USER SPACE     │      │                                    │
│       │ agent / shell / compiler │      │                                    │
│       │ package manager / tests  │      │                                    │
│       │ no host filesystem       │      │                                    │
│       │ no direct Internet       │      │                                    │
│       └──────────────────────────┘      │                                    │
│                                        ▼                                    │
└─────────────────────────────────── EXTERNAL WORLD ────────────────────────────┘
                                         Git remotes / APIs / registries /
                                         deployment systems / humans
```

### 2.1 Root of trust

The root of trust is, in order:

1. Linux kernel isolation and the host launcher boundary;
2. deterministic policy and capability checks;
3. the durable epoch/effect ledger;
4. OTP kernel processes operating over those mechanisms.

TypeSafe/Jev is **not** in the root of trust. Its output is treated as potentially wrong, unavailable, delayed, or adversarially influenced.

### 2.2 Hard envelope versus autonomic envelope

Each episode receives a deterministic hard envelope that cannot be widened by semantics:

```text
hard envelope
  ├─ mount allowlist
  ├─ maximum CPU/memory/PID budget
  ├─ allowed syscall profile
  ├─ direct-network prohibition
  ├─ brokered target allowlist
  ├─ credential classes available to broker
  └─ maximum effect classes eligible for approval
```

Inside that envelope, the `AuthorityGovernor` may issue narrower short-lived capability leases. Fast semantic signals may keep, narrow, or revoke those leases. Expansion requires a stronger authority source: signed policy, parent capability, slow verifier, or human approval as configured.

## 3. Episode process topology

The root application supervision tree is:

```text
Autonomic.Supervisor (:one_for_one)
├── Autonomic.StoreSupervisor
├── Autonomic.Registry
├── Autonomic.EffectBroker
├── Autonomic.SystemRegulator
├── Autonomic.SensorIngressSupervisor
└── Autonomic.EpisodeDynamicSupervisor
      └── EpisodeSupervisor[episode_id]
          ├── EpisodeController (:gen_statem)
          ├── AuthorityGovernor
          ├── Homeostat
          ├── SnapshotManager
          ├── ExecutionDomain.Server
          ├── SensorArray.Supervisor
          ├── RepairManager
          └── AgentWorker (replaceable/disposable)
```

`EpisodeController` is the episode authority for lifecycle state. Semantic faults are not implemented by arbitrarily crashing trusted processes. They are typed events that the controller maps to restart, rollback, containment, degradation, or escalation. The untrusted worker may be terminated as part of those transitions.

### 3.1 Episode controller states

Normative lifecycle states:

```text
:bootstrapping
   ↓
:running ⇄ :yielding
   ↓          ↓
:repairing ← :preempting
   ↓
:running

:any → :containing → :contained
:any → :completing → :completed
:any → :failed
```

`:yielding` means computation may be paused because the verification/approval horizon is not clear. A Class 3/4 effect cannot turn `:yielding` into execution by itself.

## 4. Hierarchical control loops

### 4.1 Fast reflex loop

Target cadence is approximately 100 ms to several hundred milliseconds when the semantic service and workload permit. It is asynchronous and never serializes every token through TypeSafe.

Inputs:

- visible output chunks;
- structured tool-call deltas and arguments;
- command proposals;
- stdout/stderr windows;
- filesystem/diff summaries;
- kernel sensor frames;
- capability/effect requests.

Pipeline:

```text
observable stream
   │
   ├── deterministic sensor frame ──────────────┐
   │                                            │
   └── bounded semantic window → TypeSafe/Jev ─┤
                                                ▼
                                         ObservationFrame
                                                │
                                                ▼
                                            Homeostat
                                  ┌─────────────┼──────────────┐
                                  ▼             ▼              ▼
                               continue       narrow        preempt
```

Fast-loop semantic output may **never grant new hard authority**. Its strongest immediate privilege is negative: narrow, revoke, force yield, or preempt.

### 4.2 Slow deliberative loop

The slow loop evaluates a larger trajectory before sensitive commits. It may use a larger verifier, deterministic checks, human approval, or multiple independent sources.

Triggers include:

- Class 3 or 4 effect reaching `:evaluating`;
- semantic regime transition to `:drifting` or worse;
- repeated repair;
- requested authority expansion;
- substantial workspace change;
- model/provider change during an episode.

Outputs are signed/attributed `VerificationDecision` records with expiry and the exact episode epoch/policy/snapshot they evaluated.

### 4.3 Control-loop asymmetry

The system deliberately makes safety contraction faster than capability expansion:

```text
fast loop  → continue | throttle | narrow | revoke | interrupt
slow loop  → may additionally authorize bounded expansion or commit
```

## 5. Sensory precedence lattice

The precedence relation is normative:

```text
Kernel Denial
    ≻ Capability Violation
    ≻ Deterministic Invariant
    ≻ Signed Policy
    ≻ Human Authority
    ≻ Semantic Observation
```

This is a **dominance lattice**, not a weighted average. A lower-precedence signal cannot cancel a negative higher-precedence fact.

Example:

```text
Semantic observation: "this outbound request appears benign"
Kernel fact: destination is outside the broker allowlist
Result: DENY
```

Likewise, a human approval cannot make a host mount outside the constitutional hard envelope available unless the signed policy itself permits that class of expansion.

## 6. Semantic sensor bank

TypeSafe/Jev is used as multiple bounded sensors, not one `safe?` classifier. Initial sensor families:

- `scope_drift` — has the observable trajectory moved away from the declared task?
- `authority_escalation` — is the worker attempting to acquire capabilities not implied by the task?
- `irreversibility` — how irreversible/high-impact is the proposed action?
- `evidence_sufficiency` — is the worker acting without enough evidence?
- `goal_abandonment` — is the original objective being replaced?
- `environment_mismatch` — is the worker reasoning about a different environment than the active sandbox?
- `semantic_novelty` — is the current trajectory unlike the preceding stable window?
- `regime` — `stable | uncertain | drifting | unstable` classification.

### 6.1 TypeSafeSDK 0.4 production boundary

The production adapter targets TypeSafeSDK 0.4.0 only. It prepares one strict semantic bank and executes it through `TypeSafeSDK.OTP.Server` rather than blocking the bank GenServer on network work. The wrapper uses the package-owned `Autonomic.Typesafe.Tasks` supervisor and an explicit `max_in_flight` bound.

TypeSafeSDK owns semantic validation, request construction, exact final request-size enforcement, response decoding/contracts, bounded response metadata, Prepared fingerprints and per-answer telemetry. Pristine remains the SDK's transport/resilience runtime. Autonomic MUST NOT duplicate those layers.

The adapter reads answers through `TypeSafeSDK.Response` / `TypeSafeSDK.Answer.*`, preserving actual model, request ID, usage, retry count, elapsed time, distributions and confidence. Thresholds remain Autonomic policy and are never SDK safety guarantees.

### 6.2 Fail-closed response interpretation

Production evaluations configure an SDK response contract with `on_unknown_answer: :error` and the configured exact `allowed_models` set (or `nil` when no allow-set is configured). Unexpected response answer IDs and concrete-model drift therefore fail inside the SDK contract layer.

TypeSafe intentionally preserves a future answer *type* under a requested key. Because Autonomic's fixed bank requires known Noul/Choice/Score families, any remaining `unknown_answers` entry is semantic unavailability, never an implicit negative or `safe` result.

### 6.3 Semantic contract identity

The contract ID is the native `TypeSafeSDK.Prepared.fingerprint/1` value. Persist it together with the human sensor-bank version. Do not maintain a duplicate local hash implementation or inspect private Prepared fields. A changed fingerprint invalidates calibration artifacts frozen against the prior semantic question contract.

### 6.4 Evidence and exact request budgeting

Autonomic still owns the bounded observable window and secret redaction. `evidence_limit` bounds the redacted semantic state before the SDK boundary. Separately, `request_limit` is passed to TypeSafe as `max_request_bytes:` so the SDK measures the exact final serialized request before transport egress. The second guard supplements rather than replaces the first.

### 6.5 Runtime capabilities and bounded OTP execution

The reference adapter requires `:unary_cancellation` and `:cancellation_cleanup` through `TypeSafeSDK.RuntimeCapabilities`. The supplied Pristine 0.4 Finch transport advertises both as supported. Unsupported or unverified custom transports fail bank startup.

The TypeSafe OTP wrapper gives each request a private Pristine cancellation scope and cancels pending work on bank shutdown. Autonomic does not add another transport cancellation layer. `TypeSafeSDK.Batch` is not used as a replacement for kernel-level GenStage/SystemRegulator backpressure.

See `12_TYPESAFE_SDK_INTEGRATION.md` for the normative adapter contract.

## 7. Homeostatic trajectory model

The Homeostat maintains a temporal state rather than making threshold decisions from one model call.

Minimum state dimensions:

```text
drift
volatility
uncertainty
scope_pressure
authority_pressure
destructive_pressure
blast_radius_remaining
autonomy_balance
verification_pressure
approval_pressure
repair_count
recent deterministic violations
```

A reference smoothing strategy is an EWMA with configurable coefficients and hysteresis:

```text
x_t = α * observation_t + (1 - α) * x_(t-1)
volatility_t = β * abs(x_t - x_(t-1)) + (1 - β) * volatility_(t-1)
```

No coefficient is security-critical. Hard violations bypass smoothing and trigger an immediate negative transition.

Regimes:

```text
:stable → :uncertain → :drifting → :unstable → :containment
```

Transitions back toward stability require hysteresis and minimum dwell to avoid rapid permission oscillation.

## 8. Semantic MVCC

Every commit-sensitive decision is evaluated against an immutable version vector:

```text
V = (
  episode_id,
  epoch,
  policy_version,
  snapshot_ancestry,
  trajectory_version,
  trajectory_regime,
  lease_id,
  effect_revision
)
```

At `prepare`, the effect records `V_prepare`. At commit, the broker re-reads authoritative state and validates that every required component is still compatible.

### 8.1 Commit validation

For a Class 3/4 effect, `commit/2` MUST verify at least:

1. episode still active;
2. `effect.epoch == current_episode_epoch`;
3. lease exists, is unexpired, and is for the same epoch;
4. deterministic policy version is unchanged or explicitly declared compatible;
5. current snapshot descends from the prepared snapshot ancestry;
6. trajectory regime remains allowed for the effect class;
7. required slow-verifier/human approval records match the exact effect revision and epoch;
8. effect has not expired or been superseded;
9. target-specific preconditions still hold.

Any mismatch causes `{:error, :stale_authority}` or a more specific conflict. The worker must re-propose against the current state; stale authorization is never silently refreshed.

### 8.2 Epoch advancement

Epoch advancement is a serializable control-plane transaction. It must atomically:

- increment `episodes.current_epoch`;
- revoke/expire active leases from older epochs;
- mark prepared effects from older epochs stale;
- append an authoritative `epoch_advanced` ledger record;
- publish an OTP invalidation event.

External process termination and sandbox destruction follow immediately, but correctness does not depend on them completing before stale requests are rejected: the EffectBroker checks the ledger epoch on every privileged commit.

## 9. Speculation and commit horizon

Inside the sandbox, the worker may speculatively:

- read the mounted workspace;
- edit the mutable overlay;
- compile;
- run tests;
- create local commits in the disposable clone;
- spawn bounded child processes;
- consume pre-fetched dependencies or brokered read resources.

It cannot directly:

- reach arbitrary Internet endpoints;
- access host secrets;
- push Git refs;
- publish packages;
- send messages;
- mutate production APIs;
- deploy infrastructure.

Those operations become `ProposedEffect` records and cross the EffectBroker.

## 10. System-wide regulation

`Autonomic.SystemRegulator` observes fleet-level pressure and can reduce admission or autonomy without modifying the hard envelope.

Signals include:

- semantic verification latency/error rate;
- approval queue age;
- effect commit backlog;
- rollback rate;
- containment rate;
- model-specific drift distributions;
- store/ledger health;
- sandbox capacity.

Possible responses:

```text
accept normally
→ admit read-only episodes only
→ reduce concurrency
→ force Class 2+ yielding
→ quarantine a model/provider version
→ refuse new autonomous episodes
```

The regulator is a circuit breaker for *population-level semantic instability*, while episode Homeostats operate locally.
