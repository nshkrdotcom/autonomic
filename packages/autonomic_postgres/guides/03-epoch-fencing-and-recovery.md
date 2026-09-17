# Epoch Fencing and Outage Recovery

## Epoch Fencing

When an episode advances its epoch (e.g. after a repair or violation), `autonomic_postgres` increments the `current_epoch` in PostgreSQL within a strict serial transaction. Any worker trying to complete an effect or assert a capability granted under an older epoch receives an epoch violation error.

## Outage Recovery

If PostgreSQL becomes temporarily unreachable, `autonomic` fails closed: no uncommitted effects can proceed, and workers cannot acquire new capabilities. When database connectivity resumes, the `EffectBroker` queries pending effects in state `:committing` or `:commit_unknown` and triggers reconciliation adapters.
