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

The implementation agent receives the current `typesafe_sdk.xml`. This revised docset was grounded against **TypeSafeSDK 0.2.0**, whose strict semantic API is the normative Autonomic integration surface:

- `TypeSafeSDK.new_client/1`
- `TypeSafeSDK.noul/2`
- `TypeSafeSDK.choice/3`
- `TypeSafeSDK.score/3`
- `TypeSafeSDK.prepare/1` and `prepare!/1`
- `TypeSafeSDK.evaluate/4` and `evaluate!/4`
- `TypeSafeSDK.evaluate_stream/4` and `evaluate_many/4` for bounded per-enumeration execution where appropriate
- `TypeSafeSDK.Response` and `TypeSafeSDK.Answer.*` helpers
- `TypeSafeSDK.Test` for deterministic application/component tests through the production serialization/retry/decode path
- `TypeSafeSDK.RuntimeCapabilities` for fail-closed transport-capability reporting
- privacy-oriented `:telemetry` events emitted by the semantic evaluation layer

The 0.2 SDK preserves the older wire-oriented `system_one` API for compatibility, but Autonomic MUST NOT build its production semantic adapter on the legacy path unless a later attached SDK removes the strict `evaluate` surface and the docset is explicitly revised.

TypeSafeSDK 0.2.0 requires the Pristine 0.3.1 family in the supplied source. Autonomic does not import or reimplement Pristine HTTP semantics; that dependency remains owned behind TypeSafeSDK. In particular, Autonomic MUST NOT introduce a second HTTP/retry client for semantic traffic.

### Optional TypeSafeSDK 0.3 direction

This docset specifies three independently reusable enhancements that may appear in a later SDK release:

1. versioned fingerprints for prepared semantic question contracts;
2. opt-in strict response contracts for unknown answer tags and caller-declared allowed actual models;
3. a locally enforced serialized semantic-request byte budget before transport execution.

These are **not** required to start or complete the kernel against 0.2. On 0.2, `autonomic_typesafe` implements equivalent application-level semantics without reaching into private `Prepared` internals. If the attached SDK is 0.3+ and exposes native versions of these features, use the actual public API found in that source and remove only the corresponding compatibility code. Never guess future function names.

The semantic adapter must inspect the attached XML before implementation and verify the actual version/public names/options found there.
