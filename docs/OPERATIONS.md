# Operations

## Start-of-day checks

Run `scripts/preflight.sh`, verify PostgreSQL connectivity/migrations, verify the launcher executable checksum/ownership, ensure `/sys/fs/cgroup` is cgroup v2 and writable through the intended privilege path, and verify the configured rootfs contains `/workspace`, `/run`, `/tmp`, and `/proc` mountpoints but no secrets.

## `commit_unknown`

Do not retry automatically. Freeze new sensitive work for the episode, inspect the effect's `commit_attempt_id`, exact payload digest/version vector, target receipt/reconciliation evidence and adapter-specific authoritative target. Run adapter reconciliation. Mark committed only with positive target evidence; mark not-committed only when the adapter can prove it. Otherwise keep `commit_unknown` and require an operator decision. See `docs/runbooks/COMMIT_UNKNOWN.md`.

## Semantic outage/model drift

Semantic evidence is not authority, but Class 3/4 defaults require it. When TypeSafe is unavailable, unknown, or violates the configured model contract, SystemRegulator constrains sensitive work. Do not bypass the semantic requirement to restore throughput. See `docs/runbooks/SEMANTIC_OUTAGE.md`.

## Database outage

Stop new Class 2+ commits and lease renewal requiring durable proof. If ownership/epoch correctness cannot be established, contain/kill the domain. Never promote an in-memory cache to authority. See `docs/runbooks/DB_OUTAGE.md`.

## Suspected sandbox escape

Advance/fence epoch durably if the DB is trustworthy, freeze/kill the full cgroup, require emptiness proof, quarantine state/rootfs, rotate broker credentials reachable by configured targets, preserve event/evidence records, and rebuild from a known-good rootfs/checkpoint. See `docs/runbooks/SANDBOX_ESCAPE.md`.
