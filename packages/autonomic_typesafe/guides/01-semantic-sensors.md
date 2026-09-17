# TypeSafe/Jev Semantic Sensor Bank

`autonomic_typesafe` integrates exclusively through the public `TypeSafeSDK` 0.2.x strict semantic API to implement `Autonomic.SemanticSensor`.

## Prepared Sensor Bank

`Autonomic.Typesafe.SensorBank` prepares semantic sensors:
- `scope_drift` — Evaluates code edits against declared episode intent.
- `authority_escalation` — Detects unauthorized permission acquisition attempts.
- `stealth_persistence` — Detects background daemon or cron persistence attempts.
- `hostile_divergence` — Analyzes trajectory divergence across multiple turns.
