# Examples suite handoff — 2026-09-17

## Scope

This overlay completes the 24-example suite from `EXAMPLES_ROADMAP.md`, the shared `examples/dev_stack` harness, examples CI/boundary enforcement, and the small root README hook. It also carries the runtime fixes discovered while qualifying the examples against the real repository.

The authoritative source checkout is the **Workstation** tree. `omen-ubuntu26-dev` is a separate Ubuntu 26.04 validation host populated from that tree. No intentional source patches were made on `omen`; it was used for host/toolchain provisioning and runtime qualification only.

## Runtime fixes discovered and incorporated

- corrected the example MemoryStore helper syntax so the shared harness compiles;
- removed dynamic atom conversion from shared example support;
- fixed `Support.print_effect/2` argument order for pipeline use;
- moved per-example state roots to `/tmp/autonomic-examples/<example>` by default to keep AF_UNIX paths bounded;
- made every numbered project expose plain `mix run` as the entrypoint and fetch its dependencies through that alias;
- added per-project formatter configuration;
- made the backpressure example occupy a real broker slot through blocked adapter validation and inspect the inner GenStage state correctly;
- reworked the semantic-outage example so all Class 3 effects are prepared while healthy, then proves degraded semantic health blocks both new sensitive work and an already-ready sensitive commit;
- fixed `AuthorityGovernor.advance_epoch/2` audit serialization so tuple containment reasons cannot crash JSON-backed stores;
- added a real PostgreSQL integration regression for the non-JSON containment-reason failure;
- made `scripts/run_reference.sh` fetch the test dependencies it needs on a fresh checkout;
- made `scripts/qc.py` emit START/STEP/WAIT/PASS/FAIL/PEND progress with elapsed time while continuing to retain full command output under `artifacts/logs/`;
- preserved `scripts/run_live_typesafe.sh` as an executable script.

## Runtime qualification completed

### Workstation — WSL2

Pinned BEAM toolchain:

- Elixir 1.20.4
- Erlang/OTP 29.0.6

The numbered example matrix reached:

```text
PASS 01_first_episode
PASS 02_effect_lifecycle
PASS 03_epoch_fencing
PASS 04_class4_approval
PASS 05_commit_unknown
PASS 06_precedence_lattice
PASS 07_homeostat_regimes
PASS 08_backpressure
PASS 09_prompt_injection
PASS 10_sensor_outage
PASS 11_credential_non_exposure
PASS 12_replay_idempotency
PASS 13_custom_adapter_s3
PASS 14_custom_store_sqlite
PASS 15_custom_domain_microvm
PASS 16_worker_sdk_python
SKIP 17_full_stack_linux   qualified privileged-host gate
PASS 18_llm_agent_loop
PASS 19_operator_console
PASS 20_observability
PASS 21_policy_signing_cli
PASS 22_fleet_regulation
PASS 23_migration_unmediated
PASS 24_benchmark_overhead
```

The core package was also rerun after the AuthorityGovernor serialization fix and remained green.

### omen-ubuntu26-dev — Ubuntu 26.04.1 / kernel 7.0

Qualified host/toolchain:

- Elixir 1.20.4
- Erlang/OTP 29.0.6
- Rust 1.90.0
- PostgreSQL 18.6
- cgroup v2
- overlayfs
- namespace/seccomp-capable Linux host
- production launcher installed at `/usr/local/libexec/autonomic_launcher`
- trusted verification rootfs at `/opt/autonomic/rootfs`

Privileged/full-stack evidence:

```text
Example 17 privileged production-host gate       PASS
Rust launcher unit tests                         4/4 PASS
Linux containment integration                    3/3 PASS
PostgreSQL + Linux reference acceptance          2/2 PASS
Live TypeSafe evaluate gate                      1/1 PASS
```

A final repository-wide strict conformance run on `omen` completed with:

```text
strict QC exit:          0
status:                  release_ready
release_ready:           true
mandatory_not_green:     []
non_passed:              []
TypeSafe credentials:    configured on trusted validation host
```

Every mandatory gate in that run passed, including formatting, warnings-as-errors compilation, ExUnit, Credo, Dialyzer, ExDoc warnings-as-errors, Rust fmt/clippy/tests, PostgreSQL migrations/integration/races/outage, Linux containment, coding-agent reference/hostile paths, sensor poisoning, backpressure, the live TypeSafe gate, and host preflight.

That strict run qualified the runtime-fix tree. This final overlay additionally improves QC progress reporting, makes `run_reference.sh` fresh-checkout safe, adds the PostgreSQL regression test, and updates documentation; rerun strict QC after applying these final source changes.

Combining the Workstation laptop matrix with the qualified `omen` run gives **24/24 numbered examples executed successfully**, including the real privileged path for example 17.

## Trusted development credentials

The TypeSafe API key belongs to the trusted host-side development/QC process, not to the Linux worker sandbox. On trusted development machines it is acceptable for `TYPESAFE_API_KEY` to be supplied by the normal shell environment. The live TypeSafe gate consumes it on the host; the sandbox remains credential-free and without direct routable network access.

Generic/uncredentialed environments may leave the live gate pending in handoff mode. Strict release QC is green only when the live gate actually executes.

## Remaining semantic review flag

Example 22 intentionally exposes the current `SystemRegulator.admit?/1` ordering in which `:read_only_autonomy` admits only Class 0 while `:no_sensitive_commits` admits Classes 0–2. The example records current behavior; it does not silently decide the architectural policy. Change that behavior only as a separate core-policy decision with corresponding tests/docs.

## Apply and final verification

Apply this overlay to the authoritative Workstation checkout. Then run at least:

```bash
cd packages/autonomic
mix format --check-formatted
mix compile --warnings-as-errors
mix test

cd ../../packages/autonomic_postgres
AUTONOMIC_TEST_DATABASE_URL='ecto://autonomic:autonomic@127.0.0.1/autonomic_test' \
  mix test test/integration/postgres_authority_test.exs --include postgres

cd ../..
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/lint_package_boundaries.py
```

After syncing the authoritative source changes to the qualified Ubuntu host, rerun:

```bash
./scripts/qc --strict
```

The expected final result is `release_ready: true` with zero non-passed mandatory gates. Do not weaken or skip a gate to obtain that result.
