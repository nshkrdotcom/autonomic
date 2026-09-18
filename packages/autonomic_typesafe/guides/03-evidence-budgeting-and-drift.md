# Evidence Budgeting, Contracts and Drift

## Two independent size bounds

Autonomic bounds observable evidence before it reaches the SDK. TypeSafeSDK 0.4
then measures the exact final serialized request, including Prepared questions,
model and other wire fields.

- `evidence_limit` protects the kernel's observation-window policy and forces
  secret redaction/bounded state before semantic evaluation.
- `request_limit` is forwarded as TypeSafeSDK `max_request_bytes:` and prevents an
  oversized final JSON request from reaching transport egress.

The second guard does not replace the first.

## Model drift

A non-empty `allowed_models` setting becomes the SDK `response_contract`
`allowed_models` list. Exact membership is enforced by TypeSafeSDK before
Autonomic normalizes an answer. A mismatch is semantic degradation, never an
implicit safe result.

## Unknown answers

TypeSafeSDK's strict response contract rejects answer IDs that were not requested.
The SDK intentionally preserves a future answer type when it occurs under a
requested key. Autonomic's fixed production bank requires known Noul/Choice/Score
families, so any remaining `response.unknown_answers` entry is rejected as
`{:unknown_required_answers, keys}`.

## Outage and overload

Transport errors, request timeouts, response-contract violations, request-budget
failures and TypeSafe OTP `max_in_flight` overload all return errors and mark
semantic health degraded. Missing configuration marks semantic health unavailable.
No such condition produces a synthetic safe observation.
