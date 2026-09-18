# Evidence Budgeting, Privacy, Contracts, and Failure Semantics

A semantic model is useful only if the boundary around it is explicit. `autonomic_typesafe` applies an application-level evidence policy before TypeSafeSDK applies its own exact request contract.

## What crosses the semantic boundary

`Autonomic.Typesafe.Evidence.bounded/2` constructs a new map rather than forwarding the whole worker/process state. It includes only:

- episode ID;
- epoch;
- observation sequence;
- observation timestamp;
- deterministic facts;
- resource summaries;
- proposed-effect context;
- explicitly visible/observable state from frame metadata.

It does not intentionally forward arbitrary process state or the host environment.

## Recursive sanitization

Before serialization, the evidence layer:

- redacts secret-shaped keys such as `api_key`, `token`, `password`, `authorization`, `cookie`, `private_key`, and credential variants;
- redacts bearer tokens and common inline secret assignments from strings;
- redacts PEM private-key markers;
- bounds string length;
- bounds map/list item counts;
- bounds nesting depth.

The result is then encoded and measured.

## Two independent byte limits

There are deliberately two size controls:

```text
ObservationFrame
      |
      v
Autonomic.Typesafe.Evidence
      | evidence_limit: bounded/redacted semantic state
      v
TypeSafeSDK serialization
      | max_request_bytes: exact final wire request
      v
transport
```

`evidence_limit` protects Autonomic's observation-window policy. If the redacted state is too large it is compacted, important deterministic/resource/effect context is retained, and a digest of the fuller redacted value is recorded. If the compact representation still cannot fit, semantic evaluation fails.

`request_limit` is forwarded to TypeSafeSDK as `max_request_bytes:`. It includes the prepared bank, model, state, and other serialized request fields. A request that exceeds that limit is rejected before transport egress.

## Model and semantic-contract drift

Two independent identities are checked:

- concrete response model, optionally restricted by `allowed_models`;
- Prepared fingerprint, required to equal the bank's stored semantic-contract ID.

A model outside the configured allow-set is a TypeSafe response-contract error. A fingerprint mismatch is an Autonomic semantic-contract error.

Neither is reinterpreted as an unsafe agent claim. They are failures of the evidence channel itself and therefore degrade semantic health.

## Unknown answers

The integration is fail-closed in both directions:

- an answer ID that was never requested is rejected by TypeSafeSDK (`on_unknown_answer: :error`);
- a requested sensor returned using an unknown future answer family is rejected by Autonomic because the production bank requires known Noul/Score/Choice semantics.

There is no fallback that maps "unknown" to false, zero, stable, or sufficient.

## Outage and overload semantics

These conditions produce errors rather than synthetic safe observations:

- missing TypeSafe configuration;
- transport failure;
- timeout;
- response-contract failure;
- model drift;
- Prepared-fingerprint mismatch;
- unknown required answer family;
- request budget failure;
- required runtime-capability failure;
- `max_in_flight` saturation.

`Autonomic.Typesafe.Bank` reports semantic health to `Autonomic.SystemRegulator`. The core can then reduce autonomy or pause sensitive commits.

## What TypeSafe probabilities mean inside Autonomic

The adapter preserves distributions and confidence. Core policy does not currently claim those distributions are calibrated probabilities of real-world safety. The Homeostat consumes normalized values plus confidence, and the EffectBroker uses explicit thresholds for selected sensors. That is an intentional separation between **semantic measurement** and **authority policy**.
