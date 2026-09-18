<p align="center">
  <img src="assets/autonomic_typesafe.svg" alt="Autonomic TypeSafe Logo" width="200" height="200">
</p>

# autonomic_typesafe

<p align="center">
  <a href="https://github.com/nshkrdotcom/autonomic"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fautonomic-24292e?logo=github" alt="GitHub"/></a>
  <a href="https://hex.pm/packages/autonomic_typesafe"><img src="https://img.shields.io/hexpm/v/autonomic_typesafe.svg" alt="Hex.pm"/></a>
  <a href="https://hexdocs.pm/autonomic_typesafe"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
</p>

TypeSafe/Jev semantic sensor bank backend for the Autonomic Kernel.

---

## What is this package?

`autonomic_typesafe` implements `Autonomic.SemanticSensor` using TypeSafeSDK
**0.4.0**. It evaluates a fixed, prepared bank for scope drift,
authority escalation, evidence sufficiency, effect irreversibility, and trajectory
regime while keeping semantic evidence outside Autonomic's root of trust.

## Runtime design

The adapter leverages TypeSafeSDK 0.4 primitives:

- `TypeSafeSDK.Prepared.fingerprint/1` provides machine-contract identity.
- `response_contract:` enforces allowed-model policy and validates answer IDs.
- `max_request_bytes:` enforces the exact serialized request budget before egress.
- `TypeSafeSDK.Response.metadata/1` supplies bounded response provenance, and `TypeSafeSDK.Error.metadata/1` supplies privacy-safe error diagnostics.
- `TypeSafeSDK.OTP.Server` keeps evaluation responsive under the package-owned `Autonomic.Typesafe.Tasks` supervisor with an explicit `max_in_flight` bound.
- Per-answer telemetry is emitted after semantic validation.

Autonomic handles kernel-specific concerns: observable-window construction, secret redaction, evidence budgeting, and fail-closed evaluation, while delegating transport, request serialization, and scoped cancellation to TypeSafeSDK.

## Dependencies

- `autonomic` (`~> 0.1.0` when published)
- `typesafe_sdk` (`~> 0.4.0`)

TypeSafeSDK 0.4.0 in turn requires Pristine 0.4.0. The supplied Pristine Finch
transport advertises verified unary cancellation and cancellation cleanup; this
adapter always requires those capabilities because the TypeSafe OTP server
uses scoped cancellation for bounded in-flight work.

## Installation

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_typesafe, "~> 0.1.0"}
  ]
end
```

## Configuration

```elixir
config :autonomic,
  sensor: Autonomic.Typesafe.Sensor

config :autonomic_typesafe,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  model: "jev-latest",
  allowed_models: [],
  timeout_ms: 3_000,
  slow_timeout_ms: 10_000,
  max_in_flight: 8,
  evidence_limit: 32_768,
  request_limit: 65_536,
  required_capabilities: [] # optional additional requirements; cancellation base is mandatory
```

`allowed_models: []` means that no concrete model allow-set is enforced. `required_capabilities` adds deployment-specific requirements on top of the adapter’s non-removable `:unary_cancellation` and `:cancellation_cleanup` base. For a
calibrated deployment, set a non-empty list of exact model IDs. `request_limit`
is the TypeSafeSDK full serialized-request limit; `evidence_limit` is the separate
Autonomic observable-state budget and remains necessary.

When no API key is configured, the package application starts without a bank and
`Autonomic.Typesafe.Sensor.observe/2` returns `{:error, :typesafe_not_configured}`.
Tests disable autostart and inject real `TypeSafeSDK.Test` clients directly into a
supervised bank; production has no client hot-swap API.

## Public modules

- `Autonomic.Typesafe.Sensor` — `Autonomic.SemanticSensor` implementation.
- `Autonomic.Typesafe.SensorBank` — declarative question bank and Prepared contract.
- `Autonomic.Typesafe.Bank` — bounded OTP execution and response normalization.
- `Autonomic.Typesafe.Evidence` — observable-state sanitization and redaction.
- `Autonomic.Typesafe.Application` — dedicated semantic task supervision plus optional bank supervision.

## Semantic Sensor Bank

The sensor bank evaluates five structured dimensions rather than a single classification:

| Sensor | TypeSafe family | Preserved structure |
| --- | --- | --- |
| `scope_drift` | Noul | boolean, confidence, true/false probabilities |
| `authority_escalation` | Noul | boolean, confidence, true/false probabilities |
| `evidence_sufficiency` | Score | expected/modal/ranked levels, normalized score, probabilities |
| `irreversibility` | Score | normalized value, expected/modal/ranked levels, probabilities |
| `trajectory_regime` | Choice | selected regime, confidence, full probabilities, ranking, margin |

Each evaluation produces typed `Autonomic.SemanticObservation` records containing model, request, fingerprint, usage, and timing provenance, feeding into:

1. `Autonomic.Homeostat`: Smooths semantic risk over time to drive regime transitions (`continue`, `yield`, `narrow`, `preempt`).
2. `Autonomic.EffectBroker`: Evaluates semantic evidence against policy thresholds for an exact effect revision before commit.

Read the guides in order:

1. [Semantic Sensors](guides/01-semantic-sensors.md)
2. [TypeSafeSDK Integration](guides/02-typesafe-sdk-integration.md)
3. [Evidence Budgeting, Privacy & Failure Semantics](guides/03-evidence-budgeting-and-drift.md)
4. [End-to-End TypeSafe Semantic Control Loop](guides/04-end-to-end-control-loop.md)

## Testing

Deterministic component tests use the real TypeSafeSDK serialization, validation,
response-contract, request-budget and transport seam through `TypeSafeSDK.Test`.
The separate `:live` gate uses an authorized real endpoint and records only
non-secret structural provenance.

See the package guides and repository-level `docs/TYPESAFE_SENSORS.md` for the
full integration contract.

For the repository-wide adapter/core dependency model and full-stack installation recipe, see [`docs/PACKAGE_COMPOSITION.md`](https://github.com/nshkrdotcom/autonomic/blob/main/docs/PACKAGE_COMPOSITION.md).
