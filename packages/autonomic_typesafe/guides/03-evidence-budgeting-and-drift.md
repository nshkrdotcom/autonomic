# Evidence Budgeting and Model Drift

## Sanitization and Redaction

Before any observation frame is sent to the semantic model:
- `Autonomic.Typesafe.Evidence.bounded/2` scrubs bearer tokens, API keys, private keys, and passwords.
- Bounded payload sizes prevent prompt injection or denial-of-service via giant observation inputs.

## Model Drift & Outage Degradation

If the TypeSafe API times out or responds with unknown future shapes, `autonomic_typesafe` logs a warning and degrades gracefully without crashing the BEAM supervisor tree.
