# Runbook: semantic outage/model drift

1. Inspect `Autonomic.Typesafe.Bank.status/0` and SystemRegulator mode.
2. Check TypeSafe credentials/network without logging the API key.
3. Run the live gate with synthetic evidence only.
4. If actual-model drift is reported, compare it with the operator `allowed_models` contract; update policy/config deliberately rather than auto-accepting drift.
5. Keep Class 3/4 effects yielding while required semantic evidence is unavailable. Deterministic denials continue to preempt immediately.
