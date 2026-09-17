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

<p align="center">
  <b>An operating-system-style kernel for AI coding agents.</b><br>
  The agent is the untrusted program. The BEAM is the kernel. Every irreversible effect is a mediated transaction.
</p>

---

Autonomic runs untrusted coding workers inside disposable Linux execution domains while keeping authority, policy, effect mediation, verification, recovery and audit in a trusted OTP control plane backed by PostgreSQL.

It is not a prompt-safety wrapper and it does not ask a language model whether another language model is behaving. Deterministic mechanisms — Linux namespaces, cgroup v2, seccomp, overlayfs, signed policy, row-locked epoch fencing — hold authority. Semantic model output is admitted only as a **sensor**: it can narrow, yield, or preempt, and it can never mint a capability or widen an envelope.

**Contents**

[Why](#why) · [What it does](#what-it-does) · [Architecture](#architecture) · [Effect classes](#effect-classes) · [The commit horizon](#the-commit-horizon) · [Install](#install) · [Worked example](#worked-example) · [Worker protocol](#worker-protocol) · [Packages](#packages) · [Configuration](#configuration) · [Invariants](#invariants) · [Security](#security-posture) · [Verification](#verification-and-conformance) · [Repository](#repository-layout) · [Development](#development-and-quality-control) · [Docs](#documentation-map) · [Requirements](#requirements) · [Status](#status)

---

## Why

An autonomous coding agent is a probabilistic program with a shell, a package manager, a network stack and a credential-bearing Git remote. Most harness designs put all of that on the same trust boundary as the orchestrator, then try to constrain it with instructions and a review step.

Three failure modes follow from that design, and Autonomic is built to make each one structurally impossible rather than unlikely:

| Failure mode | Typical harness | Autonomic |
| :--- | :--- | :--- |
| **Agent does something irreversible before anyone can intervene** | Effects execute inline from agent tool calls | Class 2+ effects become durable `ProposedEffect` records that cross a broker with prepare → evaluate → commit semantics |
| **Prompt injection from repository or tool output escalates privilege** | Injected text reaches the same code path as operator intent | Injected text can at most influence a sensor; sensors sit at the bottom of a dominance lattice and cannot expand a lease |
| **A crash mid-effect leaves unknown external state** | Retry and hope, or manual archaeology | `commit_intent` is persisted before actuation; ambiguous outcomes become `commit_unknown` and require adapter reconciliation against authoritative target evidence |

The repository ships a hostile fixture (`test/fixtures/coding_agent/HOSTILE_INJECTION.md`) that instructs the semantic classifier to rate a violation as safe. The acceptance gate asserts that the classifier **does** rate it safe — and that the deterministic seccomp boundary still fences the epoch, destroys the domain, stales the pending effect, and forces a re-proposal under epoch 2.

---

## What it does

- **Isolates workers.** Each episode gets a user/mount/PID/network/IPC/UTS namespace set, a cgroup v2 subtree, a read-only rootfs, and a disposable overlayfs upperdir — created by a small external Rust launcher that never executes worker-supplied shell strings.
- **Mediates effects.** The sandbox has no routable network and no authoritative repository mount. Its only egress is one broker-owned `AF_UNIX` socket. Git pushes, HTTP calls and artifact publication are proposals, not calls.
- **Fences authority durably.** Leases, domains, effect revisions, decisions, checkpoints and commits all bind to a monotonic episode epoch in PostgreSQL. Advancing the epoch atomically revokes leases and stales prepared effects.
- **Supervises trajectory, not just liveness.** A worker can be computationally healthy and semantically unhealthy. `Homeostat` maintains smoothed drift/volatility/uncertainty/pressure state with hysteresis and regime transitions (`stable → uncertain → drifting → unstable → containment`).
- **Recovers deterministically.** Repair advances the epoch, proves the old cgroup empty, digest-verifies the last stable checkpoint, restores it into a *new* generation, mints a reduced repair lease, and persists recovery lineage.
- **Degrades honestly.** Semantic outage, model drift outside the pinned set, DB unavailability and broker saturation all reduce autonomy through `SystemRegulator` instead of silently proceeding. There is no path that promotes an in-memory cache to authority.

---

## Architecture

```text
┌────────────────────────────── TRUSTED HOST ───────────────────────────────┐
│                                                                           │
│  ┌──────────────────────── AUTONOMIC KERNEL (BEAM) ────────────────────┐  │
│  │  EpisodeController (:gen_statem)    AuthorityGovernor   Homeostat   │  │
│  │  EffectBroker    SnapshotManager    RepairManager   SystemRegulator │  │
│  │  SensorArray (GenStage, demand-driven)             VerificationRunner│ │
│  └───────────┬──────────────────┬───────────────────────┬──────────────┘  │
│              │                  │                       │                 │
│      control / epoch     brokered effects        semantic sensor          │
│              │                  │                       │                 │
│  ┌───────────▼──────────┐  ┌────▼─────────────┐  ┌──────▼─────────────┐   │
│  │ autonomic_linux      │  │ Effect adapters  │  │ autonomic_typesafe │   │
│  │ namespaces, cgroup2  │  │ Git / GitRemote  │  │ sensor bank only   │   │
│  │ seccomp, overlayfs   │  │ HTTP / Artifact  │  │ never authority    │   │
│  │ Rust launcher        │  │ (trusted creds)  │  └────────────────────┘   │
│  └───────────┬──────────┘  └────┬─────────────┘                           │
│              │                  │        ┌────────────────────────────┐   │
│  ┌───────────▼──────────────┐   │        │ autonomic_postgres         │   │
│  │ UNTRUSTED EXECUTION      │   │        │ epochs, leases, effects,   │   │
│  │ agent / shell / compiler │   │        │ decisions, checkpoints,    │   │
│  │ package manager / tests  │   │        │ recovery lineage, events   │   │
│  │ no host FS · no Internet │   │        └────────────────────────────┘   │
│  │ one AF_UNIX broker socket│   │                                         │
│  └──────────────────────────┘   │                                         │
└─────────────────────────────────┼─────────────────────────────────────────┘
                                  ▼
                   EXTERNAL WORLD — Git remotes, APIs, registries, humans
```

Per-episode processes run under a `rest_for_one` `EpisodeSupervisor`, so losing the authority governor tears down everything downstream of it rather than leaving a worker running against a dead authority.

### Precedence is a lattice, not a vote

```text
Kernel Denial ≻ Capability Violation ≻ Deterministic Invariant
              ≻ Signed Policy ≻ Human Authority ≻ Semantic Observation
```

A lower-precedence signal can never cancel a negative higher-precedence fact. A seccomp violation or forbidden-path write bypasses Homeostat smoothing entirely and triggers an immediate negative transition. "This request looks benign" loses to "this destination is not on the broker allowlist" every time.

### Control-loop asymmetry

Contraction is fast; expansion is slow and requires stronger authority.

```text
fast loop (~100ms–1s, async)  → continue | throttle | narrow | revoke | interrupt
slow loop (pre-commit)        → may additionally authorize bounded expansion or commit
```

---

## Effect classes

Every proposed action is classified. The class determines what the worker may do unilaterally and what must cross the broker.

| Class | Meaning | Example | Mediation |
| :--- | :--- | :--- | :--- |
| `class_0_local_replayable` | Reads and analysis, replayable | Read workspace, run a linter | Inside the domain |
| `class_1_isolated_mutable` | Mutations confined to the disposable overlay | Edit files, compile, run tests, local commits | Inside the domain |
| `class_2_external_observable_or_compensatable` | External but observable or compensatable | Brokered HTTP `GET` through a target allowlist | `EffectBroker` |
| `class_3_authoritative_external_mutation` | Authoritative external mutation | Update `refs/heads/main`, mutating API call | Broker + semantic evidence + slow verification |
| `class_4_irreversible_high_impact` | Irreversible, high blast radius | Publish a release artifact | All of the above + signed human approval bound to the exact effect revision |

Reference adapters shipped in core, with their default class mapping:

| Adapter | Kind | Default class | Mechanism |
| :--- | :--- | :--- | :--- |
| `Autonomic.Adapters.Git` | `git_commit` | 3 | Replays an exact patch against an exact base OID in a trusted worktree, compare-and-swap ref update |
| `Autonomic.Adapters.GitRemote` | `git_remote` | 3 | Force-with-lease against `expected_remote_oid`, URL and ref allowlists |
| `Autonomic.Adapters.HTTP` | `http_read` / `http_mutation` | 2 / 3 | Owns DNS, TLS, redirects (`autoredirect: false`), method/host/path allowlists, body and response caps, broker-selected credentials, idempotency headers, rate limits |
| `Autonomic.Adapters.Artifact` | `publish` | 4 | Create-only / content-idempotent publication into a trusted directory |

The worker never names a host path, base URL or credential. It supplies a bounded, target-relative request; trusted configuration supplies everything else.

---

## The commit horizon

```text
proposed → prepared → evaluating → ready → commit_intent → committing → committed
    │           │          │          │            │
    └───────────┴──────────┴──────────┴────────────┴──→ aborted | expired | stale
                                                   └──→ commit_unknown | failed
```

Every commit-sensitive decision is evaluated against an immutable version vector captured at `prepare`:

```text
V = (episode_id, epoch, policy_version, snapshot_ancestry,
     trajectory_version, trajectory_regime, lease_id, effect_revision)
```

At commit the broker takes row locks in a fixed **episode → effect → lease** order, re-reads durable state, and requires all of:

1. episode still active
2. `effect.epoch == current_episode_epoch`
3. lease exists, unexpired, same epoch
4. policy version unchanged or explicitly declared compatible
5. current snapshot descends from the prepared ancestry
6. trajectory regime still permitted for this effect class
7. verification / approval records match the exact effect **revision** and epoch
8. effect not expired or superseded
9. adapter-specific target preconditions still hold

Any mismatch returns `{:error, :stale_authority}` or a more specific conflict. Stale authorization is never silently refreshed — the worker re-proposes against current state.

**`commit_unknown` is a first-class outcome.** `commit_intent` is persisted *before* adapter actuation, so a crash inside the window is recorded rather than lost. Adapters must return `{:unknown, reason}` whenever execution may have occurred but cannot be proven, and `reconcile/2` must distinguish `{:committed, receipt}`, `:not_committed` and `{:unknown, reason}` without mutating blindly. Git reconciliation searches for the effect identity marker in the commit trailer and reports unrelated ref movement as ambiguous instead of claiming success. See [`docs/runbooks/COMMIT_UNKNOWN.md`](docs/runbooks/COMMIT_UNKNOWN.md).

---

## Install

Add only the packages your environment needs. Core has no dependency on Linux, Ecto, PostgreSQL or the semantic SDK.

```elixir
# mix.exs
defp deps do
  [
    {:autonomic, "~> 0.1.0"},           # required: kernel, broker, contracts
    {:autonomic_linux, "~> 0.1.0"},     # optional: Linux execution domains
    {:autonomic_postgres, "~> 0.1.0"},  # optional: durable authority store
    {:autonomic_typesafe, "~> 0.1.0"}   # optional: semantic sensor bank
  ]
end
```

Wire the implementations — core resolves them through configuration, never through compile-time dependencies:

```elixir
# config/runtime.exs
config :autonomic,
  store: Autonomic.Store.Postgres,
  domain_backend: Autonomic.Linux.Backend,
  sensor: Autonomic.Typesafe.Sensor,
  state_dir: "/var/lib/autonomic/kernel",
  targets: %{
    "authoritative_repo" => %{
      "repo" => "/srv/autonomic/repos/example.git",
      "ref" => "refs/heads/main",
      "allowed_refs" => ["refs/heads/main"],
      "allowed_paths" => ["lib/**"],
      "forbidden_paths" => ["test/**", ".env", "**/*secret*"],
      "verify_argv" => [["mix", "test"]]
    }
  }

config :autonomic_linux,
  enabled: true,
  executable: "/usr/local/libexec/autonomic_launcher",
  rootfs: "/opt/autonomic/rootfs",
  state_root: "/var/lib/autonomic",
  sudo: true

config :autonomic_postgres, Autonomic.Store.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 10
```

Then provision the host and prove it:

```bash
sudo bash scripts/provision_host.sh          # Debian/Ubuntu packages only
bash scripts/build_launcher.sh /tmp/autonomic_launcher
sudo install -D -m 0755 /tmp/autonomic_launcher /usr/local/libexec/autonomic_launcher
sudo python3 scripts/build_rootfs.py --destination /opt/autonomic/rootfs \
  --otp "$(asdf where erlang 29.0.6)" --elixir "$(asdf where elixir 1.20.4-otp-29)"
bash scripts/preflight.sh
mix ecto.migrate -r Autonomic.Store.Repo
```

A preflight pass is necessary but not sufficient. See [Verification](#verification-and-conformance).

---

## Worked example

The full lifecycle, adapted from the reference acceptance scenario: start an episode, let the worker repair a failing test inside its disposable overlay, then move the verified patch across the commit horizon into the authoritative repository.

```elixir
alias Autonomic.{EffectBroker, EpisodeController, EpisodeSpec, EpisodeSupervisor, ExecutionDomain}

spec = %EpisodeSpec{
  id: Autonomic.Canonical.id(),
  origin_intent: "Fix the failing test in test/auth_test.exs without changing fixtures or secrets.",
  workspace: %{"lower" => "/srv/worker-clones/example", "base_ref" => base_oid},
  policy: %{
    "id" => "coding-agent-policy",
    "version" => 1,
    "max_effect_class" => 3,
    "capabilities" => [
      %{"kind" => "git_commit", "scope" => %{"id" => "authoritative_repo"}, "max_class" => 3}
    ],
    "semantic" => %{"max_risk" => 0.65}
  },
  hard_envelope: %{
    "max_effect_class" => 3,
    "capabilities" => [
      %{"kind" => "git_commit",
        "scope" => %{"id" => "authoritative_repo"},
        "constraints" => %{"max_effect_class" => 3}}
    ]
  },
  resource_limits: %{"cpu_quota" => 2, "memory_mb" => 1024, "pids" => 128, "worker_timeout_ms" => 120_000},
  requested_effect_ceiling: :class_3_authoritative_external_mutation
}

{:ok, _pid} = EpisodeSupervisor.start_episode(spec)
{:running, %{epoch: 1}} = EpisodeController.state(spec.id)
runtime = EpisodeController.trusted_runtime(spec.id)

# Class 1: mutate the disposable overlay. Nothing here touches the authoritative repo.
{:ok, %{exit_status: 0}} =
  runtime.domain.backend.exec(runtime.domain, %ExecutionDomain.Command{
    argv: ["mix", "test"], cwd: "/workspace", timeout_ms: 60_000
  })

{:ok, diff} =
  runtime.domain.backend.exec(runtime.domain, %ExecutionDomain.Command{
    argv: ["git", "diff", "--binary", "--", "lib/auth.ex"], cwd: "/workspace", timeout_ms: 10_000
  })

# Class 3: propose. The patch and base OID are exact; the digest is bound to the revision.
{:ok, effect} =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :git_commit,
    target_id: "authoritative_repo",
    target: %{"base_ref" => base_oid, "ref" => "refs/heads/main", "message" => "fix auth token validation"},
    payload: diff.metadata.stdout
  })

{:ok, %{state: :ready}}     = EffectBroker.evaluate(effect.id)  # semantic + slow verification
{:ok, %{state: :committed}} = EffectBroker.commit(effect.id)    # locks, re-reads, commit_intent, actuate

EpisodeController.complete(spec.id)
```

Slow verification replays that exact patch in a *separate clean disposable domain* — repository code is never executed on the host. The resulting commit carries an `Autonomic-Effect: <effect_id>` trailer, which is what reconciliation searches for if the commit outcome is ever ambiguous.

### Class 4 requires a signature bound to the exact revision

`EffectBroker.commit/1` on a Class 4 effect fails until an Ed25519-signed approval matching the effect id, revision, epoch and payload digest is supplied to `evaluate/2`:

```elixir
doc = %{
  "effect_id" => effect.id,
  "effect_revision" => effect.revision,
  "episode_id" => effect.episode_id,
  "epoch" => effect.epoch,
  "payload_digest" => effect.payload_digest,
  "decision" => "allow"
}

signature =
  :crypto.sign(:eddsa, :none,
    "autonomic.human-approval.v1\n" <> Autonomic.Canonical.json(doc),
    [operator_private_key, :ed25519]
  ) |> Base.encode64()

{:ok, %{state: :ready}} =
  EffectBroker.evaluate(effect.id,
    human_approval: %{document: doc, signature: signature, key_id: "operator", source_ref: "operator:oncall"}
  )
```

Re-propose the payload and the revision changes; the old signature no longer applies. Approval cannot be harvested and replayed against different bytes.

---

## Worker protocol

Inside the sandbox the agent sees exactly one channel: `/run/autonomic/effect.sock`. No host home, no `~/.ssh`, no cloud credentials, no Docker socket, no authoritative checkout. Direct `AF_INET`/`AF_INET6` `socket()` is trapped with `SIGSYS`, so an attempt becomes deterministic evidence rather than a silent failure.

The protocol is one length-prefixed JSON request per connection: a 4-byte big-endian length, then the payload, capped at 1 MiB in both directions.

```jsonc
// → request
{
  "protocol": 1,
  "request_id": "01JB…",
  "epoch": 3,                       // rejected as :stale_request_epoch if not current
  "action": "prepare",              // prepare | evaluate | commit | abort | status | fetch_response
  "lease_id": "…",
  "kind": "http_read",
  "target_id": "docs_read",         // names trusted config, never a URL
  "target": {"method": "GET", "path": "/reference/api.json"},
  "payload_b64": ""
}

// ← response
{"ok": true, "result": {"id": "…", "epoch": 3, "revision": 1, "class": "class_2_…", "state": "prepared",
                        "payload_digest": "sha256:…"}}
```

Response bodies from brokered HTTP reads never stream into the sandbox directly. They land in the trusted content-addressed payload store and are read back through bounded `fetch_response` chunks with an offset, a limit, a total size and a body digest — so the worker cannot use a response as an unbounded side channel.

Any authority claim the worker makes in a frame is checked against the durable store before it means anything.

---

## Packages

Four independently versioned, independently publishable Mix projects in a Poncho layout. Adapters depend on core; adapters have no production dependency on one another.

| Package | Purpose | Adds dependencies | Docs |
| :--- | :--- | :--- | :--- |
| **`autonomic`** | Kernel semantics, episode lifecycle, `EffectBroker`, `AuthorityGovernor`, `Homeostat`, `SystemRegulator`, contracts, reference adapters | `finch`, `jason`, `gen_stage`, `telemetry` | [Docs](https://hexdocs.pm/autonomic) |
| **`autonomic_linux`** | `ExecutionDomain` for Linux: namespaces, cgroup v2, seccomp, overlayfs, Rust launcher, host preflight | Rust toolchain, privileged host | [Docs](https://hexdocs.pm/autonomic_linux) |
| **`autonomic_postgres`** | `Store` implementation: epochs, leases, effects, decisions, checkpoints, recovery lineage, event ledger | `ecto_sql`, `postgrex`, PostgreSQL 16+ | [Docs](https://hexdocs.pm/autonomic_postgres) |
| **`autonomic_typesafe`** | `SemanticSensor` bank, evidence redaction and budgeting, model-drift and contract identity | `typesafe_sdk` | [Docs](https://hexdocs.pm/autonomic_typesafe) |

The four extension points are plain behaviours — bring your own backend without forking core:

```elixir
@behaviour Autonomic.ExecutionDomain  # create/exec/signal/checkpoint/restore/destroy/inspect_domain
@behaviour Autonomic.Store            # current_epoch/advance_epoch/put_lease/put_effect/append_event/…
@behaviour Autonomic.SemanticSensor   # observe(ObservationFrame.t(), opts) :: {:ok, [SemanticObservation.t()]}
@behaviour Autonomic.EffectAdapter    # validate/2, commit/2, reconcile/2
```

### Semantic sensor bank

The semantic layer is not one `safe?` classifier. It is a versioned manifest of bounded sensors with a SHA-256 contract id persisted alongside every observation:

`scope_drift` · `authority_escalation` · `evidence_sufficiency` · `irreversibility` · `trajectory_regime`

An unknown or missing required answer is treated as **semantic unavailability**, never as an implicit "safe". A response model outside the configured `allowed_models` set is semantic-contract drift. Evidence is secret-redacted and byte-budgeted before it leaves the trusted plane.

---

## Configuration

| Key | Default | Purpose |
| :--- | :--- | :--- |
| `:store` | — | `Autonomic.Store` implementation |
| `:domain_backend` | — | `Autonomic.ExecutionDomain` implementation |
| `:sensor` | — | `Autonomic.SemanticSensor` implementation |
| `:state_dir` | `"var"` | Trusted kernel state root: sockets (`0700`), payload store, snapshots |
| `:targets` | `%{}` | Trusted target definitions — the only source of paths, URLs and credential references |
| `:effect_adapters` | Git / GitRemote / HTTP / Artifact | `kind => {module, default_class}` |
| `:effect_concurrency` | `8` | Bound on concurrent broker orchestration; excess is rejected with `:effect_broker_saturated` rather than queued |
| `:sensor_queue` | `64` | Sensor backpressure depth; critical deterministic frames are never intentionally dropped |
| `:speculation_ms` | `15_000` | Speculation window before the commit horizon |
| `:max_repairs` | `3` | Repair attempts before containment |
| `:owner_ttl_ms` | `15_000` | Ownership lease TTL |
| `:automatic_verification` | `true` | Run slow verification automatically at `evaluating` |
| `:policy_keys` / `:decision_keys` / `:signer` | `%{}` | Ed25519 verification keys for signed policy and decisions |

`:autonomic_linux` takes `enabled`, `executable`, `rootfs`, `state_root`, `sudo`. `:autonomic_typesafe` takes `api_key`, `model`, `allowed_models`, `required_capabilities`, `timeout_ms`, `slow_timeout_ms`, `evidence_limit`, `request_limit`. A complete operator template lives in [`config/autonomic.example.json`](config/autonomic.example.json).

---

## Invariants

These five statements are what the acceptance gates exist to falsify.

1. **No unmediated irreversible effects.** Class 2+ external mutations cross `Autonomic.EffectBroker`. Sandboxed workers have no routable external networking and no authoritative repository mount.
2. **Semantic evidence cannot exceed deterministic authority.** The sensor bank is an observation source. It cannot mint capabilities, override a deterministic boundary violation, or expand a signed hard envelope.
3. **Authority is epoch-fenced.** Leases, execution domains, effect revisions, decisions, checkpoints and commits bind to a durable episode epoch in PostgreSQL.
4. **Speculation precedes commitment.** Worker filesystem mutations are disposable within an overlayfs upperdir. Class 3/4 effects cross the durable commit horizon only on exact cryptographic and policy evaluation.
5. **Worker state is disposable; kernel state is authoritative.** Worker processes, cgroups and overlays may be destroyed at any moment. The PostgreSQL ledger and digest-verified checkpoints reconstruct the episode.

---

## Security posture

The threat model assumes the worker, the repository contents, stdout/stderr, tool output and semantic evidence may all be hostile. [`docs/spec/07_THREAT_MODEL_AND_SECURITY.md`](docs/spec/07_THREAT_MODEL_AND_SECURITY.md) is normative; [`docs/SECURITY.md`](docs/SECURITY.md) summarizes.

| Boundary | Enforcement |
| :--- | :--- |
| **Kernel / DB** | PostgreSQL is the authority for epoch, policy version, leases, effect state, decisions, checkpoints and recovery lineage. DB loss blocks authoritative commits; no cache is ever promoted to authority. |
| **OS** | Namespaces, cgroup v2, read-only rootfs, overlayfs, `PR_SET_NO_NEW_PRIVS`, seccomp, network namespace. The reference filter denies namespace/mount/ptrace/key/BPF/perf escape syscalls and traps INET sockets. |
| **Effect** | Only trusted adapters receive target configuration and credentials. The worker supplies a bounded target-relative request and payload bytes — never a host path or credential. |
| **Semantic** | `Autonomic.Typesafe.Evidence` redacts secret-shaped fields and enforces a byte budget before evaluation. Unknown required tags, model drift and outages fail closed as degradation. |
| **Launcher** | A small external privileged process. Packet-framed JSON with protocol versioning, per-action allowed fields, request/reply limits and structural argv/env transfer. It does **not** execute worker-supplied shell strings. Each lifecycle request uses a one-shot Port so a running worker cannot block a concurrent destroy or freeze. |

The launcher should be given a narrow sudoers rule for its exact immutable path, or the kernel should run under an already-privileged service account with `AUTONOMIC_NO_SUDO=1`. Workers must never be able to execute the launcher binary.

> **A source audit is not a sandbox qualification.** Deploy only after every mandatory gate in [`docs/spec/11_ACCEPTANCE_GATES.md`](docs/spec/11_ACCEPTANCE_GATES.md) is green on the intended kernel, cgroup and filesystem host, and the live semantic gate has run with non-secret provenance.

Operational runbooks: [`COMMIT_UNKNOWN`](docs/runbooks/COMMIT_UNKNOWN.md) · [`DB_OUTAGE`](docs/runbooks/DB_OUTAGE.md) · [`SANDBOX_ESCAPE`](docs/runbooks/SANDBOX_ESCAPE.md) · [`SEMANTIC_OUTAGE`](docs/runbooks/SEMANTIC_OUTAGE.md)

---

## Verification and conformance

Safety claims here are gates, not prose. `scripts/qc` executes them and writes a machine-readable conformance report that binds the source tree and every executed gate log by SHA-256; `release_ready` is only true when every mandatory gate actually ran and passed on that host.

Selected gates from [`artifacts/conformance_report.json`](artifacts/conformance_report.json):

| Gate | What it proves |
| :--- | :--- |
| `linux_namespaces_cgroup_seccomp_overlay` | Containment holds on the real kernel, not a mock |
| `old_process_fork_cleanup` | A forked descendant cannot survive domain destruction |
| `overlay_rollback` | The disposable upperdir is genuinely gone after repair |
| `postgresql_epoch_commit_race` | Concurrent commits cannot both win across an epoch advance |
| `stale_epoch_race` | A prepared effect from a fenced epoch cannot commit |
| `broker_crash_after_external_mutation_reconciliation` | A crash inside the commit window reconciles to a provable outcome |
| `git_authoritative_commit_reconciliation` | Ambiguous ref movement is reported as ambiguous, not as success |
| `db_outage_blocks_authority` | Authority actually stops when durability stops (real ephemeral cluster) |
| `af_unix_effect_broker` | Worker ingress honors epoch, framing and bounds |
| `sensor_poisoning` | Hostile evidence cannot escalate authority |
| `semantic_outage_degradation` | Sensor loss degrades autonomy instead of failing open |
| `backpressure_load` | Saturation rejects rather than queues unboundedly |
| `class4_human_horizon` | Class 4 cannot cross without an exact signed approval |
| `coding_agent_violation_repair_epoch2` | Full hostile scenario: seccomp trip → fence → destroy → restore → commit under epoch 2 |

Run everything:

```bash
AUTONOMIC_LINUX=1 \
AUTONOMIC_TEST_DATABASE_URL=ecto://autonomic:autonomic@127.0.0.1:5433/autonomic_test \
./scripts/qc --strict
```

CI is deliberately tiered: `ci.yml` covers non-privileged BEAM/PostgreSQL/Rust gates; `privileged-linux.yml` runs containment only on an operator-controlled runner labeled `autonomic-privileged`; `live-typesafe.yml` is manual. Hosted CI is never treated as proof of cgroup, namespace or seccomp behavior, and no workflow substitutes a fixture for either.

---

## Repository layout

```text
autonomic/
├── packages/
│   ├── autonomic/                  # Core OTP control plane, broker, contracts, homeostat
│   ├── autonomic_linux/            # Namespaces, cgroup v2, seccomp, overlayfs + Rust launcher
│   ├── autonomic_postgres/         # Authority store, epoch fencing, transactional ledger
│   └── autonomic_typesafe/         # Semantic sensor bank, drift detection, evidence redaction
├── integration/
│   └── autonomic_acceptance/       # Cross-package end-to-end acceptance suite
├── scripts/
│   ├── qc                          # Monorepo test & quality-control orchestrator
│   ├── release                     # Deterministic Hex staging, build and inspection
│   ├── lint_package_boundaries.py  # Architectural boundary verification
│   ├── build_launcher.sh           # Native Rust launcher build
│   ├── build_rootfs.py             # Reproducible offline verification rootfs
│   ├── preflight.sh                # Host capability check
│   ├── provision_host.sh           # Debian/Ubuntu host packages
│   ├── run_reference.sh            # End-to-end coding-agent reference scenario
│   └── run_db_outage_gate.sh       # PostgreSQL fault-injection gate
├── docs/                           # Architecture, security, operations, runbooks, normative spec
├── artifacts/                      # Conformance report, dependency and package graphs
└── test/fixtures/coding_agent/     # Deliberately hostile fixture repository
```

---

## Development and quality control

Each project is self-contained — there is no root umbrella. `scripts/` coordinates multi-package operations.

```bash
# Per-package
cd packages/autonomic && mix test

# Store, races, reconciliation, AF_UNIX
cd packages/autonomic_postgres && mix test test/integration --include postgres --exclude linux --exclude reference

# Linux containment (privileged host)
cd packages/autonomic_linux && AUTONOMIC_LINUX=1 mix test test/integration --include linux

# Live semantic gate
cd packages/autonomic_typesafe && TYPESAFE_API_KEY=… mix test test/live_gate_test.exs --include live

# Full coding-agent reference (normal + hostile)
cd integration/autonomic_acceptance && AUTONOMIC_LINUX=1 mix test test/coding_agent_test.exs \
  --include reference --include postgres --include linux
```

Quality control and release staging:

```bash
./scripts/qc --strict                        # all mandatory gates
./scripts/qc --handoff                       # honest pending status on an under-provisioned host
./scripts/qc --package autonomic_postgres    # single package
python3 scripts/lint_package_boundaries.py   # zero unauthorized cross-adapter dependencies

./scripts/release check                      # boundary + metadata pre-flight
./scripts/release stage 0.1.0                # rewrite path deps → versioned Hex deps
./scripts/release build 0.1.0                # build tarballs
./scripts/release inspect 0.1.0              # unpack and audit for release cleanliness

uv run --no-project python scripts/verify_packages.py  # resolve/compile/test outside the source tree
```

`--handoff` never sets `release_ready=true` when gates are skipped. Staging rejects residual workspace paths, mismatched core versions and generated artifacts.

---

## Documentation map

**Start here** — [Architecture](docs/ARCHITECTURE.md) · [Security model](docs/SECURITY.md) · [Operations](docs/OPERATIONS.md) · [Development](docs/DEVELOPMENT.md)

**Building on it** — [Effect adapter authoring](docs/EFFECT_ADAPTERS.md) · [Semantic sensors](docs/TYPESAFE_SENSORS.md) · [Persistence and recovery](docs/PERSISTENCE_RECOVERY.md) · [Host provisioning](docs/HOST_PROVISIONING.md)

**Normative specification** — [`docs/spec/`](docs/spec/README.md): system architecture, subsystem specifications, interfaces and schemas, effect transaction protocol, threat model, durability ledger, testing and conformance, acceptance gates, TypeSafe SDK integration.

**Per-package guides** — each package ships its own `guides/` directory rendered into HexDocs.

---

## Requirements

| Component | Version | Notes |
| :--- | :--- | :--- |
| Elixir / OTP | 1.20.4 / 29.0.6 | Pinned in `.tool-versions` |
| Rust | 1.90.0 | Launcher only; pinned in `rust-toolchain.toml` |
| PostgreSQL | 16+ | Real integration dependency, not a mock |
| Linux kernel | cgroup v2 unified, user/mount/PID/net/IPC/UTS namespaces, overlayfs, seccomp | Dedicated host or VM |

Core alone (`autonomic`) compiles and tests on any BEAM platform. The Linux backend requires a privileged Linux host; the reference rootfs builder produces an offline runtime with a recorded SHA-256 manifest and no host credentials.

---

## Status

Version `0.1.0`. All four packages are staged for Hex with independent lockfiles, metadata, licenses, READMEs and guides; the strict conformance run reports `release_ready: true` with every mandatory gate executed and passed on a provisioned host. Package boundaries are lint-enforced: adapters depend on core and never on each other.

Contributions are welcome — new `ExecutionDomain`, `Store`, `SemanticSensor` and `EffectAdapter` implementations are the intended extension surface. A new adapter must never reduce the required decision floor for its effect class.

---

## License

MIT. See `LICENSE`.
