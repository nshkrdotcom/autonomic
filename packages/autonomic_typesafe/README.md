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

`autonomic_typesafe` implements `Autonomic.SemanticSensor` backed by TypeSafeSDK 0.2.x. It prepares semantic evaluation banks for detecting code drift, authority escalation, stealth persistence, and trajectory anomalies in untrusted coding workers.

## When should I install it?

Install `autonomic_typesafe` when your Autonomic Kernel deployment requires semantic oversight and AI-based drift analysis alongside deterministic policies.

## What does it depend on?

- `autonomic` (~> 0.1.0)
- `typesafe_sdk` (~> 0.2.0)

## Installation

Add `autonomic_typesafe` to your `mix.exs`:

```elixir
def deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_typesafe, "~> 0.1.0"}
  ]
end
```

## How do I configure it?

In your `config/config.exs` or `config/runtime.exs`:

```elixir
config :autonomic,
  sensor: Autonomic.Typesafe.Sensor

config :autonomic_typesafe,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  model: "jev-latest",
  timeout_ms: 3000,
  evidence_limit: 32_768,
  request_limit: 65_536
```

## What public modules and concepts does it own?

- `Autonomic.Typesafe.Sensor` — Implements `Autonomic.SemanticSensor`.
- `Autonomic.Typesafe.Bank` — Manages prepared sensor banks and request dispatch.
- `Autonomic.Typesafe.Evidence` — Sanitizes, redacts, and bounds observation payloads.
- `Autonomic.Typesafe.Application` — OTP application supervisor.

## How does it fit into Autonomic?

`autonomic_typesafe` acts as an optional sensor adapter:

```text
                      ┌─────────────────────┐
                      │      autonomic      │
                      └──────────┬──────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
     autonomic_typesafe                      other sensors
```

## Where are the full system docs?

See the repository root at [GitHub](https://github.com/nshkrdotcom/autonomic) and [HexDocs](https://hexdocs.pm/autonomic_typesafe).
