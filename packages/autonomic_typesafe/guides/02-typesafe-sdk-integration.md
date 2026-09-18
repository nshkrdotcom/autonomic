# TypeSafeSDK 0.4 Integration

`autonomic_typesafe` intentionally uses TypeSafeSDK as the semantic client/runtime instead of reimplementing its HTTP, response, contract, or cancellation layers.

## SDK features used directly

| TypeSafeSDK feature | How Autonomic uses it |
| --- | --- |
| `TypeSafeSDK.noul/1` | scope-drift and authority-escalation questions |
| `TypeSafeSDK.score/2` | evidence-sufficiency and irreversibility questions |
| `TypeSafeSDK.choice/2` | trajectory-regime classification |
| `TypeSafeSDK.prepare!/1` | compile the fixed ordered semantic bank once per process |
| `TypeSafeSDK.Prepared.fingerprint/1` | authoritative machine identity for the semantic question contract |
| `TypeSafeSDK.OTP.Server` | bounded non-blocking evaluation outside the bank callback |
| `max_request_bytes:` | exact final serialized-request budget before egress |
| `response_contract:` | unexpected answer ID and concrete-model enforcement |
| `TypeSafeSDK.Response` | required answer fetch, request ID and stable metadata |
| `TypeSafeSDK.Answer.Noul` | boolean threshold + confidence |
| `TypeSafeSDK.Answer.Score` | expected/modal/ranked/normalized score interpretation |
| `TypeSafeSDK.Answer.Choice` | selected choice, ranking and margin |
| `TypeSafeSDK.RuntimeCapabilities` | startup-time proof of required transport/runtime properties |
| `TypeSafeSDK.Error.metadata/1` | bounded privacy-safe status diagnostics |
| `TypeSafeSDK.Test` | deterministic tests at the real SDK transport/serialization seam |

## Client construction

Production configuration creates a real `TypeSafeSDK.Client`:

```elixir
TypeSafeSDK.new_client(
  api_key: key,
  model: configured_model,
  timeout_ms: configured_timeout,
  retry: false
)
```

Autonomic deliberately sets `retry: false`. Retry semantics are not duplicated at this layer; a semantic request either produces a contract-valid response or becomes degraded/unavailable evidence.

## OTP execution model

`Autonomic.Typesafe.Bank` uses `TypeSafeSDK.OTP.Server` and a dedicated `Autonomic.Typesafe.Tasks` supervisor.

```text
caller
  |
  v
Autonomic.Typesafe.Bank
  |  prepare bounded state + tag request
  v
TypeSafeSDK.OTP.Server
  |
  +--> task 1 -> TypeSafe/Pristine
  +--> task 2 -> TypeSafe/Pristine
  `--> bounded by max_in_flight
```

The bank GenServer stays responsive while network work is in flight. Semantic tasks do not consume the core `Autonomic.Tasks` slots used by episode/effect orchestration.

The wrapper's `max_in_flight` is a hard local bound. Overload returns a typed error and degrades semantic health; it does not grow an unbounded queue.

## Required runtime capabilities

The adapter has a non-removable baseline requirement:

```elixir
[:unary_cancellation, :cancellation_cleanup]
```

Additional deployment requirements may be configured, but cannot remove that base. Startup calls `TypeSafeSDK.RuntimeCapabilities.check/2`; unsupported or unverified required capabilities fail startup rather than silently weakening the execution contract.

## Request contract

The evaluation defaults include:

```elixir
[
  model: configured_model,
  retry: false,
  max_request_bytes: request_limit,
  response_contract: [
    on_unknown_answer: :error,
    allowed_models: configured_allow_set_or_nil
  ]
]
```

`max_request_bytes` is enforced by TypeSafeSDK against the complete serialized wire request. This is separate from Autonomic's earlier evidence-state budget.

A non-empty `allowed_models` list is exact-membership policy. Model drift is a response-contract error before Autonomic normalizes the answer.

## Response contract

After TypeSafeSDK accepts the response, Autonomic still verifies two application-specific requirements:

1. the response Prepared fingerprint equals the bank's stored contract ID;
2. no required requested sensor arrived as a future/unknown answer family.

Unexpected answer IDs are already rejected by the SDK response contract. A future answer type under a requested key is intentionally not coerced to false/zero/safe; the adapter returns `{:unknown_required_answers, keys}`.

## Provenance

Every observation records:

```text
response.model
configured requested model
request ID
TypeSafeSDK.version()
SensorBank.version()
Prepared fingerprint
usage
retry count
elapsed time
observation time
```

That makes semantic evidence inspectable and reproducible enough to answer "which model and which semantic contract produced this decision?" without logging the raw secret-bearing request.

## Testing the integration instead of mocking it away

Component tests use `TypeSafeSDK.Test`, not a parallel fake semantic client. They exercise the SDK's request serialization, response-contract handling, exact byte budget, answer normalization, runtime capability checks, transport failures, and bounded OTP execution.

The live gate uses the real configured TypeSafe endpoint and requires `TYPESAFE_API_KEY`:

```bash
cd packages/autonomic_typesafe
TYPESAFE_API_KEY=... mix test test/live_gate_test.exs --include live
```

The gate records only non-secret structural provenance.
