# 08 — Durability, Ledger, and Recovery

## 1. Durable state is part of the security model

The authoritative state of an episode cannot exist only in a GenServer heap. OTP process state is intentionally disposable. PostgreSQL is the reference durable authority store for:

- episode identity and current epoch;
- signed policy version/hash;
- current ownership/driver lease;
- capability leases and revocations;
- checkpoints and ancestry;
- effect proposals and transitions;
- verifier/human approvals;
- authoritative audit events;
- commit attempts and reconciliation state.

High-volume raw observations may be stored separately or compacted, but every observation that materially changes authority/regime/effect disposition must have a durable evidence reference.

## 2. Separation of control state and telemetry

Do not make every stdout chunk a serializable control-plane transaction.

Use two logical lanes:

### Control lane — transactional

Small, security-critical records:

- current epoch;
- active policy version;
- current checkpoint;
- active leases;
- effect state;
- approvals;
- episode ownership;
- containment/completion state.

### Evidence lane — append-oriented

- normalized observation frames;
- TypeSafe semantic observations and provenance (sensor-bank version, semantic-contract id, SDK version, requested/actual model, request id, usage/retries/timing);
- resource snapshots;
- diff summaries;
- operator notes;
- target receipts;
- selected raw evidence references.

The control lane stores references/hashes to evidence needed to explain decisions.

## 3. Reference relational model

### `episodes`

```text
id UUID/String PK
state
current_epoch BIGINT NOT NULL
policy_id
policy_version BIGINT NOT NULL
policy_digest
current_checkpoint_id
trajectory_version BIGINT NOT NULL
trajectory_regime
owner_node
owner_lease_expires_at
inserted_at/updated_at
```

Constraint: `current_epoch >= 1` once bootstrapped. Epoch updates are monotonic only.

### `capability_leases`

```text
id PK
episode_id FK
epoch BIGINT
policy_version BIGINT
capabilities JSONB
max_effect_class
issued_at
expires_at
revoked_at
authority_source
authority_ref
reason
```

Index `(episode_id, epoch, revoked_at, expires_at)`.

### `checkpoints`

```text
id PK
episode_id FK
epoch
domain_generation
parent_checkpoint_id
filesystem_ref
filesystem_digest
git_base_ref
git_patch_digest
trajectory_version
policy_version
environment_digest
dependency_lock_digest
trust_level
created_at
```

Checkpoint ancestry is immutable.

### `effects`

```text
id PK
episode_id FK
epoch
lease_id FK
revision
class
kind
target JSONB
payload_ref
payload_digest
reversible BOOLEAN
state
version_vector JSONB
idempotency_key
commit_attempt_id
expires_at
committed_at
external_receipt_ref
failure JSONB
inserted_at/updated_at
```

Unique `(episode_id, id)` and unique idempotency key where used.

### `effect_decisions`

```text
id PK
effect_id FK
effect_revision
kind ENUM('deterministic','semantic','slow_verifier','human')
decision
source_ref
epoch
policy_version
trajectory_version
snapshot_ref
expires_at
payload_digest
evidence_ref
created_at
```

Old decisions remain for audit but cannot authorize a new revision.

### `episode_events`

```text
id BIGSERIAL PK
episode_id
sequence BIGINT
kind
payload JSONB
previous_hash
entry_hash
created_at
```

Unique `(episode_id, sequence)`. Hash chaining is recommended for tamper-evident audit export, but database authorization and backups remain the integrity foundation.

### `observation_frames`

Partitionable table containing normalized frames or references to a larger evidence store.

## 4. Epoch advancement transaction

Pseudocode:

```elixir
Repo.transaction(fn ->
  episode =
    Episode
    |> where([e], e.id == ^episode_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()

  new_epoch = episode.current_epoch + 1

  Repo.update!(change(episode, current_epoch: new_epoch))

  from(l in CapabilityLease,
    where: l.episode_id == ^episode_id and l.epoch < ^new_epoch and is_nil(l.revoked_at)
  )
  |> Repo.update_all(set: [revoked_at: now])

  from(e in Effect,
    where:
      e.episode_id == ^episode_id and
      e.epoch < ^new_epoch and
      e.state in ^[:proposed, :prepared, :evaluating, :ready]
  )
  |> Repo.update_all(set: [state: :stale])

  Ledger.append_locked!(episode_id, :epoch_advanced, %{...})

  new_epoch
end, isolation: :serializable)
```

