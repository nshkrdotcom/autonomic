# Epoch Fencing and Outage Recovery

## Epoch fencing

The episode epoch is the durable generation boundary for authority. Leases, execution domains, effects, decisions, and checkpoints are expected to refer to the current epoch.

When containment or repair advances the epoch, stale work must not regain authority merely because a process is still alive.

## Semantic decisions are epoch-bound

TypeSafe-backed semantic decisions do not float independently of the authority model. An EffectBroker decision is attached to the exact effect revision and version vector, including the epoch and trajectory version. If the episode advances, the old semantic decision is no longer sufficient for a new proposal.

This matters because semantic evidence can become stale even when its text still looks relevant: the worker may be a new generation, the policy may have changed, or the trajectory may have moved.

## PostgreSQL outage behavior

If PostgreSQL becomes unreachable, Autonomic cannot prove current epoch/lease/commit authority. The system therefore fails closed for authoritative mutations rather than promoting cached process state to truth.

Semantic availability does not compensate for database unavailability. A healthy TypeSafe answer cannot establish a current epoch or durable commit horizon.

## Recovery

After connectivity returns:

1. restore access to durable episode/effect state;
2. reconcile pending `commit_intent` / `committing` / `commit_unknown` effects;
3. recover or advance episode authority conservatively;
4. resume new sensitive decisions only when the durable version vector is again provable.

Semantic evaluation can then operate against current frames/revisions instead of reusing stale observations.
