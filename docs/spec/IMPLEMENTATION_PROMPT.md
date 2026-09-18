# Complete Implementation Prompt

You are a Principal Distributed Systems Engineer, BEAM/OTP Kernel Engineer, and Linux Isolation Engineer.

Three artifacts are authoritative inputs for semantic integration:

1. **`autonomic_kernel_docset_revised_2026-09-17.zip`** — the complete architecture, contracts, threat model, persistence protocol, testing strategy, implementation sequence, and acceptance gates for the BEAM Autonomic Agent Runtime.
2. **`typesafe_sdk.xml`** — the production **TypeSafeSDK 0.4.0** source representation. Use its strict semantic API, Prepared fingerprints, exact request budgets, response contracts, stable metadata, runtime capabilities, test seam and bounded OTP server.
3. **`pristine_sdk.xml`** — the matching **Pristine 0.4.0** runtime source used to verify the transport/cancellation contract exposed through TypeSafeSDK. Do not build a second semantic HTTP/retry/cancellation stack in Autonomic.

Your task is to build the complete repository **from scratch** as an Elixir umbrella named `autonomic_kernel`, implementing the docset as the normative specification. Do not stop at scaffolding, interfaces, a demo, or a smoke test. Build the real system as far as the execution environment permits, including all source, migrations, native launcher, tests, scripts, documentation, and handoff material.

## First actions

1. Unzip and read **every file** in `autonomic_kernel_docset_revised_2026-09-17.zip`, beginning with `README.md`, then the architecture, subsystem specs, contracts, transaction protocol, threat model, durability design, test plan, implementation plan, and acceptance gates.
2. Inspect `typesafe_sdk.xml` and verify the TypeSafeSDK 0.4.0 public surface: `new_client`, strict `noul/choice/score`, `prepare`, `Prepared.fingerprint`, `evaluate`, response contracts, exact request budgets, response/answer helpers, `Response.metadata`, `OTP.Server`, `Test`, `RuntimeCapabilities`, telemetry and timeout/retry behavior.
3. Inspect `pristine_sdk.xml` only to verify the runtime contract TypeSafe exposes, especially unary cancellation/cancellation cleanup. Do not couple Autonomic to Pristine internals or build transport behavior that belongs below TypeSafe.
3. Create an implementation checklist mapping every normative requirement and every acceptance gate to concrete source files and tests. Keep it in the repository and update it as work progresses.

## Non-negotiable kernel invariants

Every implementation decision must enforce all five invariants:

1. **No Unmediated Irreversible Effects** — untrusted execution domains cannot perform authoritative external mutations directly. Every such effect crosses the transactional `Autonomic.EffectBroker`.
2. **Semantic Evidence Cannot Exceed Deterministic Authority** — TypeSafe/Jev supplies semantic observations only. It may contribute to continuation, contraction, yield, preemption, or policy-authorized decisions, but it cannot override kernel denial, mint hard capabilities, or exceed the signed deterministic envelope.
3. **Authority Is Epoch-Fenced** — every sandbox generation, lease, effect proposal, approval, verifier decision, and commit carries an episode epoch. Epoch advancement is durable and monotonic; stale in-flight authority is rejected mechanically.
4. **Speculation Precedes Commitment** — reversible computation happens optimistically only inside the isolated domain. Class 3/4 effects remain uncommitted until exact-version authorization is revalidated at the commit horizon.
5. **Worker State Is Disposable; Kernel State Is Authoritative** — agent/shell/scratchpad/cgroup/overlay state can be killed. Epoch, policy, trajectory, checkpoint lineage, leases, effect state, and audit history are reconstructed from trusted OTP/durable state.

Do not weaken an invariant to make implementation easier.

## Required repository architecture

Implement the umbrella boundaries described in the docset:

- `apps/autonomic_kernel` — trusted normative OTP control plane;
- `apps/autonomic_linux` — Linux namespace/cgroup/seccomp/overlayfs execution-domain backend and launcher Port client;
- `apps/autonomic_typesafe` — TypeSafe/Jev semantic sensor adapter using the production `typesafe_sdk` package;
- `apps/autonomic_store` — Ecto/PostgreSQL durable authority/ledger implementation;
- `native/autonomic_launcher` — minimal native external launcher process used to establish isolation before the untrusted worker executes.

Keep dependency direction clean: concrete apps depend on core behaviours; core must not depend on Linux, TypeSafe, or Ecto implementation details.

## BEAM/runtime baseline

Target Elixir `~> 1.20` and OTP 29 for the reference build unless the actual environment requires a tightly justified compatibility adjustment. Use OTP supervision and `:gen_statem`/GenServer/Registry/DynamicSupervisor primitives directly where the docset specifies them.

Use `GenStage` for demand-driven sensor/backpressure flow. Do not add Broadway unless a concrete external ingestion need justifies it.

## Linux containment must be real

The first required backend is Linux namespaces + cgroup v2 + seccomp + overlayfs. Firecracker is an architectural backend hook, not a reason to postpone the namespace backend.

