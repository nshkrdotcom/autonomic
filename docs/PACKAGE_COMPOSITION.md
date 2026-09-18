# Package composition and Hex installation

Autonomic is a Poncho-style repository with **four independently publishable Hex packages**. The package split is intentionally asymmetric: `autonomic` defines the kernel contracts and runtime, while Linux, PostgreSQL, and TypeSafe are opt-in implementations of those contracts.

## Dependency direction

The dependency direction is **adapter → core**:

```text
autonomic_linux ───────┐
autonomic_postgres ────┼──> autonomic
autonomic_typesafe ────┘
```

`autonomic` does **not** declare `autonomic_linux`, `autonomic_postgres`, or `autonomic_typesafe` as optional Mix dependencies. Doing so would make the core package own concrete infrastructure choices and would weaken the extension boundaries that the repository tests.

Each adapter is a normal standalone package that depends on `autonomic`. Applications opt in by adding whichever adapters they want.

## Consumer installation recipes

Keeping `{:autonomic, ...}` explicit in an application is recommended even when an adapter would also bring it transitively. The application uses the core API directly, so the dependency should be visible in its own `mix.exs`.

### Core only

Use this when supplying your own `Store`, `ExecutionDomain`, and/or `SemanticSensor` implementations, or when exercising kernel semantics without the official infrastructure adapters.

```elixir
defp deps do
  [
    {:autonomic, "~> 0.1.0"}
  ]
end
```

### Core + one official adapter

For example, durable PostgreSQL authority with custom execution and semantic backends:

```elixir
defp deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_postgres, "~> 0.1.0"}
  ]
end
```

The same pattern applies to `autonomic_linux` and `autonomic_typesafe`.

### Full official stack

A production application using all three official adapters depends on all four packages:

```elixir
defp deps do
  [
    {:autonomic, "~> 0.1.0"},
    {:autonomic_linux, "~> 0.1.0"},
    {:autonomic_postgres, "~> 0.1.0"},
    {:autonomic_typesafe, "~> 0.1.0"}
  ]
end
```

Then configuration selects those implementations:

```elixir
config :autonomic,
  store: Autonomic.Store.Postgres,
  domain_backend: Autonomic.Linux.Backend,
  sensor: Autonomic.Typesafe.Sensor
```

## Why the core package does not list the adapters

The public extension surface is behavioural:

- `Autonomic.Store`
- `Autonomic.ExecutionDomain`
- `Autonomic.SemanticSensor`
- `Autonomic.EffectAdapter`

This lets an application replace PostgreSQL, Linux containment, the semantic backend, or an effect target without forking `autonomic`. The repository contains explicit examples of this: the SQLite store example does not depend on `autonomic_postgres`, and the custom microVM-domain example does not depend on `autonomic_linux`.

## Repository path dependencies versus Hex dependencies

Inside this monorepo, tests and examples use `path:` dependencies so they exercise the checked-out source tree. Release staging rewrites publishable package-to-package path dependencies to versioned Hex requirements.

A consumer application should use Hex requirements, not repository paths.

The private `integration/autonomic_acceptance` project is the repository's direct all-four-package composition harness. It depends on:

```elixir
[
  {:autonomic, path: "../../packages/autonomic"},
  {:autonomic_linux, path: "../../packages/autonomic_linux"},
  {:autonomic_postgres, path: "../../packages/autonomic_postgres"},
  {:autonomic_typesafe, path: "../../packages/autonomic_typesafe"}
]
```

That is the monorepo equivalent of a consumer application's four versioned Hex dependencies.

## How the numbered examples map to published packages

The numbered examples are executable teaching/conformance projects. They are not all intended to be literal installation templates.

| Example shape | Repository dependency shape | Consumer-package lesson |
| :--- | :--- | :--- |
| Most laptop examples | `autonomic` + private `examples/dev_stack` | Core can be exercised independently of the official infrastructure adapters. |
| `14_custom_store_sqlite` | `autonomic` + example SQLite implementation | A custom `Autonomic.Store` replaces `autonomic_postgres`; do not install PostgreSQL merely to satisfy core. |
| `15_custom_domain_microvm` | `autonomic` + example domain skeleton | A custom `Autonomic.ExecutionDomain` replaces `autonomic_linux`; core does not require Linux. |
| `17_full_stack_linux` | core example wrapper plus repository provisioning/preflight scripts | A real application using the official production stack installs all four packages; direct all-four composition is exercised by `integration/autonomic_acceptance`. |

The private `examples/dev_stack` package is never published and must never become a dependency of any publishable package.

## Publication order

Publish in dependency order:

1. `autonomic`
2. `autonomic_linux`
3. `autonomic_postgres`
4. `autonomic_typesafe`

The last three can be published in any order relative to one another after `autonomic` exists, because they depend on core and not on each other. The order above is the repository's conventional release order.
