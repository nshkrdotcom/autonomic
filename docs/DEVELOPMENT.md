# Development and testing

## Toolchain

`.tool-versions` pins Elixir 1.20.4 / OTP 29.0.6 and Rust 1.90.0. PostgreSQL is a real integration dependency. Do not replace the authority store, Linux backend or semantic SDK with dummy production implementations to make tests easier.

## Setup

```bash
for project in packages/* integration/autonomic_acceptance; do
  (cd "$project" && mix deps.get)
done
(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo)
(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo)
bash scripts/build_launcher.sh
```

For Linux gates set `AUTONOMIC_LINUX=1`, `AUTONOMIC_ROOTFS`, `AUTONOMIC_LINUX_STATE_ROOT`, and optionally `AUTONOMIC_NO_SUDO=1` when already root.

## Test strata

- Pure/component: run `mix test` inside each package.
- Store/race/reconciliation/AF_UNIX: `(cd packages/autonomic_postgres && mix test test/integration --include postgres --exclude linux --exclude reference)`
- Linux isolation: `(cd packages/autonomic_linux && AUTONOMIC_LINUX=1 mix test test/integration --include linux)`
- Coding-agent normal + hostile reference: `(cd integration/autonomic_acceptance && AUTONOMIC_LINUX=1 mix test test/coding_agent_test.exs --include reference --include postgres --include linux)`
- Live semantic: `(cd packages/autonomic_typesafe && TYPESAFE_API_KEY=... mix test test/live_gate_test.exs --include live)`

## QC

`./scripts/qc --strict` runs all required gates. `python3 scripts/qc.py --handoff` is only for creating an honest continuation report on a host that lacks mandatory dependencies; it never sets `release_ready=true` when gates are skipped.

The test fixture under `test/fixtures/coding_agent` deliberately contains hostile prompt-injection text. It is inert test data, not an instruction to the implementation agent.

## CI tiers

`.github/workflows/ci.yml` runs the non-privileged BEAM/PostgreSQL and Rust quality gates. Linux containment is intentionally separated into `privileged-linux.yml`, which only runs on an operator-controlled runner labeled `autonomic-privileged`; hosted CI is not treated as proof of cgroup/namespace/seccomp behavior. `live-typesafe.yml` is manual and additionally requires `TYPESAFE_LIVE_ENABLED=true` plus the `TYPESAFE_API_KEY` secret. No workflow substitutes fixtures for either privileged Linux acceptance or the live TypeSafe gate.

## Reproducible offline verification rootfs

Build a fresh rootfs from the exact installed toolchains, then install the launcher:

```bash
sudo python3 scripts/build_rootfs.py \
  --destination /opt/autonomic/rootfs \
  --otp "$(asdf where erlang 29.0.6)" \
  --elixir "$(asdf where elixir 1.20.4-otp-29)"
bash scripts/build_launcher.sh /tmp/autonomic_launcher
sudo install -D -m 0755 /tmp/autonomic_launcher /usr/local/libexec/autonomic_launcher
```

The builder refuses to overwrite an existing rootfs. It copies executable/runtime libraries only, records their SHA-256 hashes in `rootfs-manifest.json`, and copies no host credentials. The launcher mounts the root read-only and supplies separate disposable `/workspace`, `/run`, `/tmp`, `/proc`, and `/dev` mounts. `/dev` contains only bound null/zero/random/urandom devices.

Stock OTP 29 opens an IPv4 UDP socket to discover its hostname at startup. The rootfs builder recompiles only `inet_config.set_hostname/0` to use the fixed hostname `autonomic`. Stock Mix uses TCP for cross-process build notifications; the rootfs replaces only the Mix PubSub subscriber with an inactive listener. Actual Mix compilation and ExUnit execution are unchanged. This runtime is intentionally offline; it is not a general-purpose distributed BEAM installation. These adaptations apply only inside the copied rootfs, never to the host toolchains, and direct AF_INET/AF_INET6 attempts still raise SIGSYS.

Use `MIX_OS_CONCURRENCY_LOCK=0` for a disposable verification workspace, which is owned by one Mix process. Set `ELIXIR_ERL_OPTIONS='+S 2:2 +SDcpu 1 +SDio 1'` to fit its PID budget. The reference scenario and trusted verification target declare these explicitly. Git trusts only `/workspace` inside the rootfs, permitting the namespace-root worker to read its independently cloned repository. The authoritative repository is never mounted there.

PostgreSQL URLs must name the actual listening port. On the acceptance host the dedicated `autonomic_test` database runs on port 5433. Set `AUTONOMIC_TEST_DATABASE_URL=ecto://autonomic:autonomic@127.0.0.1:5433/autonomic_test` before migrations and QC. The outage gate creates and destroys its own temporary PostgreSQL cluster.
