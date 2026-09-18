<p align="center">
  <img src="assets/autonomic.svg" alt="Autonomic Logo" width="200" height="200">
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

`autonomic_typesafe` implements `Autonomic.SemanticSensor` on the TypeSafeSDK
**0.4.0** semantic API. It evaluates a fixed, prepared bank for scope drift,
authority escalation, evidence sufficiency, effect irreversibility and trajectory
regime while keeping semantic evidence outside Autonomic's root of trust.

This is a greenfield integration. There is no TypeSafeSDK 0.2/0.3 compatibility
path, legacy shim or alternate semantic HTTP client.

## Runtime design

The adapter deliberately delegates reusable mechanics to TypeSafeSDK 0.4:

- `TypeSafeSDK.Prepared.fingerprint/1` is the semantic-contract identity;
- `response_contract:` enforces exact allowed-model policy and rejects unexpected
  answer IDs;
- `max_request_bytes:` enforces the exact serialized request budget before egress;
- `TypeSafeSDK.Response.metadata/1` supplies bounded stable response provenance and `TypeSafeSDK.Error.metadata/1` supplies privacy-safe status diagnostics;
- `TypeSafeSDK.OTP.Server` keeps the bank responsive while evaluations run under
  the package-owned `Autonomic.Typesafe.Tasks` supervisor with an explicit `max_in_flight` bound; and
- TypeSafe's per-answer telemetry is emitted after semantic validation.

Autonomic still owns the concerns that are kernel-specific: observable-window
construction, secret redaction, evidence budgeting, fail-closed treatment of an
unknown answer *type for a required sensor*, semantic health and authority policy.

TypeSafeSDK continues to own its Pristine runtime. `autonomic_typesafe` does not
implement retries, HTTP transport, a second queue, or transport cancellation.

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

## Testing

Deterministic component tests use the real TypeSafeSDK serialization, validation,
response-contract, request-budget and transport seam through `TypeSafeSDK.Test`.
The separate `:live` gate uses an authorized real endpoint and records only
non-secret structural provenance.

See the package guides and repository-level `docs/TYPESAFE_SENSORS.md` for the
full integration contract.