The untrusted domain must have:

- separate user/mount/PID/network namespaces;
- cgroup v2 CPU/memory/PID controls;
- no host home/secrets/docker socket/cloud credential mounts;
- read-only immutable base plus disposable writable overlay;
- no routable network;
- seccomp/no-new-privileges restrictions including direct INET/INET6 socket denial according to the specified profile;
- exactly the bounded AF_UNIX broker channel required for mediated effects;
- cgroup-wide kill/freeze/teardown and proof that the old cgroup is empty before successful destruction is reported.

Do not model containment as `git reset --hard`. Git is application state; the OS isolation boundary is authoritative.

The launcher must be an external process spoken to through a bounded, versioned, framed OTP Port protocol. Do not put namespace/seccomp setup in a crash-prone NIF. The launcher must receive argv/data structurally; do not construct shell command strings from untrusted content.

## EffectBroker and commit horizon

Implement the full effect state machine and protocol from `04_EFFECT_TRANSACTION_PROTOCOL.md`:

`proposed → prepared → evaluating → ready → commit_intent → committing → committed`

with `aborted`, `expired`, `stale`, `failed`, and **`commit_unknown`** as specified.

Implement the Class 0–4 effect taxonomy exactly and enforce it in policy/tests.

For Class 3/4:

- durable effect proposal;
- epoch/lease/policy/snapshot/trajectory version vector;
- exact payload digest/revision binding;
- required semantic/slow/human decisions;
- durable commit intent **before** external mutation;
- target idempotency or compare-and-swap where available;
- reconciliation after crash;
- no blind retry of an unresolved ambiguous Class 4 commit.

All privileged commit paths must reread/check the current durable epoch. In-memory messages/caches are not sufficient fencing.

## Mediated network

Do not give the sandbox arbitrary network and then “monitor” it. Make direct routable network mechanically unavailable.

Implement brokered external HTTP/effect access through the per-episode Unix-domain socket. The trusted broker owns DNS, TLS, redirects, allowlists, methods, body limits, credentials, rate limiting, idempotency, and response materialization.

## Durable authority

Use real PostgreSQL through Ecto/Postgrex for the authoritative store. Implement the schema and transaction model in `08_DURABILITY_LEDGER_AND_RECOVERY.md`.

Epoch advancement and effect commit paths must use a single documented lock order and survive actual concurrent race tests.

Do not substitute an in-memory map, DETS, or test fake for the production authority path.

## TypeSafe/Jev semantic supervision

Use `12_TYPESAFE_SDK_INTEGRATION.md` as the normative adapter contract. The only supported semantic baseline is **TypeSafeSDK 0.4.0**. This repository is greenfield; do not add compatibility branches, shims or fallbacks for TypeSafeSDK 0.2/0.3.

The semantic adapter must:

- integrate only through the attached SDK's real public semantic API;
- define one declarative sensor-bank source for scope drift, authority escalation, evidence sufficiency, irreversibility and trajectory regime;
- prepare the bank once and use native `TypeSafeSDK.Prepared.fingerprint/1` as the semantic-contract ID;
- redact secrets and enforce the independent Autonomic evidence-window budget before the SDK boundary;
- configure TypeSafe `max_request_bytes:` for the exact final serialized request;
- configure an SDK response contract for unexpected answer IDs and exact allowed-model policy;
- reject a future answer type under any required requested sensor key as unavailable/degraded, never safe;
- execute through `TypeSafeSDK.OTP.Server` using the package-owned `Autonomic.Typesafe.Tasks` and finite `max_in_flight`, rather than blocking the bank GenServer on HTTP;
- keep retries disabled by default and use SDK/Pristine timeout semantics rather than a local retry loop;
- normalize through `TypeSafeSDK.Response`, `Response.metadata/1` and `TypeSafeSDK.Answer.*`;
- preserve SDK version, requested/actual model, request ID, usage, retries, timing, sensor-bank version and Prepared fingerprint;
- require `:unary_cancellation` and `:cancellation_cleanup` through `TypeSafeSDK.RuntimeCapabilities`;
- use TypeSafe 0.4 privacy-safe evaluation/per-answer telemetry rather than duplicating it;
- use `TypeSafeSDK.Test` for deterministic component tests while retaining a separate mandatory live TypeSafe gate; and
- keep GenStage/SystemRegulator backpressure and every authority decision in Autonomic.

Do not use `TypeSafeSDK.Response.values/1` as the production normalization layer because Autonomic needs distributions/confidence/rubrics. Do not use `TypeSafeSDK.Batch` as a replacement for kernel backpressure. Do not call the legacy wire-oriented `system_one` path.

The semantic request state contains only observable evidence: user-visible/structured generation, tool-call deltas, stdout/stderr windows, diff summaries, deterministic facts, effect proposals, and declared plans/summaries actually emitted by the worker. Do **not** depend on hidden chain-of-thought.

TypeSafe/Jev remains a sensor, not a root of trust. SDK validation establishes request/response contract correctness; it does not grant authority.

## Sensor poisoning and precedence