Implementation may use `FOR UPDATE` under PostgreSQL's default isolation if all conflicting effect/epoch transitions lock the same episode row in a consistent order. The conformance suite must prove the chosen isolation strategy under actual concurrency.

## 5. Effect commit locking order

To prevent deadlocks and stale decisions, use one documented lock order everywhere:

1. episode row;
2. effect row;
3. lease row if a row lock is needed;
4. target-specific local lock/ref lock.

Never invert this order in epoch advancement, commit, abort, or reconciliation.

## 6. Durable commit intent

Before invoking a Class 3/4 adapter, transactionally write:

```text
state = :commit_intent
commit_attempt_id = globally unique id
idempotency_key = stable per logical effect
version_vector_at_commit = current validated vector
commit_started_at
```

Only after this transaction succeeds may the adapter actuate the target.

## 7. Idempotency strategy

Three target categories:

### A. Native idempotency

Provider supports idempotency key. Use `effect.id` or a derived stable key. Retry with the same key only after reconciliation indicates safe retry.

### B. Compare-and-swap target

Git refs and similar targets can use expected-old-value semantics. The effect carries expected base/ref and commit fails on drift.

### C. No idempotency/reconciliation

Treat ambiguity as `:commit_unknown`. Never automated blind retry for Class 4. Operator runbook required.

## 8. Node crash recovery

On application start:

1. acquire/renew node eligibility;
2. scan owned/claimable nonterminal episodes;
3. reclaim one episode using durable ownership lease;
4. reconstruct controller/Homeostat/Authority state from durable records;
5. reconcile nonterminal effect commit intents before spawning a new worker;
6. inspect/quarantine any surviving host domain from previous node incarnation;
7. advance epoch if old domain survival cannot be disproven;
8. restore last stable checkpoint;
9. resume only after all authority invariants pass.

Worker restart must come **after** effect reconciliation, otherwise a new worker can conflict with an ambiguous old external mutation.

## 9. Episode ownership

For a single-node first implementation, ownership is trivial but the schema should still support future failover.

For multi-node operation, use a durable owner lease:

```text
owner_node
owner_lease_token
owner_lease_expires_at
```

Only the owner may drive the episode controller. Renewal failure moves the local controller to yield/containment. A new owner advances epoch unless the previous domain is proven dead and policy explicitly permits same-epoch takeover; the safe default is advance.

## 10. Store partition behavior

If a BEAM node loses PostgreSQL:

- it cannot prove current epoch;
- it cannot authorize Class 2+ external effect commits;
- it cannot expand/renew sensitive leases past a small locally cached expiry;
- it may let Class 0/1 compute finish only under an explicit offline budget;
- if owner lease expires, it must kill/yield the domain.

Availability does not outrank authority correctness.

## 11. Checkpoint durability

Filesystem snapshot bytes may live outside Postgres (local content-addressed store, object storage, volume backend). Postgres stores immutable digest/reference metadata.

A checkpoint becomes `:stable` only after:

1. backend produced snapshot;
2. digest computed/verified;
3. durable checkpoint row committed;
4. episode current checkpoint updated transactionally;
5. ledger event appended.

If bytes exist but metadata transaction fails, bytes are orphan candidates for garbage collection, not trusted checkpoints.

## 12. Observation retention

Retention tiers:

- security decisions and effect metadata: long-lived audit retention;
- normalized semantic answers: retained with model/schema versions;
- raw source/output windows: shortest practical retention, policy-controlled, encrypted, secret-redacted;
- high-volume kernel telemetry: aggregate/compact after security window unless incident hold applies.

## 13. Ledger properties

The authoritative ledger must provide:

- per-episode monotonic sequence;
- immutable historical events;
- actor/source identity;
- timestamps from trusted host;
- references to policy/model/evidence versions;
- correlation to effect/lease/checkpoint ids;
- no raw credentials.

Hash chaining is useful for export/tamper evidence but does not turn a compromised database host into a trusted witness. Backups, access control and external audit export remain necessary.

## 14. Garbage collection

GC must never race active authority.

Eligible only when:

- episode terminal or checkpoint superseded outside retention window;
- no active effect references payload/snapshot;
- no incident/legal hold;
- digest/reference count reaches zero.

Sandbox upperdirs are disposable and should be removed eagerly after proven domain teardown; durable checkpoint blobs follow policy retention.
