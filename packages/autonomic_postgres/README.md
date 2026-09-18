<p align="center">
  <img src="assets/autonomic_postgres.svg" alt="Autonomic Postgres Logo" width="200" height="200">
</p>

# autonomic_postgres

<p align="center">
  <a href="https://github.com/nshkrdotcom/autonomic"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fautonomic-24292e?logo=github" alt="GitHub"/></a>
  <a href="https://hex.pm/packages/autonomic_postgres"><img src="https://img.shields.io/hexpm/v/autonomic_postgres.svg" alt="Hex.pm"/></a>
  <a href="https://hexdocs.pm/autonomic_postgres"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
</p>

PostgreSQL durable authority store and transactional ledger for the Autonomic Kernel.

---

## What is this package?

`autonomic_postgres` implements the `Autonomic.Store` behaviour using Ecto and PostgreSQL. It maintains the durable authority state, capability leases, effect transaction logs, checkpoints, recovery audit records, and epoch fencing boundaries that allow the BEAM control plane to reconstruct episodes after worker or node restarts.

## When should I install it?

Install `autonomic_postgres` when running an Autonomic Kernel deployment backed by PostgreSQL for durable authority.

## What does it depend on?

- `autonomic` (~> 0.1.0)
- `ecto_sql` (~> 3.13)
- `postgrex` (~> 0.21)
- PostgreSQL 16+ database.

## Installation

Add `autonomic_postgres` to your `mix.exs`:

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_postgres, "~> 0.1.0"}
  ]
end
```

## How do I configure it?

In your `config/config.exs`:

```elixir
config :autonomic,
  store: Autonomic.Store.Postgres

config :autonomic_postgres,
  ecto_repos: [Autonomic.Store.Repo]

config :autonomic_postgres, Autonomic.Store.Repo,
  url: System.get_env("DATABASE_URL") || "ecto://autonomic:autonomic@localhost/autonomic_prod",
  pool_size: 10
```

Run database migrations:

```bash
mix ecto.migrate -r Autonomic.Store.Repo
```

## Durable Authority & Transactional Ledger

`autonomic_postgres` provides the durable source of truth for the kernel control plane:
- **Epoch Fencing**: Monotonic episode epochs ensure stale workers and superseded capability leases are rejected atomically.
- **Capability Leases**: Time-bounded, row-locked authority records for worker actions.
- **Effect Horizon**: Multi-phase effect state transitions (`prepared` → `evaluating` → `ready` → `commit_intent` → `committed`), binding commits to exact effect revisions and payload digests.
- **Audit & Recovery**: Immutable event ledger, digest-verified checkpoints, and recovery lineage for deterministic state reconstruction.

All state transitions acquire row locks in a strict hierarchy (`episode` → `effect` → `lease`) to eliminate race conditions and deadlocks.

For schema details and recovery semantics, see [Postgres Authority](guides/01-postgres-authority.md) and [Epoch Fencing and Recovery](guides/03-epoch-fencing-and-recovery.md).

## What public modules and concepts does it own?

- `Autonomic.Store.Postgres` — Implements `Autonomic.Store` callbacks.
- `Autonomic.Store.Repo` — Ecto repository targeting PostgreSQL.
- `Autonomic.Store.Schema.*` — Schemas for episodes, capability leases, checkpoints, effects, effect decisions, events, observation frames, and recovery records.
- `Autonomic.Postgres.Application` — OTP application supervisor managing Repo pool.

## How does it fit into Autonomic?

`autonomic_postgres` is the reference durable authority adapter:

```text
     autonomic_postgres                      other backends
              │                                     │
              └──────────────────┬──────────────────┘
                                 ▼
                      ┌─────────────────────┐
                      │      autonomic      │
                      └─────────────────────┘
```

This package implements `Autonomic.Store` and is configured via `:store` in your application configuration.

## Where are the full system docs?

See the repository root at [GitHub](https://github.com/nshkrdotcom/autonomic) and [HexDocs](https://hexdocs.pm/autonomic_postgres).
