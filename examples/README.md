# Autonomic examples

The examples turn Autonomic's trust model into small, executable assertions. They are intentionally outside `packages/`: no published package may depend on the example harness, and the laptop development backend is never presented as production isolation.

## Start here

```bash
cd examples/01_first_episode
mix deps.get
mix run
```

Every numbered directory is its own Mix project and uses the repository's `packages/autonomic` via a path dependency. After dependencies have been fetched once, run any example with:

```bash
cd examples/NN_name
mix run
```

Most examples need only Elixir/OTP. `14_custom_store_sqlite` additionally uses the `sqlite3` executable; `16_worker_sdk_python` uses Python 3 for its protocol self-test; `17_full_stack_linux` executes the real privileged path only when run on a qualified Linux host with `AUTONOMIC_RUN_PRIVILEGED=1`. Those examples make prerequisite absence explicit instead of substituting weaker behavior.

## Trust delta

The shared `dev_stack/` is an adoption/testing harness, not a production backend. It uses the real core OTP control plane but replaces infrastructure boundaries so kernel semantics can be inspected on a laptop.

| Boundary | Laptop examples | Production |
| :--- | :--- | :--- |
| Authority/effect state machine | Real `autonomic` core | Real `autonomic` core |
| Epoch/lease checks | Real core checks over a serialized in-memory store | Durable PostgreSQL transactions via `autonomic_postgres` |
| Execution domain | **Unsafe** local directory + `System.cmd/3` | Namespaces, cgroups v2, seccomp, overlayfs via `autonomic_linux` |
| Semantic sensor | Deterministic scripted observations | `autonomic_typesafe` / TypeSafe SDK |
| External targets | In-memory adapters unless an example says otherwise | Trusted Git/HTTP/artifact adapters and real targets |

`Autonomic.Dev.UnsafeLocalDomain` has **no namespaces, cgroups, seccomp, network isolation, or host-secret boundary**. Never run untrusted code through it.

## Capability matrix

| # | Example | Main assertion | Extra requirement |
| :-- | :--- | :--- | :--- |
| 01 | [`01_first_episode`](01_first_episode/) | Episode boots, receives an epoch-fenced lease, performs local Class 1 work, and completes. | — |
| 02 | [`02_effect_lifecycle`](02_effect_lifecycle/) | Prepare → evaluate → commit works; a second commit is rejected. | — |
| 03 | [`03_epoch_fencing`](03_epoch_fencing/) | Epoch advancement stales old authority; re-proposal under the new epoch succeeds. | — |
| 04 | [`04_class4_approval`](04_class4_approval/) | Class 4 approval is bound to key, effect, revision, epoch, and payload digest. | — |
| 05 | [`05_commit_unknown`](05_commit_unknown/) | Ambiguous commit is parked and reconciled; blind retry is rejected. | — |
| 06 | [`06_precedence_lattice`](06_precedence_lattice/) | Higher-precedence denial wins; semantics cannot expand authority. | — |
| 07 | [`07_homeostat_regimes`](07_homeostat_regimes/) | Trajectory state is temporal and recovery is hysteretic. | — |
| 08 | [`08_backpressure`](08_backpressure/) | Broker saturation rejects work; critical deterministic sensor facts survive shedding. | — |
| 09 | [`09_prompt_injection`](09_prompt_injection/) | Adversarial content cannot widen deterministic target policy. | — |
| 10 | [`10_sensor_outage`](10_sensor_outage/) | Semantic failure degrades health and blocks sensitive work instead of fabricating allow. | — |
| 11 | [`11_credential_non_exposure`](11_credential_non_exposure/) | Broker-owned credential values do not enter worker-visible/persisted effect data. | — |
| 12 | [`12_replay_idempotency`](12_replay_idempotency/) | Payload identity is digest-stable and target replay is conditional/idempotent. | — |
| 13 | [`13_custom_adapter_s3`](13_custom_adapter_s3/) | An object-storage adapter validates scope, commits conditionally, and reconciles. | — |
| 14 | [`14_custom_store_sqlite`](14_custom_store_sqlite/) | SQLite reference store advances epochs monotonically and fences old records. | `sqlite3` |
| 15 | [`15_custom_domain_microvm`](15_custom_domain_microvm/) | A backend skeleton fails closed until real isolation/destruction evidence exists. | — |
| 16 | [`16_worker_sdk_python`](16_worker_sdk_python/) | Worker client implements protocol-1 length framing and chunk digest verification. | Python 3 |
| 17 | [`17_full_stack_linux`](17_full_stack_linux/) | Production example never substitutes laptop execution for privileged Linux preflight. | Qualified privileged Linux for live path |
| 18 | [`18_llm_agent_loop`](18_llm_agent_loop/) | Agent-local tools stay inside the execution domain; external authority uses the broker. | — |
| 19 | [`19_operator_console`](19_operator_console/) | Operator read model exposes authoritative episode/effect state and containment. | — |
| 20 | [`20_observability`](20_observability/) | Telemetry around broker stages carries duration/IDs without payloads or secrets. | — |
| 21 | [`21_policy_signing_cli`](21_policy_signing_cli/) | Canonical policy signing and exact Class 4 approvals verify with explicit keyrings. | — |
| 22 | [`22_fleet_regulation`](22_fleet_regulation/) | Pressure modes and hysteresis are observable; current admission widening is flagged. | — |
| 23 | [`23_migration_unmediated`](23_migration_unmediated/) | Migration removes direct authoritative mutation paths rather than retaining bypasses. | — |
| 24 | [`24_benchmark_overhead`](24_benchmark_overhead/) | Local bookkeeping timings are measured and clearly separated from production/model latency. | — |

## Shared harness

`dev_stack/` provides:

- `Autonomic.Dev.MemoryStore` — a single-writer in-memory store that preserves the **serialization shape** of epoch fencing while intentionally providing no durability;
- `Autonomic.Dev.UnsafeLocalDomain` — an explicitly unsafe local execution backend for trusted example commands only;
- `Autonomic.Dev.ScriptedSensor` — deterministic semantic observations and outage/error injection;
- `Autonomic.Dev.MemoryAdapter` / `TargetStore` — deterministic effect mutation and reconciliation scenarios;
- `Autonomic.Dev.AdapterCase`, `StoreCase`, and `ExecutionDomainCase` — runnable extension-contract probes;
- `Autonomic.Dev.Support` — common setup/assertion helpers.

See [`dev_stack/README.md`](dev_stack/README.md) before copying any example code.

## Run the suite

There is deliberately no root Mix project in this Poncho repository. A shell loop is the simplest full laptop gate:

```bash
set -euo pipefail
for example in examples/[0-9][0-9]_*/; do
  echo "==> $example"
  (cd "$example" && mix deps.get && mix run)
done
```

On a normal laptop, example 14 may report a qualified prerequisite skip if `sqlite3` is absent, and example 17 will verify its production scripts and report a qualified privileged-host skip unless explicitly opted in. CI runs examples 01–08 service-free on both Ubuntu and macOS; the full loop above remains the local all-examples gate.

## What these examples do not prove

Laptop examples prove the kernel-plane logic they actually exercise. They do **not** prove Linux namespace/seccomp/cgroup enforcement, PostgreSQL crash durability/row-lock behavior, live TypeSafe model behavior, or external provider correctness. Those remain the responsibility of the existing privileged, PostgreSQL, and live semantic gates.

The examples handoff in [`HANDOFF.md`](HANDOFF.md) records source-level QC completed in the generation environment and the exact runtime checks still required on an Elixir/OTP host.
