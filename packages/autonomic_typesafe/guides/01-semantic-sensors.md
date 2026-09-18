# TypeSafe/Jev Semantic Sensor Bank

`autonomic_typesafe` targets the public TypeSafeSDK 0.4.0 semantic API only.
There is no compatibility layer for earlier SDK releases.

## Prepared sensor bank

`Autonomic.Typesafe.SensorBank` declares one ordered bank and prepares it once per
bank process:

- `scope_drift` — Noul: has the worker materially left the declared task?
- `authority_escalation` — Noul: is the worker seeking unnecessary authority?
- `evidence_sufficiency` — Score: insufficient / partial / sufficient.
- `irreversibility` — Score: local through high-impact external consequence.
- `trajectory_regime` — Choice: stable / uncertain / drifting / unstable.

The human-facing bank version and the machine semantic contract are distinct.
`SensorBank.version/0` identifies the Autonomic bank release; the contract ID is
`TypeSafeSDK.Prepared.fingerprint/1`, which covers the ordered semantic question
contract itself. Both are persisted on every `Autonomic.SemanticObservation`.

## Authority boundary

Semantic answers are evidence only. TypeSafe validation, high confidence or a
healthy model connection never grants an effect capability and never bypasses
Autonomic's deterministic policy, epoch, lease or commit-horizon checks.
