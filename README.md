# Autonomic Kernel

A production-oriented BEAM/OTP autonomy kernel for running an untrusted coding worker inside a disposable Linux execution domain while keeping durable authority, policy, effects, verification, recovery, and audit state in a trusted control plane.

The implementation follows five non-negotiable invariants:

1. **No unmediated irreversible effects.** Class 2+ external effects cross `Autonomic.EffectBroker`; the sandbox has no routable network and no authoritative repository mount.
2. **Semantic evidence cannot exceed deterministic authority.** TypeSafe/Jev is a sensor. It cannot mint capabilities, override a deterministic boundary violation, or expand the signed hard envelope.
3. **Authority is epoch-fenced.** Leases, domains, effect revisions, decisions, checkpoints, and commits bind to a durable episode epoch.
4. **Speculation precedes commitment.** Isolated edits/tests are disposable; Class 3/4 mutations cross a durable commit horizon only after exact-version authorization.
5. **Worker state is disposable; kernel state is authoritative.** The worker/cgroup/overlay may be killed. PostgreSQL plus trusted checkpoint metadata reconstruct the episode.

## Repository layout

- `apps/autonomic_kernel` — trusted OTP control plane, policy, leases, Homeostat, EffectBroker, adapters, repair and episode state machine.
- `apps/autonomic_store` — Ecto/PostgreSQL authority store, ledger, migrations, race/reconciliation/reference tests.
- `apps/autonomic_linux` — execution-domain backend and bounded OTP Port client.
- `apps/autonomic_typesafe` — strict TypeSafeSDK 0.2.x sensor bank and live/component gates.
- `native/autonomic_launcher` — privileged external Rust launcher for namespaces, cgroup v2, overlayfs and seccomp.
- `test/fixtures/coding_agent` — normal/hostile coding-agent acceptance fixture.
- `docs/spec` — supplied normative specification; `docs/IMPLEMENTATION_CHECKLIST.md` maps it to implementation/tests.
- `scripts/qc.py` — root QC/conformance runner.

## Required host

Reference target: Ubuntu 24.04+/Omarchy-class Linux with cgroup v2, user/mount/PID/network namespaces, overlayfs, seccomp, PostgreSQL, Git, Elixir 1.20 / OTP 29, and Rust. The launcher is intentionally an external process, not a NIF.

Run:

```bash
sudo bash scripts/provision_host.sh
bash scripts/preflight.sh
mix deps.get
mix ecto.create -r Autonomic.Store.Repo
mix ecto.migrate -r Autonomic.Store.Repo
cargo build --release --manifest-path native/autonomic_launcher/Cargo.toml
mix qc
```

For a source checkout of TypeSafeSDK 0.2.x, set `TYPESAFE_SDK_PATH=/absolute/path/to/typesafe_sdk`; otherwise Mix resolves `typesafe_sdk ~> 0.2.0`.

## Runtime configuration

Trusted operator configuration is loaded from `AUTONOMIC_CONFIG`. Workers never control target paths, signing keys, model contracts, rootfs, or broker credentials. Start from `config/autonomic.example.json` and keep private-key material and API credentials outside the repository.

Typical environment:

```bash
export DATABASE_URL='ecto://autonomic:...@127.0.0.1/autonomic_prod'
export AUTONOMIC_CONFIG=/etc/autonomic/kernel.json
export AUTONOMIC_STATE_DIR=/var/lib/autonomic/kernel
export AUTONOMIC_LINUX_STATE_ROOT=/var/lib/autonomic
export AUTONOMIC_ROOTFS=/opt/autonomic/rootfs
export AUTONOMIC_LAUNCHER=/usr/local/libexec/autonomic_launcher
export AUTONOMIC_LINUX=1
# only when running the mandatory live semantic gate:
export TYPESAFE_API_KEY='...'
```

## Verification tiers

`mix test` runs pure/component tests. Mandatory integration gates are explicit because they require real infrastructure:

```bash
MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo
MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo
mix test apps/autonomic_store/test/integration --include postgres --exclude linux --exclude reference
AUTONOMIC_LINUX=1 mix test apps/autonomic_linux/test/integration --include linux
AUTONOMIC_LINUX=1 mix test apps/autonomic_store/test/reference --include reference --include postgres --include linux
TYPESAFE_API_KEY=... mix test apps/autonomic_typesafe/test/live_gate_test.exs --include live
```

`mix qc` orchestrates formatting, warnings-as-errors compilation, unit/component tests, Credo, Dialyzer, ExDoc, Rust fmt/clippy/test, real PostgreSQL gates, Linux containment, reference scenario, live TypeSafe (when explicitly enabled), secret scanning and conformance generation. It writes `artifacts/conformance_report.json` and exits non-zero unless every mandatory gate is green.

## Security status

Do not infer isolation safety from source presence. The authoritative release determination is `artifacts/conformance_report.json` plus `HANDOFF.md`. A gate that could not run is **pending**, never silently replaced by a fake or marked passed.

See [Architecture](docs/ARCHITECTURE.md), [Security](docs/SECURITY.md), [Persistence and recovery](docs/PERSISTENCE_RECOVERY.md), [Operations](docs/OPERATIONS.md), [Development](docs/DEVELOPMENT.md), and [the implementation checklist](docs/IMPLEMENTATION_CHECKLIST.md).

## License

MIT. See `LICENSE`.
