# 10 — Implementation Plan

The implementation sequence is dependency-ordered. Each phase produces production code used by later phases; there are no throwaway smoke apps.

## Phase 0 — Repository and contracts

Build the umbrella and copy/split the contracts in `03_INTERFACES_AND_SCHEMAS.ex` into final modules.

Deliver:

- umbrella applications and dependency direction;
- configuration schema;
- IDs/time abstractions;
- policy/effect/lease/checkpoint/trajectory structs;
- behaviours for Store, ExecutionDomain, SemanticSensor and EffectAdapter;
- formatter/Credo/Dialyzer/docs configuration;
- root `mix ci` alias.

Tests first:

- schema and validation tests;
- sensory precedence tests;
- effect-class ordering;
- version-vector comparison.

Exit: compile warnings-as-errors, unit suite green.

## Phase 1 — Durable authority store

Implement `autonomic_store` with real PostgreSQL migrations and Ecto.

Deliver:

- episode create/load;
- append-only episode events;
- checkpoint records;
- lease persistence;
- effect state transitions;
- epoch advancement transaction;
- owner lease fields/API;
- reconciliation queries for nonterminal commits.

Tests first:

- concurrent epoch bumps;
- stale lease queries;
- effect transition constraints;
- lock-order concurrency.

Exit: PostgreSQL integration suite green under repeated concurrent runs.

## Phase 2 — AuthorityGovernor and EpisodeController

Implement the trusted lifecycle before launching any real agent.

Deliver:

- `EpisodeController` as `:gen_statem`;
- `EpisodeSupervisor` and dynamic supervisor;
- `AuthorityGovernor`;
- monotonic epoch bump workflow;
- typed semantic exit mapping;
- repair/containment state transitions;
- durable reconstruction after controller crash.

Tests first:

- transition table;
- repeated repair threshold;
- controller crash recovery;
- epoch invalidation publication.

Exit: OTP concurrency gates green.

## Phase 3 — Linux execution domain

Implement the real containment boundary and minimal native launcher.

Deliver launcher first with a versioned framed protocol. Then implement `AutonomicLinux.ExecutionDomain`.

Required mechanisms:

- namespaces;
- cgroup v2;
- overlayfs;
- seccomp/no-new-privileges;
- no routable network;
- AF_UNIX broker channel mount point;
- cgroup freeze/kill/inspection;
- checkpoint/restore of filesystem generation;
- teardown proof.

Do not attach an LLM yet. Use real shell/compiler fixture workloads.

Exit: Linux containment integration gates in `09` all green.

## Phase 4 — EffectBroker and mediated network

Implement the external commit horizon before giving the agent any external capability.

Deliver:

- EffectJournal state machine;
- broker Unix socket protocol;
- payload content-addressing;
- lease/epoch checks;
- prepare/evaluate/commit/abort;
- commit intent and ambiguity recovery;
- HTTP read adapter;
- authoritative Git commit adapter;
- target-specific reconciliation.

Tests first:

- stale epoch race both orderings;
- payload revision invalidates approval;
- broker crash after target mutation;
- direct network remains impossible while brokered HTTP succeeds.

Exit: real local target integration green.

## Phase 5 — Deterministic SensorArray and Homeostat

Implement normalized observation frames without TypeSafe first so the semantic model is not secretly carrying deterministic responsibilities.

Deliver:

- launcher/domain events;
- resource frames;
- effect proposal frames;
- observation sequencing;
- GenStage demand/backpressure;
- Homeostat temporal state/hysteresis;
- hard-violation dominance;
- regime transitions and controller signals.

Exit: poisoning-independent deterministic containment works.

## Phase 6 — TypeSafe/Jev semantic sensors

Ground the adapter against TypeSafeSDK 0.4.0. This is a greenfield baseline; do not preserve 0.2/0.3 compatibility code.

Deliver:

