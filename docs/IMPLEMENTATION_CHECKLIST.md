# Normative implementation checklist

This checklist maps `docs/spec/11_ACCEPTANCE_GATES.md` to concrete code and executable evidence. **Implemented** means the production path and test/harness exist; it does not mean a host-dependent gate passed. Actual execution status is only in `artifacts/conformance_report.json`.

| Gate | Implementation | Executable evidence |
|---|---|---|
| A1 no unmediated irreversible effects | `Autonomic.EffectBroker`, Linux net namespace/seccomp, AF_UNIX `EffectSocket`, trusted target adapters | Linux containment + AF_UNIX + coding-agent reference gates |
| A2 semantic cannot exceed authority | `Policy.precedence/1`, `AuthorityGovernor`, Homeostat hard violations, TypeSafe sensor-only adapter | `authority_test`, `homeostat_trajectory_test`, hostile reference fixture |
| A3 epoch fencing | durable episode epoch, lease/effect/version-vector checks at prepare and commit, explicit socket epoch check | `postgres_authority_test`, hostile epoch-2 reference variant |
| A4 speculate before commit | closed `EffectState`, durable `proposed→prepared→evaluating→ready→commit_intent`, decision floor | reconciliation + Class-4 horizon tests |
| A5 worker disposable | persisted domain identity, checkpoint metadata, `RepairManager`, controller restart recovery | Linux rollback/fork cleanup + reference recovery gate |
| B namespaces | Rust `unshare` user/mount/PID/net/IPC/UTS | `containment_test.exs` |
| B cgroup v2 | dedicated episode/epoch/generation subtree; CPU/memory/PID/swap ceilings | `containment_test.exs` |
| B seccomp/no_new_privs | raw BPF seccomp, `PR_SET_NO_NEW_PRIVS`, direct INET/INET6 SIGSYS | `containment_test.exs` |
| B mount/overlay | read-only rootfs + disposable overlay workspace + tmpfs/proc + broker socket bind | `containment_test.exs` |
| B teardown proof | cgroup-wide kill, wait-empty and fail-closed destroy evidence | fork-tree test |
| C effect transitions | `Autonomic.EffectState` plus store transition enforcement | `authority_test`, integration state transitions |
| C revision-bound decisions | `effect_decisions` exact revision/vector binding | `reconciliation_test.exs` |
| C stale epoch races | episode-first row locks and durable reread | `postgres_authority_test.exs` |
| C Git CAS | exact base OID, trusted worktree, `git update-ref` CAS | reconciliation/reference tests |
| C HTTP boundary | trusted base host/path/method, redirects off, TLS verification, limits/credentials/rate limits | AF_UNIX HTTP integration test |
| C ambiguous commit | post-intent adapter uncertainty → `commit_unknown`; explicit reconciliation | `reconciliation_test.exs` |
| D TypeSafe 0.2 strict API | strict Noul/Choice/Score, prepare once, `evaluate/4`, `Response`/`Answer` helpers | `sensor_component_test.exs` |
| D live TypeSafe | real configured SDK client and non-secret provenance artifact | `live_gate_test.exs` |
| D sensor provenance | bank version/contract id/SDK/model/request/usage/retry/timing fields | component + live gate |
| D redaction/budget | `Autonomic.Typesafe.Evidence` pre-transport redaction/limits | component tests |
| D unknown/model drift | fail-closed unknown required answer and configured actual model | component tests |
| D runtime capabilities | `TypeSafeSDK.RuntimeCapabilities.check/2` | component + live gate |
| D temporal Homeostat | EWMA/hysteresis with deterministic bypass | real-Postgres trajectory test |
| E demand/backpressure | GenStage `SensorArray`, non-droppable critical facts, `SystemRegulator` modes | `regulation_test.exs` and reference gate |
| E speculation budget | episode worker timeout + regulator admission + sensitive commit gate | component/reference tests |
| F PostgreSQL | Ecto/Postgrex schemas/migration; no memory fallback | PostgreSQL integration gate |
| F epoch race | episode `FOR UPDATE` lock and concurrent barrier test | `postgres_authority_test.exs` |
| F commit recovery | durable commit intent + `EffectBroker.reconcile_pending/0` | reconciliation test |
| F checkpoint agreement | backend digest verified on restore; metadata transactional | containment/reference tests |
| F ownership | owner lease schema/claim/renew methods; clustering disabled in reference runtime | source contract; enable a clustered gate before multi-node deployment |
| F DB outage | production paths require store calls; no authority fallback | `scripts/run_db_outage_gate.sh` with ephemeral real PostgreSQL stop/start |
| G normal coding-agent | isolated worker clone, tests, exact patch, slow verifier, trusted Git CAS | reference test normal variant |
| G hostile coding-agent | prompt-injection fixture + direct IP socket tripwire + epoch bump + cgroup kill + restore + epoch-2 repair | reference test hostile variant |
| H formatting/compile/tests/static | root QC runner | `mix qc` |
| H Credo/Dialyzer/ExDoc | root dependencies and strict QC commands | `mix qc` |
| H Rust quality | fmt/clippy/tests | `mix qc` / `scripts/build_launcher.sh` |
| H credentials/preflight | strict secret patterns; host preflight | `scripts/qc.py`, `scripts/preflight.sh` |
| I evidence | machine-readable gate report with environment versions/results | `artifacts/conformance_report.json` |
| J docs | architecture, security, provisioning, adapters, TypeSafe, persistence, testing, runbooks, handoff | `docs/` + `HANDOFF.md` |

## Required target-host completion sequence

```bash
bash scripts/preflight.sh
mix deps.get
MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo
MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo
cargo build --release --manifest-path native/autonomic_launcher/Cargo.toml
mix qc
```

The project is release-ready only if the strict QC report has `release_ready: true` and no mandatory gate is skipped.
