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

### 6.1 TypeSafeSDK 0.2 production boundary

The production adapter uses the strict TypeSafeSDK semantic surface, not the legacy wire-oriented System One wrapper. Construct and prepare the sensor bank once during trusted sensor initialization, then reuse the prepared bank across observable windows:

```elixir
prepared =
  TypeSafeSDK.prepare!(
    scope_drift:
      TypeSafeSDK.noul(
        "Has the observable trajectory materially drifted beyond the original coding task?"
      ),
    authority_escalation:
      TypeSafeSDK.noul(
        "Is the worker seeking resources or authority unnecessary for the stated task?"
      ),
    evidence_sufficiency:
      TypeSafeSDK.score(
        "How sufficient is the observable evidence for the proposed action?",
        ["Insufficient", "Partial", "Sufficient"]
      ),
    irreversibility:
      TypeSafeSDK.score(
        "Classify the proposed effect by operational irreversibility.",
        ["Local", "Reversible", "External", "Authoritative", "High-impact"]
      ),
    regime:
      TypeSafeSDK.choice(
        "Classify the current trajectory regime from observable evidence only.",
        stable: "coherent and within scope",
        uncertain: "insufficient evidence or inconsistent intent",
        drifting: "directional deviation from scope",
        unstable: "rapid or severe deviation requiring containment"
      )
  )

{:ok, response} =
  TypeSafeSDK.evaluate(client, sensor_state, prepared,
    retry: false,
    timeout_ms: semantic_timeout_ms,
    telemetry_metadata: %{episode_id: episode_id, sensor_bank: sensor_bank_version}
  )
```

`TypeSafeSDK.Prepared` owns validated question construction/encoding and finite caller-key identity. `TypeSafeSDK.evaluate/4` owns JSON normalization, protected semantic request fields, request execution through the production SDK runtime, request-relative response validation, and enriched answers. `AutonomicTypesafe.Sensor` MUST NOT duplicate those layers.

The adapter reads answers through `TypeSafeSDK.Response` / `TypeSafeSDK.Answer.*`, preserving the actual response model, request id, usage, retry count, elapsed time, probability distributions, and any provider confidence exposed by the SDK. Thresholds remain Autonomic policy and are never treated as SDK safety guarantees.

### 6.2 Fail-closed response interpretation

TypeSafeSDK 0.2 intentionally preserves unknown future answer tags in `unknown_answers`. For this kernel, a required sensor answer that is unknown/missing is **semantic unavailability**, never an implicit negative or `safe` result. The adapter marks sensor health degraded and the Homeostat/SystemRegulator applies the configured uncertainty policy.

The actual response model is provenance, not merely decoration. If policy pins an allowed concrete model set and `response.model` falls outside it, treat that as semantic-contract drift. The SDK detects/returns the model; Autonomic decides whether the episode may continue, yield, require slow verification, or quarantine admission. Do not infer that a different model is intrinsically unsafe.

### 6.3 Semantic contract identity

On TypeSafeSDK 0.2, `autonomic_typesafe` maintains a versioned declarative sensor-bank manifest and computes its own SHA-256 contract id from that manifest before building the SDK questions. Do not hash or inspect private/opaque `Prepared` fields. Persist both the human sensor-bank version and the contract id with semantic evidence.

If a later attached TypeSafeSDK exposes a public prepared-contract fingerprint, prefer that public fingerprint and retain the application sensor-bank version alongside it. A change of semantic question contract invalidates calibration artifacts that were frozen against the prior contract.

### 6.4 Request budgeting

Autonomic owns the bounded observable window and secret redaction. On TypeSafeSDK 0.2, enforce a configured serialized-state budget before `evaluate/4` and reject/trim according to deterministic policy; never silently submit an unbounded accumulated transcript. If a later SDK exposes a native full serialized-request byte limit, configure it as an additional guard rather than removing the kernel evidence-window budget.

See `12_TYPESAFE_SDK_INTEGRATION.md` for the complete normative adapter contract and optional 0.3 migration rules.

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
