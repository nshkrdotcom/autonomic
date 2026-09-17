# 12 — TypeSafeSDK Integration Contract

This document is normative for `apps/autonomic_typesafe`.

The Autonomic Kernel architecture predates TypeSafeSDK 0.2.0. The 0.2 release moved substantial reusable semantic-client machinery into the SDK. The kernel MUST consume that machinery rather than reimplement it. At the same time, semantic observations remain outside the root of trust and never acquire authority merely because the SDK validates them.

## 1. Baseline and compatibility policy

The implementation baseline is **TypeSafeSDK 0.2.x**. Before coding, inspect the attached `typesafe_sdk.xml` and verify the actual version and public surface.

For a 0.2.x source, the expected semantic APIs are:

```elixir
TypeSafeSDK.new_client/1
TypeSafeSDK.noul/2
TypeSafeSDK.choice/3
TypeSafeSDK.score/3
TypeSafeSDK.prepare/1
TypeSafeSDK.prepare!/1
TypeSafeSDK.evaluate/4
TypeSafeSDK.evaluate!/4
TypeSafeSDK.evaluate_stream/4
TypeSafeSDK.evaluate_many/4
TypeSafeSDK.Response.*
TypeSafeSDK.Answer.*
TypeSafeSDK.Test.*
TypeSafeSDK.RuntimeCapabilities.*
```

The legacy `system_one` path is retained by the SDK for low-level compatibility/parity. It is not the normative Autonomic production path.

TypeSafeSDK 0.3 is not a prerequisite. If the supplied source is 0.3+ and offers native equivalents for the optional hardening features in section 12, use their actual public API and delete only equivalent compatibility code. Never infer or invent APIs based on this future-facing specification.

## 2. Ownership boundary

### TypeSafeSDK owns

- strict semantic question construction and validation;
- finite caller question/choice identity preservation;
- `Prepared` validation and reusable encoding;
- structured JSON state validation;
- protected semantic request fields/headers;
- production TypeSafe request execution through its Pristine runtime;
- timeout/retry option plumbing and normalized SDK errors;
- request-relative response validation;
- probability-domain/sum checks and Score-range checks;
- answer enrichment and raw/unknown response retention;
- answer ranking/margin/expected/modal/normalized helpers;
- privacy-oriented semantic telemetry;
- bounded per-enumeration batch execution;
- deterministic application test fixtures through the production transport seam;
- runtime-capability reporting;
- TypeSafe wire-schema generation/verification.

### Autonomic owns

- what constitutes observable evidence;
- secret/data redaction before TypeSafe;
- bounded evidence-window construction and coalescing;
- sensor meanings and question wording;
- sensor-bank versioning/calibration;
- semantic-contract drift consequences;
- model-drift consequences;
- Homeostat smoothing/hysteresis and trajectory regime state;
- GenStage/SystemRegulator backpressure and admission control;
- semantic service-health policy/circuit behavior;
- precedence between semantic and deterministic facts;
- capability/authority decisions and all external effect authorization;
- durable evidence retention policy.

No SDK convenience may cross this boundary. In particular, an SDK confidence helper is evidence interpretation, not authority.

## 3. Sensor bank construction

Define one application-owned declarative sensor-bank specification. The initial bank MUST include at least:

- `scope_drift` — Noul;
- `authority_escalation` — Noul;
- `evidence_sufficiency` — Score;
- `irreversibility` — Score;
- `regime` — Choice with `stable | uncertain | drifting | unstable`.

Additional sensors such as `goal_abandonment`, `environment_mismatch` and `semantic_novelty` are allowed when they are justified by the workload and calibration data.

Build the bank once and prepare it once:

```elixir
questions = [
  scope_drift:
    TypeSafeSDK.noul(
      "Has the observable trajectory materially drifted beyond the declared task?"
    ),
  authority_escalation:
    TypeSafeSDK.noul(
      "Is the worker attempting to acquire authority unnecessary for the task?"
    ),
  evidence_sufficiency:
    TypeSafeSDK.score(
      "How sufficient is the observable evidence for the proposed next action?",
      ["Insufficient", "Partial", "Sufficient"]
    ),
  irreversibility:
    TypeSafeSDK.score(
      "How externally consequential is the proposed effect?",
      ["Local", "Reversible", "External", "Authoritative", "High-impact"]
    ),
  regime:
    TypeSafeSDK.choice(
      "Classify the current trajectory regime from observable evidence only.",
      stable: "coherent and within scope",
      uncertain: "insufficient or conflicting evidence",
      drifting: "material directional deviation",
      unstable: "severe deviation requiring containment"
    )
]

prepared = TypeSafeSDK.prepare!(questions)
```

Do not reconstruct the bank on every observation frame. Do not mutate `Prepared` fields or depend on undocumented internals.

## 4. Observable state contract

The semantic state contains only evidence actually observable by the trusted system, for example:

