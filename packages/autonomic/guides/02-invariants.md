# Non-Negotiable Invariants

The Autonomic architecture is governed by five mandatory invariants:

1. **No unmediated irreversible effects.** Class 2+ external effects cross `Autonomic.EffectBroker`; the sandbox has no routable network and no authoritative repository mount.
2. **Semantic evidence cannot exceed deterministic authority.** Sensors provide evidence. They cannot mint capabilities, override a deterministic boundary violation, or expand the signed hard envelope.
3. **Authority is epoch-fenced.** Leases, domains, effect revisions, decisions, checkpoints, and commits bind to a durable episode epoch.
4. **Speculation precedes commitment.** Isolated edits/tests are disposable; Class 3/4 mutations cross a durable commit horizon only after exact-version authorization.
5. **Worker state is disposable; kernel state is authoritative.** The worker/cgroup/overlay may be killed. The store plus trusted checkpoint metadata reconstruct the episode.
