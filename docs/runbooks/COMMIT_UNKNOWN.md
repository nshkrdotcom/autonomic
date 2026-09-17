# Runbook: `commit_unknown`

1. Block new sensitive effects for the episode/target.
2. Record effect ID, commit-attempt ID, idempotency key, exact revision, payload digest and epoch. Do not copy credentials into notes.
3. Invoke the adapter's read-only reconciliation path.
4. If the target proves the exact mutation committed, reconcile to `committed` with receipt evidence.
5. If the target proves it did not commit and policy permits retry, reconcile to `ready`; the next commit creates a new durable attempt while preserving the same logical idempotency identity.
6. If proof is unavailable, leave `commit_unknown`. Class 4 is never blindly retried.