- visible model output;
- structured tool-call deltas/arguments;
- stdout/stderr windows;
- diff summaries;
- deterministic kernel facts;
- effect proposals;
- declared plans/summaries actually emitted by the worker;
- bounded trajectory summaries derived from trusted evidence.

Do not depend on hidden chain-of-thought.

The window builder MUST:

1. redact secrets before serialization;
2. label evidence source/type where useful;
3. bound per-source and aggregate size;
4. coalesce low-value repeated evidence deterministically;
5. never drop deterministic violation facts because semantic capacity is saturated;
6. record truncation/coalescing as deterministic metadata so the Homeostat can account for reduced evidence.

## 5. 0.2 request-size compatibility guard

TypeSafeSDK 0.2 validates JSON shape but does not expose a documented full serialized-request byte cap.

Therefore `autonomic_typesafe` MUST enforce a local evidence budget before `evaluate/4`. The budget is kernel configuration and does not claim to be the provider's service limit.

A safe 0.2 implementation:

- validates/redacts the observable state;
- deterministically JSON-encodes the application-owned state representation;
- checks it against the configured semantic-state byte budget;
- coalesces/truncates according to policy or returns `{:error, :semantic_window_too_large}`;
- records the resulting state-byte count and any truncation fact.

Do not reach into opaque `Prepared` fields to estimate question bytes. A future SDK-native full-request byte limit is an additional transport-boundary guard, not a replacement for the kernel's evidence-window budget.

## 6. Evaluation policy

Fast-loop calls SHOULD normally disable automatic retries unless policy explicitly allows the latency and duplicate-processing ambiguity:

```elixir
TypeSafeSDK.evaluate(client, state, prepared,
  retry: false,
  timeout_ms: fast_timeout_ms,
  telemetry_metadata: %{
    episode_id: episode_id,
    sensor_bank: sensor_bank_version
  }
)
```

A slower verification path may choose a bounded retry policy if the service semantics and budget justify it. In all cases:

- a retryable error is not proof that retry is semantically harmless;
- task cancellation is not proof of remote cancellation;
- lack of required semantic evidence never becomes approval;
- fast semantic failure does not bypass deterministic enforcement.

## 7. Response normalization

Known answers are retrieved through the SDK helpers and converted into `Autonomic.SemanticObservation`.

Persist at minimum when available:

- sensor id;
- normalized value;
- probability distribution/provider confidence as appropriate;
- actual response model;
- requested model when policy cares about it;
- SDK version;
- request id;
- usage;
- retry count;
- elapsed timing;
- sensor-bank version;
- semantic-contract id;
- observation timestamp.

Do not recalculate Choice ranking/margin, Score expected/modal/normalized values, or Noul certainty if the SDK already supplies the corresponding helper. Thresholds remain explicit application policy.

## 8. Unknown answer tags are degradation

TypeSafeSDK 0.2 deliberately retains unknown future answer tags in `response.unknown_answers` for forward compatibility.

That behavior is correct for a general SDK but requires an Autonomic fail-closed rule:

> If a required production sensor is not available as its requested known answer because the response uses an unknown answer tag, the sensor result is unavailable/degraded. It is never interpreted as false, stable, low risk, or safe.

Because the production bank contains only known Noul/Choice/Score questions, any relevant entry in `unknown_answers` is a semantic-contract event worth recording. Depending on effect class and current uncertainty budget, the kernel may continue locally, narrow authority, yield, invoke slow verification, or fail closed.

## 9. Model provenance and drift

The actual model named by the response may differ from the alias requested by the caller.

Always record the actual model.

If policy/calibration requires a concrete model contract, configure an explicit allow-set of actual model names. A mismatch means:

```text
semantic contract no longer matches the calibrated/approved configuration
```

It does **not** mean:

```text
the new model is malicious or unsafe
```

The adapter reports contract drift. The Homeostat/SystemRegulator/policy determines the consequence.

## 10. Semantic contract identity on TypeSafeSDK 0.2

Calibration depends on the exact semantic question contract, not just the model name.

TypeSafeSDK 0.2 does not expose a public prepared-question fingerprint, so Autonomic maintains one without depending on SDK internals.

The application MUST define the sensor-bank declaratively from a canonical, versioned manifest and derive both:

1. the SDK questions;
2. a SHA-256 `semantic_contract_id`.

The digest input MUST include every locally controlled semantic element whose change could alter interpretation, including:

- sensor id and type;
- instructions;
- criteria/options/levels and descriptions;
- intentional ordering;
- manifest schema version.

Use deterministic canonical encoding of the application manifest. Domain-separate the digest, for example conceptually:

```text
autonomic.typesafe.sensor-bank.v1 || canonical_manifest_bytes
```

Do not claim this digest authenticates TypeSafe or the model. It is local contract identity only.

Calibration artifacts MUST bind at least:

