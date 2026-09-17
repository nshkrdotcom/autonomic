# Development and testing

## Toolchain

`.tool-versions` pins Elixir 1.20.4 / OTP 29.0.6 and Rust 1.90.0. PostgreSQL is a real integration dependency. Do not replace the authority store, Linux backend or semantic SDK with dummy production implementations to make tests easier.

## Setup

```bash
mix deps.get
MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo
MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo
cargo build --release --manifest-path native/autonomic_launcher/Cargo.toml
```

For Linux gates set `AUTONOMIC_LINUX=1`, `AUTONOMIC_ROOTFS`, `AUTONOMIC_LINUX_STATE_ROOT`, and optionally `AUTONOMIC_NO_SUDO=1` when already root.

## Test strata

- Pure/component: `mix test`
- Store/race/reconciliation/AF_UNIX: `mix test apps/autonomic_store/test/integration --include postgres --exclude linux --exclude reference`
- Linux isolation: `AUTONOMIC_LINUX=1 mix test apps/autonomic_linux/test/integration --include linux`
- Coding-agent normal + hostile reference: `AUTONOMIC_LINUX=1 mix test apps/autonomic_store/test/reference --include reference --include postgres --include linux`
- Live semantic: `TYPESAFE_API_KEY=... mix test apps/autonomic_typesafe/test/live_gate_test.exs --include live`

## QC

`mix qc` invokes `scripts/qc.py --strict`. `python3 scripts/qc.py --handoff` is only for creating an honest continuation report on a host that lacks mandatory dependencies; it never sets `release_ready=true` when gates are skipped.

The test fixture under `test/fixtures/coding_agent` deliberately contains hostile prompt-injection text. It is inert test data, not an instruction to the implementation agent.

## CI tiers

`.github/workflows/ci.yml` runs the non-privileged BEAM/PostgreSQL and Rust quality gates. Linux containment is intentionally separated into `privileged-linux.yml`, which only runs on an operator-controlled runner labeled `autonomic-privileged`; hosted CI is not treated as proof of cgroup/namespace/seccomp behavior. `live-typesafe.yml` is manual and additionally requires `TYPESAFE_LIVE_ENABLED=true` plus the `TYPESAFE_API_KEY` secret. No workflow substitutes fixtures for either privileged Linux acceptance or the live TypeSafe gate.
