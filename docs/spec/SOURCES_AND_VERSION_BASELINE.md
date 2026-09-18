# Sources and Version Baseline

Original architecture freeze: **2026-09-16**.

Semantic SDK revision: **2026-09-17**.

This file records the external technology baseline used when the architecture was frozen. Version numbers are not security guarantees; upgrade through normal compatibility/QC work.

## BEAM

- Elixir 1.20 released 2026-06-03 and is the reference language line for this implementation.
  - https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/
- Erlang/OTP 29.1 released 2026-09-16 and is the reference OTP line.
  - https://www.erlang.org/news/191

The seed requirements mentioned Elixir 1.17+/OTP 27+ as a floor. This docset intentionally targets the current 1.20/29 family for a new implementation.

## Elixir packages checked during authoring

- `gen_stage` 1.3.2 — demand/backpressure primitive.
  - https://hex.pm/packages/gen_stage
- `broadway` 1.3.0 — evaluated but not selected for core v0.1; GenStage provides the lower-level demand model required by the kernel.
  - https://hex.pm/packages/broadway
- `finch` 0.23.0 — useful to trusted broker adapters and already common in the surrounding Elixir ecosystem, but TypeSafe traffic must go through `typesafe_sdk` rather than a parallel client.
  - https://hex.pm/packages/finch
- `jason` 1.4.5 — JSON encoding/decoding.
  - https://hex.pm/packages/jason
- `telemetry` 1.4.2 — instrumentation dispatch.
  - https://hex.pm/packages/telemetry
- `ecto_sql` 3.14.0 — SQL persistence/migrations.
  - https://hex.pm/packages/ecto_sql
- `postgrex` 0.22.4 — current non-vulnerable PostgreSQL driver line surfaced during authoring.
  - https://hex.pm/packages/postgrex
- `nimble_options` 1.1.1 — configuration validation.
  - https://hex.pm/packages/nimble_options
- `erlexec` 2.3.4 — evaluated. Deliberately not required in the containment TCB because the design uses one explicit launcher Port protocol for pre-exec isolation setup.
  - https://hex.pm/packages/erlexec

## Linux isolation

- `libseccomp` 2.6.1 was the current release surfaced during authoring.
  - https://github.com/seccomp/libseccomp/releases
- Bubblewrap 0.12.0 was the current release surfaced during authoring. It is useful as a development/reference sandbox but is not the normative production authority boundary by itself.
  - https://github.com/containers/bubblewrap/releases
- Firecracker 1.17.0 was the latest release surfaced during authoring. It is the planned stronger microVM backend, not a v0.1 blocker.
  - https://github.com/firecracker-microvm/firecracker/releases
  - https://github.com/firecracker-microvm/firecracker

Firecracker's own project documentation explicitly notes that safe multi-tenant operation depends on a correctly configured host OS. The microVM backend therefore does not replace host hardening or brokered effects.

## TypeSafe SDK basis

The semantic integration is grounded against the supplied **TypeSafeSDK 0.4.0** source. The active Autonomic surface is:

- `TypeSafeSDK.new_client/1`
- strict `TypeSafeSDK.noul/2`, `choice/3`, `score/3`
- `TypeSafeSDK.prepare/1` / `prepare!/1`
- `TypeSafeSDK.Prepared.fingerprint/1`
- `TypeSafeSDK.evaluate/4`
- `TypeSafeSDK.Response`, `Response.metadata/1` and `TypeSafeSDK.Answer.*`
- strict response contracts and exact `max_request_bytes:` request budgets
- `TypeSafeSDK.RuntimeCapabilities`
- `TypeSafeSDK.OTP.Server` for bounded non-blocking GenServer integration
- `TypeSafeSDK.Test` for deterministic application/component tests
- privacy-oriented evaluation and per-answer telemetry

The codebase is greenfield. There is no 0.2/0.3 support path and no local emulation of functionality now present in 0.4. The wire-oriented `system_one` surface is not used by the production Autonomic adapter.

TypeSafeSDK 0.4.0 requires **Pristine 0.4.0**. Autonomic does not build a second semantic HTTP or retry layer; TypeSafe remains responsible for its Pristine runtime. The supplied Pristine 0.4 Finch transport advertises and implements `:unary_cancellation` and `:cancellation_cleanup`, which are non-removable required runtime capabilities for the TypeSafe bank. Configured `required_capabilities` add stricter deployment requirements; they do not subtract this base.

The semantic adapter must still preserve Autonomic-specific concerns: observable evidence selection/redaction, evidence-window limits, fixed sensor meaning, required-known-answer policy, semantic health, calibration provenance, system backpressure and authority.