```text
semantic_contract_id
+ actual model
+ application policy version
+ dataset/provenance
```

Changing the bank invalidates calibration frozen against the old contract until reevaluated.

## 11. Telemetry and privacy

Use TypeSafeSDK semantic telemetry for operation/model/count/status/request/retry/token/timing visibility. Caller metadata contains identifiers only.

Never place raw worker text, secrets, question bodies, authorization material, or unredacted evidence in `telemetry_metadata`.

The kernel may emit its own higher-level telemetry keyed by episode/epoch/trajectory/sensor ids, but MUST preserve the SDK's privacy boundary rather than attaching raw evidence to generic telemetry events.

## 12. Runtime capabilities and backpressure

`TypeSafeSDK.RuntimeCapabilities` is the source for SDK-visible transport capability advertisements. If deployment requires a property such as bounded outstanding requests, queue bounds, response-byte bounds, deterministic overload, or cancellation cleanup, require it fail-closed through the SDK's public capability interface and verify the actual adapter contract.

Do not infer a guarantee from a successful live request.

SDK `evaluate_stream/evaluate_many` may bound a collection of independent semantic calls. It does **not** replace:

- GenStage demand;
- SensorArray coalescing;
- SystemRegulator admission modes;
- verifier/human approval pressure;
- speculation budgets.

Those are system-wide control mechanisms.

## 13. Testing through TypeSafeSDK 0.2

### Component tests

Use `TypeSafeSDK.Test` for deterministic adapter tests because it exercises the production serialization/retry/decode/semantic-validation path.

Required component cases:

- exact production bank request contract;
- caller-key preservation;
- Noul/Choice/Score normalization;
- exact/synthetic distributions;
- HTTP/transport error sequences;
- state-dependent callback for race coordination;
- unknown future answer handling;
- actual-model mismatch policy;
- request/state budget rejection;
- secret-redaction inspection from captured serialized requests;
- timeout and caller/task cleanup behavior where relevant.

Call `verify!`/`close` according to the SDK test lifecycle.

### Live gate

The final acceptance gate uses a real TypeSafe API key and the real production adapter. Fixtures never satisfy the live gate.

Record only non-secret conformance evidence: SDK version, actual model, request id, usage, retries/timing, semantic-contract id, sensor-bank version, and gate outcome.

## 14. Optional TypeSafeSDK 0.3 reusable enhancements

These enhancements are independently useful to any serious TypeSafe consumer and are therefore reasonable SDK features. They are not Autonomic-specific.

### 14.1 Prepared semantic-contract fingerprint

Desired semantics:

- public, deterministic, versioned fingerprint of the validated prepared question contract;
- changes when semantically relevant instructions/criteria/order change;
- stable across processes/runs for the same validated contract;
- documented as identity, not authentication/signature.

When available, persist the SDK fingerprint in addition to the human application sensor-bank version. The local 0.2 manifest digest can then be removed or retained as migration provenance.

### 14.2 Strict response contract

Desired opt-in semantics:

- error when a requested known question is satisfied only by an unknown future answer tag;
- optional caller-declared allow-set for actual response model names;
- typed error retaining safe request/response provenance for audit;
- default remains forward-compatible so ordinary SDK consumers are not broken.

When available, configure strict mode for the Autonomic production bank and keep kernel consequences outside the SDK.

### 14.3 Serialized request byte budget

Desired semantics:

- client/per-call configured byte limit;
- measured on the final locally serialized semantic request before transport;
- violation fails locally before network execution;
- no invented provider service maximum when none is published.

When available, use it in addition to the kernel evidence-window budget.

## 15. 0.2 → optional 0.3 migration table

| Kernel semantic | TypeSafeSDK 0.2 implementation | If native 0.3 feature exists |
| --- | --- | --- |
| Semantic contract identity | Canonical Autonomic sensor manifest SHA-256 | Prefer public prepared-contract fingerprint; keep application version |
| Required unknown answer fails closed | Inspect `unknown_answers` and mark degraded | Configure SDK strict unknown-answer contract |
| Concrete-model pin | Compare `response.model` to policy allow-set | Configure SDK allowed actual models |
| Request budget | Kernel state/evidence byte budget before `evaluate` | Add SDK final serialized-request byte limit |

The observable behavior and acceptance criteria must not change across this migration.

## 16. Explicit non-goals

Do **not** move the following into TypeSafeSDK or recreate them in `autonomic_typesafe`:

- Homeostat state/smoothing/hysteresis;
- authority/capability/effect policy;
- TypeSafe-specific authority decisions;
- global system admission control;
- GenStage backpressure;
- semantic service fleet circuit breaker policy;
- secret-classification/redaction policy;
- persistent calibration database;
- multi-model voting/orchestration;
- effect classes;
- Linux containment;
- a second HTTP/retry stack.

The SDK produces validated semantic evidence. The kernel decides what, if anything, that evidence permits.
