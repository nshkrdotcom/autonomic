# Autonomic Kernel acceptance handoff

Date: 2026-09-17

## Completion contract

`artifacts/conformance_report.json` is the release determination for this source tree. Every mandatory gate must be `passed` and `release_ready` must be `true`. Gate logs and the report record actual executions; unavailable, failed, or fully excluded tests cannot count as passes. The report binds the source inventory and execution logs with SHA-256.

The production implementation remains PostgreSQL-backed, uses the external Rust Linux launcher, integrates TypeSafeSDK 0.2 through its strict public semantic API, and crosses irreversible-effect authority only through the durable EffectBroker commit horizon. The acceptance scope is the invariants and scenarios in `docs/spec/11_ACCEPTANCE_GATES.md` on the recorded host.

## Reviewed changes

The pushed repository baseline was `cb0a886`. The incoming uncommitted Antigravity fixes were reviewed against it. The illegal Elixir guards, unreachable clauses, rescue-variable scope fix, Rust serialization/import fixes, and Rust formatting were retained. The regulator branch was simplified while retaining immediate degradation and hysteretic recovery. Dependency lockfiles are included.

Executable acceptance additionally uncovered and repaired:

- Episode-event/observation migration IDs that disagreed with Ecto schemas, numeric capability constraints, the controller child specification, and the checkpoint snapshot return contract.
- Non-JSON manifest/semantic metadata/HTTP receipt tuples and a nullable receipt on prepared socket responses. Canonical authority encoding remains strict.
- Native cgroup-entry races before fork/exec, keeper readiness, namespace access to the trusted broker account, offline runtime setup, and missing device mounts. Direct network calls still trigger SIGSYS; namespace manipulation syscalls are denied.
- Concurrent artifact publication overwrites: publication now atomically creates the final name with a hard link after syncing the complete temporary file. Conflicting content cannot replace it.
- HTTP origin checking now binds scheme, host, and port. Responses are streamed with a byte ceiling instead of being fully downloaded before checking their size; redirects are not followed.
- Test selection, asynchronous socket ownership, global-state assertions, per-test episode teardown, Git-ref reconciliation assertions, and live-evidence output location.
- Credo, Dialyzer, formatter, and ExDoc findings without disabling their checks.

The native rootfs is reproducibly built by `scripts/build_rootfs.py`. Its two offline startup adaptations and runtime file hashes are documented in `docs/DEVELOPMENT.md` and the generated rootfs manifest. Host OTP/Elixir installations are unmodified upstream runtimes. The misleading OTP 29.0.6 directory copied from OTP 29.0.5 was moved aside; genuine OTP 29.0.6 was built and installed.

## Acceptance host

- Ubuntu 26.04.1 LTS; Linux `6.18.33.2-microsoft-standard-WSL2`, x86_64.
- Elixir 1.20.4, Erlang/OTP 29.0.6 / ERTS 17.0.6.
- Rust/Cargo 1.90.0; exact selection in `.tool-versions` and `rust-toolchain.toml`.
- PostgreSQL 18.6; dedicated `autonomic_test` database on port 5433.
- Python 3.14.4 and Git 2.53.0.
- Unified cgroup v2, privileged namespace/mount operations, overlayfs, and the live TypeSafe service were exercised.

Exact versions, executed commands, timestamps, statuses, and log references are in the conformance report. Semantic provenance is in `artifacts/typesafe_live_gate.json`; no API key is recorded. Dependency audit output and the resolved dependency tree are under `artifacts/`.

## Reproduction

Install the exact pinned toolchains and PostgreSQL server/client binaries. Provision the test role/database on an explicitly selected port, then:

```bash
mix deps.get
export AUTONOMIC_TEST_DATABASE_URL='ecto://autonomic:autonomic@127.0.0.1:5433/autonomic_test'
MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo
MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo
sudo python3 scripts/build_rootfs.py \
  --destination /opt/autonomic/rootfs \
  --otp "$(asdf where erlang 29.0.6)" \
  --elixir "$(asdf where elixir 1.20.4-otp-29)"
bash scripts/build_launcher.sh /tmp/autonomic_launcher
sudo install -D -m 0755 /tmp/autonomic_launcher /usr/local/libexec/autonomic_launcher
sudo install -d -m 0700 /var/lib/autonomic
export AUTONOMIC_LINUX=1
export AUTONOMIC_ROOTFS=/opt/autonomic/rootfs
export AUTONOMIC_LAUNCHER=/usr/local/libexec/autonomic_launcher
# Intentionally configure TYPESAFE_API_KEY through the operator environment.
bash scripts/preflight.sh
python3 scripts/qc.py --strict
```

The rootfs builder requires a fresh destination and does not overwrite an existing image. `scripts/run_db_outage_gate.sh` owns its temporary PostgreSQL cluster; it does not stop the host database. `scripts/run_reference.sh` runs both required coding-agent variants. `scripts/run_live_typesafe.sh` runs the real semantic gate independently.

## Git and evidence

The final commit is obtained with `git rev-parse HEAD`; this document does not embed its own commit ID. `DELIVERY.json` points to the evidence rather than stale archive metadata. The final source tree, tests, documentation, dependency locks, conformance report, and executed gate logs are committed together.
