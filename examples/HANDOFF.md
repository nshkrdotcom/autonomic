# Examples suite handoff — 2026-09-17

## Scope completed

This overlay adds the full numbered `examples/` suite described by `EXAMPLES_ROADMAP.md`, plus the shared laptop development stack, a root examples index, a surgical root README hook, a service-free Ubuntu/macOS examples workflow, and package-boundary linting for example-only code.

The numbered suite contains **24 independent Mix projects**, each with a `run.exs` entrypoint and a README trust-delta table. The later detailed roadmap sections (11–24) were treated as authoritative where the roadmap's earlier directory sketch stopped at 20 or used older names.

## Files that intentionally modify the existing repository

Only two pre-existing repository files are changed:

1. `README.md` — one inserted **Try it in 60 seconds** block immediately before the existing Contents section. No other README text was changed.
2. `scripts/lint_package_boundaries.py` — extends the existing architectural lint to assert that no publishable package depends on `autonomic_examples_dev` and that `Autonomic.Dev.*` source references remain confined to `examples/`.

Everything else is new: the entire `examples/` tree plus `.github/workflows/examples.yml`, which runs examples 01–08 on both Ubuntu and macOS using the repository's pinned toolchain.

## Shared harness

`examples/dev_stack` is a non-publishable local Mix package containing:

- `Autonomic.Dev.MemoryStore` — serialized in-memory implementation of the store API surface actually exercised by core, including episode lifecycle, lease/effect persistence, epoch advance, decision records, checkpoints, trajectory persistence, reconciliation, and append-only example events. Epoch advance revokes old leases and marks old pre-commit effects stale. It provides no crash durability or cross-node semantics.
- `Autonomic.Dev.UnsafeLocalDomain` — executes trusted example commands with `System.cmd/3` in a temporary directory, supports filesystem checkpoints/restores, and rejects stale generations. It loudly warns that there are no namespaces, cgroups, seccomp, network isolation, or secret boundary.
- `Autonomic.Dev.ScriptedSensor` — deterministic semantic observations plus explicit outage/error injection.
- `Autonomic.Dev.MemoryAdapter` / `TargetStore` — deterministic target mutation, ambiguity, idempotency, and reconciliation paths.
- `Autonomic.Dev.Support` — common configuration, episode bootstrap, assertions, signing, and effect helpers.
- `Autonomic.Dev.AdapterCase`, `StoreCase`, `ExecutionDomainCase` — runnable extension-contract probes.

The harness is deliberately outside `packages/` and is blocked from becoming a published-package dependency by `scripts/lint_package_boundaries.py`.

## Source-level QC completed in this environment

The generation environment does **not** contain `elixir` or `mix`, so no claim is made that the Elixir projects were compiled or executed here. The repository pins Elixir `1.20.4-otp-29` and Erlang/OTP `29.0.6` in `.tool-versions`; use those exact versions for the first runtime pass.

The following checks were run successfully:

```text
python3 scripts/lint_package_boundaries.py
  PASS

python3 -m py_compile examples/16_worker_sdk_python/worker_sdk.py
  PASS

python3 examples/16_worker_sdk_python/worker_sdk.py --self-test
  worker_sdk.py self-test: PASS

bash -n examples/17_full_stack_linux/run_full_stack.sh
  PASS

node --check examples/16_worker_sdk_python/worker_sdk.mjs
  PASS

gofmt -w examples/16_worker_sdk_python/worker_sdk.go
  PASS

go run examples/16_worker_sdk_python/worker_sdk.go
  PASS

.github/workflows/examples.yml YAML parse
  PASS

uv run --no-project python scripts/test_qc.py
  1 test, PASS
```

Structural counts verified:

- 24 numbered example directories;
- 24 numbered `run.exs` entrypoints;
- 25 example Mix projects including `dev_stack`;
- 25 per-project READMEs including `dev_stack`.

## Required Elixir runtime QC — next agent

Run these on the repository-pinned Elixir 1.20.4 / OTP 29.0.6 checkout. Do not paper over failures by weakening assertions.

### 1. Format and compile the shared harness

```bash
cd examples/dev_stack
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
```

If compilation finds a callback-spec mismatch around `ExecutionDomain.destroy/1`, preserve the controller's evidence-bearing destruction semantics; do not remove destruction evidence merely to silence a callback warning. Reconcile the public behaviour contract with the implementation if needed.

### 2. Run every laptop example

From repository root:

```bash
set -euo pipefail
for example in examples/[0-9][0-9]_*/; do
  echo "==> $example"
  (cd "$example" && mix deps.get && mix format --check-formatted && mix compile --warnings-as-errors && mix run)
done
```

Expected qualified prerequisite behavior:

- `14_custom_store_sqlite`: if `sqlite3` is not installed, it prints the prerequisite and exits successfully without claiming the SQLite gate ran. Install SQLite and rerun for the actual assertion.
- `17_full_stack_linux`: without explicit opt-in on a qualified host, it verifies referenced production scripts exist and reports a qualified skip. On a disposable qualified host, set `AUTONOMIC_RUN_PRIVILEGED=1` and run it again.

### 3. Run existing repository QC

