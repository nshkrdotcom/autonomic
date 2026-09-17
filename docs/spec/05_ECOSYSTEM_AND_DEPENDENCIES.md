# 05 — Ecosystem and Dependencies

## 1. Runtime baseline

Reference implementation baseline (dated 2026-09-16):

- Elixir `~> 1.20`
- Erlang/OTP 29.x, with OTP 29.1 current on the docset date
- Linux kernel 6.x with cgroup v2, user/mount/PID/network namespaces, seccomp, overlayfs and `pidfd` support
- PostgreSQL 16+ (17+ recommended where operationally available)

Architectural floor for later compatibility work may be lower, but the first implementation SHOULD target current BEAM rather than artificially constrain itself to Elixir 1.17/OTP 27.

## 2. Why an umbrella

The repository should be a normal Mix umbrella so trust boundaries are visible in dependency direction.

```text
autonomic_kernel/
├── apps/
│   ├── autonomic_kernel/
│   │   ├── lib/autonomic/
│   │   │   ├── application.ex
│   │   │   ├── episode_controller.ex
│   │   │   ├── episode_supervisor.ex
│   │   │   ├── episode_dynamic_supervisor.ex
│   │   │   ├── authority_governor.ex
│   │   │   ├── homeostat.ex
│   │   │   ├── effect_broker.ex
│   │   │   ├── effect_journal.ex
│   │   │   ├── snapshot_manager.ex
│   │   │   ├── repair_manager.ex
│   │   │   ├── system_regulator.ex
│   │   │   ├── execution_domain.ex
│   │   │   ├── semantic_sensor.ex
│   │   │   ├── effect_adapter.ex
│   │   │   └── contracts/
│   │   └── test/
│   ├── autonomic_linux/
│   │   ├── lib/autonomic_linux/
│   │   │   ├── execution_domain.ex
│   │   │   ├── launcher_port.ex
│   │   │   ├── domain_server.ex
│   │   │   ├── cgroup.ex
│   │   │   ├── observation_source.ex
│   │   │   └── profile.ex
│   │   ├── priv/autonomic_launcher
│   │   └── test/
│   ├── autonomic_typesafe/
│   │   ├── lib/autonomic_typesafe/
│   │   │   ├── sensor.ex
│   │   │   ├── question_bank.ex
│   │   │   ├── window.ex
│   │   │   ├── redaction.ex
│   │   │   └── observation_decoder.ex
│   │   └── test/
│   └── autonomic_store/
│       ├── lib/autonomic_store/
│       │   ├── repo.ex
│       │   ├── store.ex
│       │   ├── ledger.ex
│       │   └── schemas/
│       ├── priv/repo/migrations/
│       └── test/
├── native/
│   └── autonomic_launcher/
│       ├── Cargo.toml
│       └── src/
├── integration/
│   ├── fixtures/
│   └── scenarios/
├── scripts/
├── config/
├── mix.exs
├── README.md
└── HANDOFF.md
```

### Dependency direction

```text
autonomic_kernel   ← autonomic_linux
autonomic_kernel   ← autonomic_typesafe
autonomic_kernel   ← autonomic_store
```

The trusted core defines behaviours. Concrete adapters depend on the core, not the reverse. Runtime configuration injects implementations.

## 3. Mix dependency set

### `apps/autonomic_kernel`

Recommended dependencies:

```elixir
[
  {:jason, "~> 1.4.5"},
  {:telemetry, "~> 1.4"},
  {:gen_stage, "~> 1.3"},
  {:nimble_options, "~> 1.1"}
]
```

Rationale:

- `jason` — bounded JSON for broker/launcher/public telemetry payloads. Never deserialize arbitrary Erlang terms from untrusted user space.
- `telemetry` — standard instrumentation bus; emits metrics without making metrics backend part of kernel logic.
- `gen_stage` — demand-driven observation/approval/verification streams and explicit backpressure. Broadway is intentionally omitted from the initial core because the kernel needs lower-level demand control rather than an ingestion framework; Broadway can be added for external queues later.
- `nimble_options` — validated policy/runtime configuration at trusted boundaries.

OTP primitives used directly:

- `Supervisor`, `DynamicSupervisor`, `Registry`;
- `:gen_statem` for `EpisodeController` and potentially effect state machines;
- `GenServer` for Homeostat/AuthorityGovernor/SystemRegulator;
- `Port` for the launcher protocol;
- `:atomics` only for non-authoritative local counters;
- monitors/links for lifecycle signals;
- `:persistent_term` only for immutable process-wide configuration, never mutable episode authority.

### `apps/autonomic_linux`

```elixir
[
  {:autonomic_kernel, in_umbrella: true},
  {:jason, "~> 1.4.5"},
  {:telemetry, "~> 1.4"}
]
```

The isolation backend SHOULD NOT use a NIF for namespace/seccomp/cgroup control. A crash or memory-safety bug in a NIF shares the BEAM address space. The host launcher is a separate native executable spoken to over a framed Port protocol.

`erlexec` is deliberately **not required in the TCB**. It is a capable third-party OS process manager (2.3.4 was current during docset authoring), but the security model needs one explicit launcher protocol capable of constructing the namespace/cgroup/seccomp envelope before `execve` of the worker. Adding another process-management abstraction does not improve that invariant. If later used for trusted maintenance subprocesses, keep it outside `Autonomic.ExecutionDomain` enforcement.

### `apps/autonomic_typesafe`

```elixir
[
  {:autonomic_kernel, in_umbrella: true},
  {:typesafe_sdk, "~> 0.2.0"}
]
```

During implementation, the attached `typesafe_sdk.xml` is authoritative for the exact package version and public names. This revised docset is grounded to TypeSafeSDK 0.2.0 and the production adapter MUST prefer its strict semantic layer:

- `TypeSafeSDK.new_client/1`;
- `TypeSafeSDK.noul/2`, `choice/3`, `score/3`;
- `TypeSafeSDK.prepare/1` / `prepare!/1`;
- `TypeSafeSDK.evaluate/4` / `evaluate!/4`;
- `TypeSafeSDK.Response` and `TypeSafeSDK.Answer.*`;
- `TypeSafeSDK.RuntimeCapabilities`;
- `TypeSafeSDK.Test` only for deterministic component tests.

The legacy wire-oriented `system_one` API remains useful for SDK parity/compatibility testing but is not the normative kernel adapter path. Do not copy SDK internals or reach directly into generated/Pristine modules.

The supplied TypeSafeSDK 0.2.0 source requires Pristine `~> 0.3.1`. That transport/runtime dependency is owned by the SDK. Autonomic must not add another HTTP stack, retry engine, or TypeSafe-specific Finch client around it. Transport guarantees that the SDK reports as unverified remain unverified until the configured adapter proves them.

TypeSafeSDK 0.3 is **optional**. If the attached package is 0.3+ and provides public semantic-contract fingerprinting, strict response contracts, or request-byte limits, use those actual APIs and remove only equivalent adapter-local compatibility code. Do not make 0.3 a prerequisite and do not invent functions that are absent from the attached source.

If the implementation environment uses a sibling checkout rather than Hex, the **only** accepted local-development variation is a normal Mix path dependency pointing at the real `typesafe_sdk` checkout. Do not vendor a fork into this umbrella.

### `apps/autonomic_store`

```elixir
[
  {:autonomic_kernel, in_umbrella: true},
  {:ecto_sql, "~> 3.14"},
  {:postgrex, "~> 0.22.4"},
  {:jason, "~> 1.4.5"},
  {:telemetry, "~> 1.4"}
]
```

Rationale:

- PostgreSQL provides durable transactional epoch/effect state and row/advisory locking needed for race correctness.
- Ecto gives migrations and explicit transactions without inventing a persistence framework.
- No in-memory persistence is acceptable for production episode authority. Pure in-memory stores may exist only as isolated unit-test subjects for pure contract logic; all system gates use real PostgreSQL.

### Development/test tooling

At umbrella root or per app:

```elixir
[
  {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
  {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
  {:ex_doc, "~> 0.40", only: :dev, runtime: false},
  {:stream_data, "~> 1.2", only: :test},
  {:bypass, "~> 2.1", only: :test}
]
```

`Bypass` is acceptable only for isolated HTTP adapter contract tests. It must not replace live TypeSafe, live Linux isolation, or real PostgreSQL integration gates.

## 4. Native launcher

A minimal Rust launcher is recommended because it provides memory-safe access to Linux syscalls and libseccomp while remaining outside the BEAM VM.

It MUST remain intentionally small. It is not a second orchestration daemon.

Responsibilities:

- namespace creation;
- uid/gid mapping and `no_new_privs`;
- cgroup creation/join before worker exec;
- mount/overlay construction;
- seccomp installation;
- child lifecycle and cgroup kill/freeze/thaw;
- bounded inspection events;
- teardown proof.

Not responsibilities:

- semantic policy;
- capability decisions;
- effect authorization;
- TypeSafe calls;
- human approval;
- durable epoch truth.

The BEAM kernel remains authoritative for all of those.

## 5. Host dependencies

Required production host capabilities:

- Linux kernel 6.x;
- unified cgroup v2 mounted and a delegated subtree for the service;
- user namespaces enabled according to deployment security policy;
- overlayfs;
- seccomp with `libseccomp` 2.6.x family (2.6.1 current during docset authoring);
- capability to create required namespaces/mounts/cgroups without giving the worker those capabilities;
- PostgreSQL;
- CA certificate bundle for trusted broker egress.

Optional/alternative backend tools:

- `bubblewrap` 0.12.x is useful for development/reference isolation and fixture validation, but the reference production backend must prove the same invariant set through the launcher;
- Firecracker 1.17.x is the planned stronger microVM backend for multi-tenant/hostile workloads; its own documentation stresses that safe multi-tenant use depends on correctly configured host security;
- eBPF tooling/auditd may improve deterministic observation but is not the sole enforcement mechanism.

## 6. Release topology

First production release is a single BEAM release per node with the four umbrella apps and one launcher binary installed adjacent to release `priv` assets.

The Postgres database may be shared by a small trusted cluster. Episode ownership uses lease/heartbeat semantics so only one node drives an episode controller at a time. EffectBroker commit paths always consult durable epoch/effect state and therefore remain correct across node failover.

Do not start with a distributed BEAM cluster requirement merely because BEAM supports distribution. First prove single-node kernel semantics with durable failover-safe state; then add clustered episode ownership.

## 7. Configuration philosophy

- no runtime authority from arbitrary environment variables inside episode code;
- materialize application configuration at release boot;
- secret values live in the trusted broker/secret provider, not sandbox env unless the signed policy explicitly allows a bounded ephemeral credential;
- configuration affecting hard envelopes is versioned as signed policy and referenced by hash/version in every episode.

## 8. Observability

Telemetry event families:

```text
[:autonomic, :episode, ...]
[:autonomic, :domain, ...]
[:autonomic, :authority, ...]
[:autonomic, :homeostat, ...]
[:autonomic, :effect, ...]
[:autonomic, :sensor, ...]
[:autonomic, :regulator, ...]
[:autonomic, :store, ...]
```

Never emit raw credentials, full environment maps, hidden model reasoning, or unrestricted source content as metrics metadata.
