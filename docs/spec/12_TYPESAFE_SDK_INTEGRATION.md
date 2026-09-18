# 12 — TypeSafeSDK 0.4 Integration Contract

## 1. Normative baseline

The Autonomic semantic adapter targets **TypeSafeSDK 0.4.0** and no earlier SDK
release. This repository is greenfield: do not add compatibility branches,
version probes, shims, legacy response handling, migration code or fallback
implementations for TypeSafeSDK 0.2/0.3.

The production dependency is:

```elixir
{:typesafe_sdk, "~> 0.4.0"}
```

TypeSafeSDK 0.4.0 requires Pristine 0.4.0 and retains Pristine as the sole
HTTP/resilience runtime. Autonomic consumes the TypeSafe public semantic API and
must not build a parallel HTTP client, retry engine, circuit breaker, transport
pool or cancellation engine.

The relevant public surface is:

```text
TypeSafeSDK.new_client/1
TypeSafeSDK.noul/2
TypeSafeSDK.choice/3
TypeSafeSDK.score/3
TypeSafeSDK.prepare/1
TypeSafeSDK.prepare!/1
TypeSafeSDK.evaluate/4
TypeSafeSDK.Response.*
TypeSafeSDK.Answer.*
TypeSafeSDK.Prepared.fingerprint/1
TypeSafeSDK.RuntimeCapabilities.*
TypeSafeSDK.OTP.Server
TypeSafeSDK.Test.*
```

`system_one` remains a wire-oriented SDK API but is not an Autonomic production
integration path.

## 2. Ownership boundary

### TypeSafeSDK owns

- semantic question validation and encoding;
- reusable `Prepared` contracts and finite caller-key restoration;
- deterministic Prepared fingerprints;
- final semantic request construction and JSON serialization;
- exact full-request byte-budget enforcement;
- generated operation execution through Pristine;
- retry/timeout option translation;
- response decoding and request-relative semantic validation;
- strict response contracts;
- answer enrichment and ranking/confidence helpers;
- bounded response/error metadata;
- semantic telemetry, including TypeSafe 0.4 per-answer telemetry;
- bounded OTP task orchestration through `TypeSafeSDK.OTP.Server`; and
- fail-closed transport capability reporting delegated to Pristine.

### Autonomic owns

- which observable evidence may cross the semantic boundary;
- secret redaction and bounded observation-window construction;
- the production sensor-bank content and human bank version;
- semantic health and overload consequences;
- the policy meaning of sensor values and thresholds;
- required-known-answer-family policy for the fixed bank;
- calibration provenance and allowed concrete model policy;
- system-level GenStage/SystemRegulator backpressure; and
- every authority, epoch, lease, commit-horizon and effect decision.

A semantically valid or high-confidence TypeSafe answer is evidence only. It
never grants authority.

## 3. Production sensor bank

The reference bank contains:

- `scope_drift` — Noul;
- `authority_escalation` — Noul;
- `evidence_sufficiency` — Score;
- `irreversibility` — Score; and
- `trajectory_regime` — Choice (`stable | uncertain | drifting | unstable`).

Build the bank from one declarative source and prepare it once per bank process:

```elixir
prepared = TypeSafeSDK.prepare!(questions)
```

Do not reconstruct questions for every observation and do not read private
`Prepared` fields.

## 4. Semantic contract identity

The authoritative semantic-contract ID is:

```elixir
TypeSafeSDK.Prepared.fingerprint(prepared)
```

Persist it alongside the separate human `sensor_bank_version`. Do not maintain a
second SHA-256 implementation over a duplicate local representation merely to
recreate a feature the SDK now provides.

Every successful response must carry the same Prepared fingerprint through
TypeSafeSDK response metadata. A mismatch is a contract error and must fail
closed.

## 5. Observable evidence contract

The state sent to TypeSafe must be derived only from observable, policy-approved
facts such as:

- deterministic observation facts;
- resource summaries;
- proposed effect context;
- bounded stdout/stderr/tool summaries;
- explicit worker plans or emitted text; and
- prior semantic summaries that policy explicitly permits to re-enter context.

Do not send credentials, authorization headers, private keys, raw environment
secrets, hidden model state or unbounded accumulated transcripts.

`Autonomic.Typesafe.Evidence` is responsible for recursive secret redaction and
an `evidence_limit` on the normalized observable state before the SDK sees it.
This kernel-level evidence budget remains mandatory even though TypeSafe now has
a final request budget.

## 6. Exact request budget

Configure TypeSafeSDK `max_request_bytes:` from Autonomic's `request_limit`.
TypeSafe measures the actual final serialized request value immediately before
transport egress, including the state, Prepared questions, model and other wire
fields.

This replaces the old approximation of `state_bytes + local_manifest_bytes`.
Do not reintroduce that approximation.

An SDK `:request_too_large` error is semantic degradation and produces no safe
observation.

## 7. Response contract

Every production bank evaluation uses an SDK response contract equivalent to:

```elixir
response_contract: [
  on_unknown_answer: :error,
  allowed_models: allowed_models_or_nil
]
```

A non-empty Autonomic `allowed_models` list is passed through unchanged and uses
TypeSafe's exact-membership semantics. `[]` is represented as `nil` so no model
allow-set is enforced.

TypeSafe's `on_unknown_answer: :error` rejects response answer IDs that were not
part of the Prepared request. It intentionally does not reject a future answer
*type* that arrives under a requested key. Because Autonomic's production bank
requires known Noul/Choice/Score families, any remaining
`response.unknown_answers` entry is a required-answer contract failure and must
be rejected explicitly by the adapter.