Implement and test the precedence lattice:

`Kernel Denial ≻ Capability Violation ≻ Deterministic Invariant ≻ Signed Policy ≻ Human Authority ≻ Semantic Observation`

This is dominance, not weighted voting. A semantic “safe” result cannot cancel a deterministic boundary violation.

Create a hostile repository fixture containing indirect prompt-injection text designed to trick the semantic sensor. Then make the worker attempt forbidden secret access/direct networking. The OS boundary must deny it, deterministic evidence must dominate, the episode must preempt/rollback according to policy, and a stale old-epoch effect must remain impossible.

## Homeostat and trajectory

Implement the living `HomeostaticState`, temporal smoothing/hysteresis, budgets, trajectory versioning, regime transitions, and typed negative control outputs from the docset.

Hard deterministic violations bypass smoothing.

Fast semantic supervision may continue, throttle, narrow, revoke, yield, or interrupt. It must not spontaneously expand the hard authority envelope.

## Snapshot/repair

Implement real checkpoint metadata plus actual sandbox filesystem-generation handling. A rollback must:

- fence/advance epoch as required;
- kill the entire old cgroup and prove it empty;
- discard old mutable layer;
- stale/abort old uncommitted effects;
- restore a new domain generation from the last compatible stable checkpoint;
- build a minimal repair context from trusted evidence rather than blindly replaying contaminated scratchpad;
- mint a new policy-valid lease;
- record recovery lineage.

## System regulator and backpressure

Implement cluster/node-wide pressure aggregation and modes described in the docset. Verification/approval/semantic saturation must propagate upstream as admission/concurrency pressure. Sensitive effects must yield rather than bypass required verification.

## Coding-agent reference scenario

Implement the end-to-end acceptance scenario from `06_REFERENCE_IMPLEMENTATION_AND_SCENARIO.md` using a real fixture repository:

`Fix the failing test in test/auth_test.exs without changing test fixtures or secrets.`

Required variants:

1. normal repair and verified authoritative Git commit;
2. violation attempt (`~/.env`/direct networking) → deterministic tripwire → epoch advancement → cgroup kill → overlay discard → checkpoint restore → repaired epoch-2 run → verified authoritative Git commit.

The authoritative repository must not simply be mounted writable into the worker.

## Testing discipline

Use TDD to the maximum extent possible. Do not declare completion based on mocks, fakes, dummy backends, or smoke-only milestones.

Required real gates include:

- real PostgreSQL concurrency/race tests;
- real Linux namespace/cgroup/seccomp/overlay tests;
- real AF_UNIX EffectBroker path;
- real local Git target for authoritative commit/reconciliation;
- stale-epoch race tests with deterministic synchronization barriers;
- old-process/fork cleanup tests;
- overlay rollback verification;
- sensor-poisoning test;
- semantic outage/degradation test;
- broker crash after external mutation / reconciliation test;
- backpressure/load test;
- **live TypeSafe `evaluate/4` integration gate** using the production strict semantic API when credentials/network are available; record non-secret SDK/model/request/usage/retry/timing provenance and the sensor contract id.

A mandatory gate that cannot execute in your environment may be marked pending in `HANDOFF.md`, but you must still build the complete implementation and exact runnable test harness for the next environment. Do not silently replace a missing real gate with a fake and call it verified.

## QC

The repository must finish with a root QC command/alias that runs, as applicable:

- format check;
- compile with warnings as errors;
- full ExUnit;
- Credo strict;
- Dialyzer;
- docs warnings as errors;
- Rust launcher format/clippy/tests;
- PostgreSQL integration gates;
- Linux containment gates;
- conformance report generation.

Generate `artifacts/conformance_report.json` with actual environment versions and gate outcomes as specified.

## Documentation and handoff

Write/maintain repository documentation for:

- architecture and five invariants;
- threat model;
- host provisioning and preflight;
- execution-domain backend protocol;
- policy/capability semantics;
- effect adapter authoring;
- TypeSafe 0.4 sensor authoring/calibration, Prepared fingerprinting, response contracts, exact request budgets, bounded OTP execution and model/contract drift handling;
- persistence/migrations/recovery;
- testing/conformance;
- operator runbooks for `commit_unknown`, semantic outage, DB outage, and suspected sandbox escape.

Create `HANDOFF.md` at the end containing:

- what is fully implemented;
- exact tests/gates run with results;
- environment versions;
- live integrations actually exercised;
- any remaining blocked gate and the exact command to run next;
- no claims that an unexecuted gate passed.

## Git discipline

Work in coherent commits. At the end, commit the complete implementation and documentation. If a writable configured remote exists, push the implementation branch. Otherwise record the final commit SHA and clean/dirty status in `HANDOFF.md`.

## Completion definition

`11_ACCEPTANCE_GATES.md` is the completion contract. Do not redefine the project downward. Do not stop after a proof of concept. The objective is the full production-grade first implementation of the BEAM Autonomic Agent Runtime, with the Linux coding-agent vertical slice actually exercising the kernel semantics.
