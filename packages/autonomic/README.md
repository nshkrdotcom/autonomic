<p align="center">
  <img src="assets/autonomic.svg" alt="Autonomic Logo" width="200" height="200">
</p>

# autonomic

<p align="center">
  <a href="https://github.com/nshkrdotcom/autonomic"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fautonomic-24292e?logo=github" alt="GitHub"/></a>
  <a href="https://hex.pm/packages/autonomic"><img src="https://img.shields.io/hexpm/v/autonomic.svg" alt="Hex.pm"/></a>
  <a href="https://hexdocs.pm/autonomic"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
</p>

The foundational, implementation-independent BEAM/OTP control plane for the Autonomic Kernel architecture.

---

## What is this package?

`autonomic` provides the core runtime, authority governor, effect broker, homeostatic regulator, episode lifecycle supervisor, and normative contracts for running untrusted coding workers inside disposable execution domains while keeping durable authority in a trusted control plane.

## When should I install it?

Install `autonomic` if you are:
- Building an autonomous coding workflow with BEAM/OTP.
- Implementing a custom execution domain backend (extending `Autonomic.ExecutionDomain`).
- Implementing a custom authority or persistence store (extending `Autonomic.Store`).
- Implementing custom semantic sensor banks (extending `Autonomic.SemanticSensor`).
- Authoring custom effect adapters (extending `Autonomic.EffectAdapter`).

If you need a turnkey execution stack on Ubuntu/Linux with PostgreSQL and TypeSafe sensors, combine `autonomic` with:
- [`autonomic_linux`](https://hex.pm/packages/autonomic_linux) — Linux cgroup v2, namespace, and seccomp isolation domain.
- [`autonomic_postgres`](https://hex.pm/packages/autonomic_postgres) — PostgreSQL durable authority store and ledger.
- [`autonomic_typesafe`](https://hex.pm/packages/autonomic_typesafe) — TypeSafe/Jev semantic sensor bank.

## What does it depend on?

`autonomic` has **zero dependencies** on Linux, PostgreSQL, Ecto, or TypeSafeSDK. It depends strictly on standard BEAM utilities:
- `finch` (~> 0.23)
- `jason` (~> 1.4)
- `gen_stage` (~> 1.3)
- `telemetry` (~> 1.3)

## Installation

Add `autonomic` to your `mix.exs`:

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"}
  ]
end
```

For the full official stack, the **application** opts into all three adapters explicitly:

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_linux, "~> 0.1.0"},
    {:autonomic_postgres, "~> 0.1.0"},
    {:autonomic_typesafe, "~> 0.1.0"}
  ]
end
```

This does not make the adapters dependencies of `autonomic`. The dependency direction is the reverse: each adapter depends on core, and applications choose which adapters to install.

## How do I configure it?

Configure the runtime implementations and effect adapters in your `config/config.exs`:

```elixir
config :autonomic,
  store: Autonomic.Store.Postgres,
  domain_backend: Autonomic.Linux.Backend,
  sensor: Autonomic.Typesafe.Sensor,
  state_dir: "/var/lib/autonomic/kernel",
  effect_concurrency: 8,
  sensor_queue: 64,
  speculation_ms: 15_000,
  max_repairs: 3
```

## TypeSafe-centered reference runtime

The core package is adapter-neutral, but the repository's reference semantic path is TypeSafe-centered. With `sensor: Autonomic.Typesafe.Sensor`, observable worker/effect state is evaluated by a fixed prepared TypeSafe bank and returned as typed `Autonomic.SemanticObservation` values.

Those observations are not decorative telemetry:

```text
TypeSafe semantic bank
  |
  +--> Homeostat -> temporal drift/uncertainty/authority/destructive pressure
  |                 -> continue / yield / narrow / preempt
  |
  `--> EffectBroker -> semantic decision for an exact effect revision
                      -> allow / deny as one required decision class
```

The adapter preserves Noul/Score/Choice distributions, confidence, ranking/margins, actual/requested model, request ID, TypeSafeSDK version, bank version, Prepared fingerprint, usage, retries, and latency. Core policy then interprets that evidence conservatively; it does not treat the semantic model as authority.

See [TypeSafe Control Loop](guides/05-typesafe-control-loop.md) for the exact core consumption path and current policy limitations.

## What public modules and concepts does it own?

- **Core & Lifecycle**: `Autonomic.Application`, `Autonomic.EpisodeSupervisor`, `Autonomic.EpisodeController`, `Autonomic.EpisodeSpec`, `Autonomic.Runtime`, `Autonomic.SystemRegulator`.
- **Authority & Policy**: `Autonomic.AuthorityGovernor`, `Autonomic.Policy`, `Autonomic.Capability`, `Autonomic.CapabilityLease`, `Autonomic.HumanApproval`, `Autonomic.VersionVector`.
- **Effect Broker & Adapters**: `Autonomic.EffectBroker`, `Autonomic.EffectSocket`, `Autonomic.EffectState`, `Autonomic.EffectAdapter`, `Autonomic.Adapters.Git`, `Autonomic.Adapters.GitRemote`, `Autonomic.Adapters.HTTP`, `Autonomic.Adapters.Artifact`.
- **Homeostasis & Sensors**: `Autonomic.Homeostat`, `Autonomic.HomeostaticState`, `Autonomic.SensorArray`, `Autonomic.SemanticSensor`, `Autonomic.Trajectory`.
- **Verification & Repair**: `Autonomic.Verifier`, `Autonomic.VerificationRunner`, `Autonomic.RepairManager`, `Autonomic.SnapshotManager`.
- **Contracts**: `Autonomic.Contracts`, `Autonomic.Canonical`, `Autonomic.Payloads`.
- **Extension Behaviours**: `Autonomic.Store`, `Autonomic.ExecutionDomain`, `Autonomic.SemanticSensor`, `Autonomic.EffectAdapter`.

## How does it fit into Autonomic?

`autonomic` is the central hub of the dependency graph:

```text
       autonomic_linux   autonomic_postgres   autonomic_typesafe
              │                  │                   │
              └──────────────────┼───────────────────┘
                                 ▼
                      ┌─────────────────────┐
                      │      autonomic      │
                      │                     │
                      │ kernel semantics    │
                      │ EffectBroker        │
                      │ episode lifecycle   │
                      │ policy/capability   │
                      │ Store behaviour     │
                      │ Exec behaviour      │
                      │ Sensor behaviour    │
                      └─────────────────────┘
```

The arrows above are Mix dependency arrows: adapter → core. Runtime calls flow through core behaviours into the configured implementation, but package ownership remains one-way.

## Where are the full system docs?

See the repository root at [GitHub](https://github.com/nshkrdotcom/autonomic), [HexDocs](https://hexdocs.pm/autonomic), and the repository [package-composition guide](https://github.com/nshkrdotcom/autonomic/blob/main/docs/PACKAGE_COMPOSITION.md).
