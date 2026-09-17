<p align="center">
  <img src="assets/autonomic.svg" alt="Autonomic Kernel Logo" width="200" height="200">
</p>

# Autonomic Kernel

<p align="center">
  <a href="https://github.com/nshkrdotcom/autonomic"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fautonomic-24292e?logo=github" alt="GitHub"/></a>
  <a href="https://hex.pm/packages/autonomic"><img src="https://img.shields.io/hexpm/v/autonomic.svg" alt="Hex.pm"/></a>
  <a href="https://hexdocs.pm/autonomic"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
</p>

A production-oriented BEAM/OTP autonomy kernel for running untrusted coding workers inside disposable Linux execution domains while maintaining durable authority, policy enforcement, effect brokering, verification recovery, and audit logs in a trusted control plane.

Autonomic is structured as a **Hex-ready Poncho monorepo** comprising four decoupled, independently publishable Mix packages and an internal end-to-end acceptance suite.

---

## Core Invariants

1. **No unmediated irreversible effects**: Class 2+ external mutations cross `Autonomic.EffectBroker`; sandboxed workers operate without routable external networking or authoritative repository mounts.
2. **Semantic evidence cannot exceed deterministic authority**: TypeSafe/Jev is an observation sensor. It cannot mint capabilities, override deterministic boundary violations, or expand signed hard envelopes.
3. **Authority is epoch-fenced**: Leases, execution domains, effect revisions, decisions, checkpoints, and commits bind to a durable episode epoch in PostgreSQL.
4. **Speculation precedes commitment**: Worker filesystem mutations are disposable within an overlayfs upperdir; Class 3/4 effects cross the durable commit horizon only upon exact cryptographic and policy evaluation.
5. **Worker state is disposable; kernel state is authoritative**: Worker processes, cgroups, and overlays may be aborted at any moment. PostgreSQL ledger entries and trusted checkpoint metadata reconstruct the episode.

---

## Package Ecosystem

The repository is organized as independent Mix projects linked via path dependencies for local development and staged as independent versioned Hex packages for publication:

```
autonomic/
├── packages/
│   ├── autonomic/                 # Core OTP control plane, effect broker, homeostat
│   ├── autonomic_linux/           # Linux cgroup v2, namespace, seccomp, overlayfs sandbox & Rust launcher
│   ├── autonomic_postgres/        # PostgreSQL authority governor, Ecto repo, transactional ledger
│   └── autonomic_typesafe/        # TypeSafe/Jev semantic sensor bank, drift detection, evidence redaction
├── integration/
│   └── autonomic_acceptance/      # Cross-package end-to-end acceptance test suite
├── scripts/
│   ├── qc                         # Monorepo test & quality control orchestrator
│   ├── release                    # Deterministic release staging & inspection pipeline
│   ├── lint_package_boundaries.py # Architectural boundary verification tool
│   ├── build_launcher.sh          # Native Rust launcher compilation script
│   ├── preflight.sh               # Host capability checker
│   ├── run_reference.sh           # End-to-end coding agent reference scenario runner
│   └── run_db_outage_gate.sh      # PostgreSQL outage fault-injection gate
└── docs/                          # Comprehensive architectural and operational documentation
```

### Published Hex Packages

| Package | Mix Dependency | Purpose | HexDocs |
| :--- | :--- | :--- | :--- |
| **`autonomic`** | `{:autonomic, "~> 0.1.0"}` | Core OTP kernel, authority governor, effect broker, contracts, homeostat | [Docs](https://hexdocs.pm/autonomic) |
| **`autonomic_linux`** | `{:autonomic_linux, "~> 0.1.0"}` | Linux isolation backend with cgroups v2, namespaces, seccomp, overlayfs, and Rust launcher | [Docs](https://hexdocs.pm/autonomic_linux) |
| **`autonomic_postgres`** | `{:autonomic_postgres, "~> 0.1.0"}` | PostgreSQL Ecto store, epoch fencing, transactional ledger, and authority governor adapter | [Docs](https://hexdocs.pm/autonomic_postgres) |
| **`autonomic_typesafe`** | `{:autonomic_typesafe, "~> 0.1.0"}` | Semantic sensor bank backed by TypeSafe/Jev for evidence budgeting, drift detection, and anomaly scoring | [Docs](https://hexdocs.pm/autonomic_typesafe) |

---

## Downstream Usage

Applications can consume only the packages required for their environment:

```elixir
# mix.exs
defp deps do
  [
    # Core kernel (always required)
    {:autonomic, "~> 0.1.0"},

    # Optional: Linux execution domain isolation
    {:autonomic_linux, "~> 0.1.0"},

    # Optional: Durable PostgreSQL authority store
    {:autonomic_postgres, "~> 0.1.0"},

    # Optional: Semantic sensor bank
    {:autonomic_typesafe, "~> 0.1.0"}
  ]
end
```

---

## Development & Quality Control

Because this is a Poncho monorepo without root umbrella semantics, each project is self-contained. Tooling in `scripts/` coordinates multi-package operations.

### Monorepo Quality Control (`scripts/qc`)

Run the full QC suite (format checks, compilation with warnings-as-errors, unit tests, Credo, Dialyzer, ExDoc, Rust launcher tests, boundary checks, and release inspection):

```bash
# Run QC in handoff mode (records honest pending status for environmental gates):
./scripts/qc --handoff

# Run strict release gating (requires all infrastructure gates to pass):
./scripts/qc --strict

# Target a specific package:
./scripts/qc --package autonomic_postgres
```

### Architectural Boundary Verification

Verify that package boundaries remain clean with zero unauthorized cross-adapter dependencies:

```bash
python3 scripts/lint_package_boundaries.py
```

### Deterministic Release Staging (`scripts/release`)

Autonomic packages are prepared for Hex via a staging pipeline that rewrites local path dependencies into versioned Hex dependencies:

```bash
# Pre-flight boundary and metadata check:
./scripts/release check

# Stage packages for version 0.1.0:
./scripts/release stage 0.1.0

# Build Hex package tarballs (.tar):
./scripts/release build 0.1.0

# Unpack and audit package tarballs for release cleanliness:
./scripts/release inspect 0.1.0
```

---

## Verification Tiers

To run individual package test suites:

```bash
# Core kernel tests
cd packages/autonomic && mix test

# Linux isolation backend tests
cd packages/autonomic_linux && mix test

# PostgreSQL store tests (requires running PostgreSQL)
cd packages/autonomic_postgres
MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo || true
MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo
mix test test/integration --include postgres

# Semantic sensor tests
cd packages/autonomic_typesafe && mix test

# Acceptance integration suite (cross-package)
cd integration/autonomic_acceptance && mix test
```

---

## Documentation

- [Poncho Migration Guide](docs/PONCHO_MIGRATION.md)
- [Poncho Implementation Checklist](docs/PONCHO_IMPLEMENTATION_CHECKLIST.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Security Model](docs/SECURITY.md)
- [Persistence and Recovery](docs/PERSISTENCE_RECOVERY.md)
- [Operations Guide](docs/OPERATIONS.md)
- [Development Guide](docs/DEVELOPMENT.md)

---

## License

MIT. See `LICENSE`.
