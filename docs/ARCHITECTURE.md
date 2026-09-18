# Architecture and Kernel Invariants

The normative architecture is in `docs/spec/01_SYSTEM_ARCHITECTURE.md`; this document maps the current repository implementation.

## Four-package reference composition

The repository publishes four separate Mix projects:

```text
                         application composition

                         +-------------+
                         |  autonomic  |
                         | core kernel |
                         +------+------+
                                ^
             +------------------+------------------+
             |                  |                  |
   +---------+---------+ +------+-----------+ +----+----------------+
   | autonomic_linux   | | autonomic_postgres| | autonomic_typesafe |
   | ExecutionDomain   | | Store             | | SemanticSensor     |
   +-------------------+ +--------------------+ +---------------------+
```

The adapters depend on core; core does not depend on them. Runtime composition is selected through configuration.

The TypeSafe-centered reference configuration is:

```elixir
config :autonomic,
  domain_backend: Autonomic.Linux.Backend,
  store: Autonomic.Store.Postgres,
  sensor: Autonomic.Typesafe.Sensor
```

## Trusted and untrusted planes

`Autonomic.EpisodeSupervisor` owns a per-episode rest-for-one tree. The trusted control plane owns authority, effect mediation, sensor ingestion, Homeostat trajectory state, verification orchestration, trusted target configuration, and persistence.

The current `Autonomic.Linux.Backend` executes untrusted workers in local Linux namespace/cgroup/seccomp/OverlayFS containment. The worker receives a broker-owned AF_UNIX socket but no routable network or trusted credentials.

**Current implementation boundary:** the Linux containment and trusted BEAM control plane share the same host kernel. This is not a remote-worker or microVM architecture. Stronger execution isolation can be introduced through a different `Autonomic.ExecutionDomain` implementation without changing the semantic/store contracts.

## Semantic control plane

Observable worker and effect state becomes `Autonomic.ObservationFrame`. The reference semantic adapter:

1. redacts and bounds approved observable state;
2. evaluates one prepared TypeSafe bank;
3. returns five typed `SemanticObservation` values with probability/confidence/provenance;
4. reports semantic health to `SystemRegulator`.

Core consumes those observations in two places:

- `Homeostat` — temporal drift/uncertainty/authority/destructive-pressure regulation;
- `EffectBroker` — semantic allow/deny evidence for an exact effect revision when policy requires it.

See [`TYPESAFE_CONTROL_LOOP.md`](TYPESAFE_CONTROL_LOOP.md).

## Authority flow

1. admission validates an `EpisodeSpec` against the deterministic hard envelope;
2. PostgreSQL establishes the durable episode/epoch;
3. `AuthorityGovernor` issues finite epoch/policy-bound capability leases;
4. Class 0/1 work runs inside the execution domain;
5. Class 2+ work is proposed to `EffectBroker` with payload identity and version vector;
6. required decisions are collected against the exact proposal revision;
7. commit revalidates epoch/lease/policy/trajectory/revision and persists `commit_intent` before external actuation;
8. target outcome becomes committed/failed/unknown and is durably reconciled.

## Precedence

Semantic evidence is intentionally subordinate to deterministic authority:

```text
Kernel denial
  > capability violation
  > deterministic invariant
  > signed policy
  > human authority
  > semantic observation
```

A TypeSafe result can make the system more conservative. It cannot make a forbidden operation legal.

## Trajectory control

Homeostat maintains smoothed drift, volatility, uncertainty, scope pressure, authority pressure, destructive pressure, verification/approval pressure, autonomy balance, and blast-radius budget. Regime changes yield concrete controller behavior. Recovery from risky regimes is hysteretic.

Deterministic hard violations bypass smoothing and enter containment immediately.

## Durability

`autonomic_postgres` persists the authority state required to survive process failure, including observation frames, trajectory state, effect decisions, and recovery lineage. Semantic evidence therefore has audit provenance without becoming the source of truth for authority.

## Backpressure

Sensor ingestion and effect orchestration are bounded. Semantic overload degrades semantic health; broker saturation rejects excess work rather than building unbounded queues. PostgreSQL transactions and version checks—not task scheduling—remain the fencing authority.