Use the repository's normal QC entrypoint after examples compile. At minimum:

```bash
python3 scripts/lint_package_boundaries.py
./scripts/qc
```

Then run the strict/privileged gates on the host class they already require. Examples must not cause any publishable package's dependency graph or package manifest to change.

### 4. macOS/Linux laptop matrix

The roadmap calls for Tier 1 to run service-free on both macOS and Ubuntu. Validate at least examples 01–10 on both OSes. `UnsafeLocalDomain` uses `/bin/sh`, which should exist on both target OSes; do not replace it with OS-specific shell behavior without updating the matrix.

## High-value runtime checks to scrutinize

Because the Elixir runtime was unavailable here, pay extra attention to these integration seams first:

1. **Application startup ordering.** Each numbered project configures `:autonomic` to use the dev store/domain/sensor and starts both `:autonomic` and `:autonomic_examples_dev`. Confirm the dev application's processes are available before any delayed `EffectBroker` reconciliation touches the store.
2. **Bootstrap checkpoint.** `EpisodeController` captures a stable checkpoint during bootstrap. Confirm `UnsafeLocalDomain.checkpoint/1` and `MemoryStore.put_checkpoint/1` satisfy `SnapshotManager` exactly.
3. **MemoryStore return shapes.** Validate all return shapes used by `EpisodeSupervisor`, `EffectBroker`, `SnapshotManager`, `Homeostat`, `RepairManager`, and controller completion/containment.
4. **Example 04 decision persistence.** Four separate Class 4 effects are deliberately used so failed approval attempts cannot conflict with already persisted semantic decision evidence on a single effect revision.
5. **Example 08 saturation timing.** The first broker task intentionally sleeps in adapter validation and the script waits until `EffectBroker.stats().active == 1` before issuing the second request. Confirm this remains deterministic; do not replace the bounded-state wait with larger arbitrary sleeps.
6. **Example 14 SQLite CLI quoting/term decoding.** Run with a real `sqlite3` binary. The example intentionally uses a serialized single-writer GenServer plus `BEGIN IMMEDIATE`; it is an extension/conformance example, not a claim of PostgreSQL-equivalent HA semantics.
7. **Example 22 regulator behavior.** The current source admits only Class 0 in `:read_only_autonomy` but Classes 0–2 in `:no_sensitive_commits`. The example asserts and loudly labels this **current implementation review flag** so the suite does not silently bless it. Resolve architectural intent separately before changing the example or regulator.

## Deliberate roadmap adaptations — do not mistake these for hidden completion claims

### Example 18 — LLM agent loop

The kernel routing loop and swappable `ExampleAgentModel` behaviour are implemented and runnable deterministically. The default model is scripted so the example is reproducible and does not require a provider credential. No specific live LLM provider was hard-coded because the repository does not define one. If the project chooses a canonical provider/client, add a live implementation behind the existing behaviour without changing the tool-routing boundary: Class 0/1 local work goes to `ExecutionDomain`; external authority goes to `EffectBroker`.

### Example 19 — operator console

The authoritative read/control model is implemented as a terminal console and includes operator containment. The roadmap suggested Phoenix LiveView, but the repository has no Phoenix dependency. This overlay deliberately does **not** add Phoenix to core or pretend a terminal view is LiveView. If a separate example-only Phoenix app is desired, wrap these exact read paths in `examples/19_operator_console` without adding Phoenix to any publishable package.

### Example 20 — observability

The current core declares `:telemetry` but emits no normative broker event vocabulary. The example therefore emits namespaced `[:autonomic, :example, ...]` telemetry around the public broker calls and asserts that metadata contains duration/identifiers rather than payloads/secrets. If core telemetry is later added, migrate the example to core events and add regression tests for metadata redaction.

### Example 17 — full-stack Linux

`run_full_stack.sh` wires the existing provisioning, Rust launcher build, rootfs build, and preflight scripts and resolves OTP/Elixir roots from explicit env vars or mise/asdf. It was syntax-checked only here. The actual privileged path must be run on the existing qualified host class; do not claim the OS-plane gate from the laptop examples.

## Known source discrepancy captured by the examples

The roadmap says replay/idempotency should “submit the same proposal twice; show digest-based identity.” The current broker creates a new effect ID for each proposal. Example 12 therefore demonstrates what the code actually guarantees:

- identical payload bytes produce the same content digest;
- repeated logical effects remain distinct effect IDs;
- the trusted target adapter performs conditional/idempotent replay;
- a post-intent target conflict becomes `commit_unknown` instead of clobbering.

Do not change the example to claim broker-level proposal deduplication unless the core implementation gains that feature.

## Definition of done for the next runtime/QC pass

The handoff is complete when:

- all 24 numbered projects compile with warnings treated as errors;
- all non-qualified-skip examples exit zero and reach their final `ASSERTION PASSED` line;
- example 14 passes with SQLite installed;
- example 17 passes on the qualified privileged Linux host when explicitly opted in;
- existing core/package/integration QC remains green;
- package-boundary lint remains green;
- root README diff is still only the inserted examples block;
- any required runtime fixes are limited to the example suite unless a genuine pre-existing core bug is discovered and separately documented.