- `Autonomic.Typesafe.Sensor` implementing `Autonomic.SemanticSensor`;
- one declarative sensor-bank source covering scope drift, authority escalation, evidence sufficiency, irreversibility and regime;
- one reusable `TypeSafeSDK.Prepared` and native `Prepared.fingerprint/1` contract identity;
- bounded observable-window construction and secret redaction;
- exact TypeSafe `max_request_bytes:` enforcement for the final serialized request;
- SDK `response_contract` enforcement for unexpected answer IDs and exact allowed-model policy;
- explicit rejection of a future answer type under any required sensor key;
- `TypeSafeSDK.OTP.Server` using the package-owned `Autonomic.Typesafe.Tasks` and finite `max_in_flight`;
- fast/slow SDK timeout policy with retries disabled by default;
- response normalization through `TypeSafeSDK.Response`, `Response.metadata/1` and `TypeSafeSDK.Answer.*`;
- SDK/request/model/usage/retry/timing/sensor-bank/fingerprint provenance on `SemanticObservation`;
- semantic service/contract health state;
- fail-closed `TypeSafeSDK.RuntimeCapabilities` requirements for unary cancellation and cancellation cleanup;
- deterministic tests through `TypeSafeSDK.Test`, including request budget, response contract, blocked-request bank responsiveness and max-in-flight overload; and
- a separate mandatory live gate with non-secret provenance.

Do not implement a second TypeSafe HTTP client, retry engine, semantic response validator, ranking/margin/score helper layer, local Prepared hash, approximate whole-request size estimator, package-global TypeSafe supervisor or compatibility shim. `TypeSafeSDK.Batch` does not replace kernel backpressure.

Exit:

- deterministic TypeSafe adapter tests green through the SDK test seam;
- mandatory live gate recorded with provenance;
- request-budget/model-contract/unknown-answer/outage/overload paths fail closed;
- deterministic rules still dominate a semantic `safe` result in the poisoning test.

## Phase 7 — Snapshot and repair

Deliver:

- stable checkpoint selection;
- epoch-fenced rollback;
- domain destruction/recreation;
- scratchpad/context decontamination policy;
- repair context from authoritative evidence;
- narrower restart lease;
- recovery lineage.

Exit: end-to-end violation → epoch bump → cgroup kill → overlay discard → restore → repaired run test green.

## Phase 8 — Slow verifier and approval horizon

Define verifier/approval records as independent signed/attributed decisions.

Deliver:

- slow verifier behaviour and reference implementation;
- human approval API/storage surface (CLI/admin API is sufficient; UI not required);
- decision expiry;
- exact effect revision binding;
- structural `:yielding` state for sensitive commits.

Do not let the agent self-approve by emitting text.

Exit: Class 3/4 cannot commit without required decisions; revision change invalidates them.

## Phase 9 — SystemRegulator and fleet pressure

Deliver:

- pressure aggregation;
- admission modes;
- semantic service circuit breaker;
- model-version quarantine controls;
- approval/verification backpressure;
- bounded speculation budget.

Exit: load test demonstrates upstream throttling rather than unbounded queues.

## Phase 10 — Coding-agent adapter and reference scenario

Only now attach the real coding agent/provider.

The adapter is untrusted and replaceable. It runs inside the execution domain or communicates through a strictly bounded worker protocol, depending on provider CLI/API requirements.

Implement the exact `test/auth_test.exs` scenario from `06_REFERENCE_IMPLEMENTATION_AND_SCENARIO.md` as a real integration/acceptance case.

Exit: full clean run plus violation/repair run both produce durable episode ledgers and the expected authoritative Git commit behavior.

## Phase 11 — Hardening and release

Deliver:

- security review against `07_THREAT_MODEL_AND_SECURITY.md`;
- dependency audit;
- host provisioning/preflight script;
- reproducible launcher build instructions;
- operator runbooks for `commit_unknown`, suspected escape, DB outage, semantic outage;
- `artifacts/conformance_report.json` generation;
- complete README and architecture docs;
- HANDOFF with exact remaining environment-dependent gates, if any.

Exit criteria are exactly `11_ACCEPTANCE_GATES.md`.

## Implementation discipline

For every phase:

1. write failing tests/acceptance fixtures for the actual invariant;
2. implement the real integration, not a mock backend standing in for it;
3. run focused tests;
4. run affected integration tests;
5. run root QC;
6. update docs and handoff;
7. commit a coherent change.

Where the execution environment cannot run a host-level gate, build the complete implementation and test harness anyway, clearly mark that gate pending, and give the next Linux-capable agent exact commands. Do not silently replace it with a weaker proof.
