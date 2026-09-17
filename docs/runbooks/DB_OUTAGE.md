# Runbook: PostgreSQL outage

1. Treat current epoch/lease/commit authority as unprovable.
2. Stop Class 2+ commit authorization and do not issue/renew sensitive leases from cache.
3. If an effect had durable `commit_intent` before the outage, do not retry it; reconcile after DB recovery.
4. If owner lease/epoch safety cannot be established, contain the worker domain.
5. Restore PostgreSQL, verify migrations and event-chain continuity, reconcile pending commit intents, then resume admission.