Do not turn missing or future answer types into false/zero/safe defaults.

## 8. Bounded OTP execution

`Autonomic.Typesafe.Bank` uses `TypeSafeSDK.OTP.Server` rather than performing
network evaluation directly inside a GenServer callback.

The wrapper is configured with:

- the normal TypeSafe client;
- the package-owned `Autonomic.Typesafe.Tasks` Task.Supervisor;
- an explicit `max_in_flight` bound;
- fixed evaluation defaults for model, retry policy, response contract and
  request budget; and
- per-observation timeout and privacy-safe caller telemetry metadata.

The bank's synchronous `observe/2` API waits for the typed SDK result, but the
bank process remains responsive while HTTP work executes in a supervised task.
The SDK wrapper owns private Pristine cancellation scopes for each request and
cancels pending work on server shutdown.

`Autonomic.Typesafe.Tasks` is deliberately separate from the core task supervisor so semantic latency cannot exhaust task slots needed by effect or episode control. It is only a caller-owned task lifecycle supervisor; do not turn it into an HTTP pool or queue, and do not add a TypeSafe-owned global process.

`TypeSafeSDK.Batch` may be used elsewhere for independent semantic fan-out, but
it is not a replacement for Autonomic's GenStage/SystemRegulator pressure model.

## 9. Runtime capability requirements

The reference adapter always requires:

```elixir
[:unary_cancellation, :cancellation_cleanup]
```

`TypeSafeSDK.RuntimeCapabilities` delegates discovery to
`Pristine.RuntimeCapabilities.transport/1`. The supplied Pristine 0.4.0 Finch
transport advertises both capabilities as supported and implements cancelable
unary execution through the Execution Plane.

A custom transport whose status is unsupported or unverified fails bank startup.
Do not infer support from adapter names or optional callbacks.

Pristine currently verifies those cancellation capabilities; additional TypeSafe
report fields such as queue or response-byte bounds remain unverified unless a
transport explicitly advertises them. Do not require unverified capabilities by
default.

## 10. Retry and timeout policy

Autonomic semantic sensing uses `retry: false` by default. A semantic retry can
consume extra latency/tokens and is not evidence that a prior remote attempt was
never processed. Any later decision to enable retry must be explicit and use
TypeSafe's `RetryPolicy`; do not implement retry loops in Autonomic.

Fast and slow observation modes choose different `timeout_ms` values. The SDK and
Pristine own request timeout execution. The bank should not layer a shorter
GenServer call timeout that can abandon a still-owned SDK task.

## 11. Normalization and provenance

Normalize only through TypeSafe public response/answer helpers. Persist at least:

- actual response model;
- requested model;
- request ID;
- TypeSafeSDK version;
- sensor-bank version;
- Prepared fingerprint;
- token usage;
- retry count;
- elapsed time;
- sensor value, confidence and probability distribution; and
- evidence-budget metadata.

Use `TypeSafeSDK.Response.metadata/1` for stable bounded structural response
metadata. Persist/expose SDK error state through `TypeSafeSDK.Error.metadata/1` rather
than raw error structs that may retain response bodies. Use the answer structs/helpers for policy-relevant distributions;
`TypeSafeSDK.Response.values/1` is intentionally insufficient for this adapter
because it discards confidence/rubric/distribution information.

## 12. Telemetry

TypeSafeSDK 0.4 emits privacy-oriented evaluation spans and one
`[:typesafe_sdk, :answer]` event per validated known answer. Autonomic supplies
identifier-only `telemetry_metadata` (`episode_id`, epoch, sequence, bank version and contract ID)
and does not duplicate answer telemetry.

Never place observable state, question text, credentials, raw bodies or selected
business labels into global telemetry metadata.

## 13. Startup and configuration

`autonomic_typesafe` may be installed without a configured API key. In that
case, its application supervisor starts without a bank and `Sensor.observe/2`
returns `{:error, :typesafe_not_configured}` while marking semantic health
unavailable.

There is no production client hot-swap API. Tests disable autostart and supervise
a bank with an injected `TypeSafeSDK.Test` client. This keeps test substitution at
the official SDK transport seam instead of adding production mutation hooks.

## 14. Testing contract

Deterministic component tests must prove:

- Prepared fingerprint provenance;
- redaction and bounded evidence state;
- exact TypeSafe full-request budget failure before transport;
- strict allowed-model response-contract rejection;
- fail-closed required future answer types;
- required runtime capabilities;
- TypeSafe transport outage degradation;
- the bank remains responsive while a semantic task is blocked; and
- `max_in_flight` rejects excess concurrent semantic work.

Use `TypeSafeSDK.Test` so serialization, request construction, semantic decoding
and SDK validation are still real. Do not replace these gates with mocks of the
Autonomic adapter.

The live gate remains separate and must record only non-secret provenance from a
real authorized TypeSafe endpoint.

## 15. Explicitly rejected compatibility work

Because the project is greenfield, the following are forbidden:

- `Code.ensure_loaded?` version branches for old TypeSafe releases;
- fallbacks to local manifest hashing;
- local model-drift enforcement when the SDK response contract can enforce it;
- approximate full-request byte accounting;
- a client-install/hot-swap production callback retained only for old tests;
- legacy `system_one` production paths; and
- dead 0.2/0.3 migration instructions in active architecture documentation.
