# BEAM Autonomic Agent Runtime — Revised Implementation Docset

This archive is the implementation handoff for `autonomic_kernel`, a capability-secure BEAM/OTP execution kernel for probabilistic workers. This revision is dated **2026-09-17** and fixes the semantic-integration baseline at **TypeSafeSDK 0.4.0** with its Pristine 0.4.0 runtime. The codebase is greenfield: earlier TypeSafe releases are not supported and no compatibility shim is part of the architecture.

The runtime treats an LLM/coding agent as an **untrusted user-space program**. The trusted system is the OTP kernel plus its durable ledger, authority state, effect broker, and host-isolation backend. Agent processes and sandboxes are disposable. External effects are mediated, epoch-fenced, and committed only after the required deterministic and semantic checks.

## Normative invariants

Every implementation decision MUST preserve these invariants:

1. **No unmediated irreversible effects.** External mutation crosses `Autonomic.EffectBroker`; untrusted domains have no direct mutating egress.
2. **Semantic evidence cannot exceed deterministic authority.** TypeSafe/Jev may contract or modulate authority inside a hard deterministic envelope, never expand beyond it or override a kernel denial.
3. **Authority is epoch-fenced.** Capability leases, sandboxes, effect proposals, approvals, and commit intents carry a monotonic episode epoch. Epoch advancement invalidates stale authority immediately.
4. **Speculation precedes commitment.** Reversible work may execute optimistically inside isolation; externally authoritative effects remain uncommitted until the commit protocol clears.
5. **Worker state is disposable; kernel state is authoritative.** Scratchpads, agent processes, cgroups, namespaces, overlays, and microVMs may be killed. Trusted episode state lives in OTP and durable storage.

## Docset map

- `01_SYSTEM_ARCHITECTURE.md` — worldview, trust boundaries, control loops, semantic MVCC, process topology.
- `02_SUBSYSTEM_SPECIFICATIONS.md` — normative subsystem behavior, state machines, messages, crash recovery.
- `03_INTERFACES_AND_SCHEMAS.ex` — self-contained Elixir contracts/types/structs for the core protocol.
- `04_EFFECT_TRANSACTION_PROTOCOL.md` — effect classes, prepare/evaluate/commit/abort, stale-epoch races, mediated egress.
- `05_ECOSYSTEM_AND_DEPENDENCIES.md` — umbrella layout, Mix dependencies, Linux/host prerequisites, release topology.
- `06_REFERENCE_IMPLEMENTATION_AND_SCENARIO.md` — end-to-end coding-agent episode.
- `07_THREAT_MODEL_AND_SECURITY.md` — attacker model, sensor poisoning, isolation, credentials, fail-safe rules.
- `08_DURABILITY_LEDGER_AND_RECOVERY.md` — Postgres data model, event ledger, epoch transactions, ambiguous commit recovery.
- `09_TESTING_AND_CONFORMANCE.md` — TDD strategy and real integration gates, including race and poisoning tests.
- `10_IMPLEMENTATION_PLAN.md` — implementation sequence with exit criteria and no throwaway scaffolding.
- `11_ACCEPTANCE_GATES.md` — final non-negotiable completion gates.
- `SOURCES_AND_VERSION_BASELINE.md` — dated technology baseline and upstream references.
- `REVISION_NOTES_2026-09-17.md` — exact scope of the TypeSafeSDK 0.4 greenfield revision.
- `12_TYPESAFE_SDK_INTEGRATION.md` — normative TypeSafeSDK 0.4.0 adapter contract, provenance, bounded OTP execution and testing strategy.
- `IMPLEMENTATION_PROMPT.md` — exact prompt to accompany this archive and the current TypeSafeSDK 0.4.0 / Pristine 0.4.0 source snapshots.

## Semantic SDK baseline

The implementation targets **TypeSafeSDK 0.4.0** and MUST use the strict semantic layer plus the 0.3/0.4 primitives that are now first-class: Prepared fingerprints, exact request-byte budgets, strict response contracts, stable metadata and `TypeSafeSDK.OTP.Server`. The wire-oriented `system_one` surface is not an Autonomic production path.

TypeSafeSDK owns semantic request construction/validation, Prepared contracts/fingerprints, final request sizing, response contracts/enrichment, retry/timeout plumbing, privacy-oriented evaluation/per-answer telemetry, bounded OTP evaluation, test transport and runtime-capability reporting. Autonomic owns evidence selection/redaction, sensor meaning, semantic health, model/contract consequences, system-level backpressure and all authority decisions.

There is no local fallback for features provided by the 0.4 SDK. Do not add version branches or recreate older behavior.

## Intended repository shape

The implementation is an Elixir umbrella named `autonomic_kernel` with four applications:

```text
autonomic_kernel/
├── apps/
│   ├── autonomic_kernel/      # trusted normative OTP control plane
│   ├── autonomic_linux/       # Linux execution-domain backend + native launcher protocol
│   ├── autonomic_typesafe/    # TypeSafe/Jev semantic sensor adapter
│   └── autonomic_store/       # PostgreSQL persistence and migrations
├── native/
│   └── autonomic_launcher/    # minimal host isolation helper; external process, not a NIF
├── config/
├── integration/
├── scripts/
├── mix.exs
├── README.md
└── HANDOFF.md
```

The architecture keeps the trusted BEAM domain independent of any specific model provider, Linux backend, or storage implementation through explicit behaviours. `autonomic_linux`, `autonomic_typesafe`, and `autonomic_store` implement those behaviours.

## Non-goals for the first implementation

The first implementation is not a general agent framework, prompt library, browser automation suite, or replacement for Kubernetes. It must prove the kernel semantics with a coding-agent workload on Linux. Firecracker is an architectural backend hook and later hardening path; Linux namespaces/cgroup v2/seccomp/overlayfs are the first required executable backend.

The runtime must not depend on hidden model chain-of-thought. It observes only available data: streamed visible output, structured tool-call deltas, declared plans/summaries, stdout/stderr, files/diffs, process and syscall telemetry, effect proposals, and external outcomes.
