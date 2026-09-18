# EffectBroker, Semantic Evaluation, and Mutation Horizons

`Autonomic.EffectBroker` is the trusted boundary between speculative worker activity and externally visible or authoritative effects.

## Effect classes

| Class | Meaning | Typical examples | Broker treatment |
| --- | --- | --- | --- |
| 0 | local replayable | compile, test, parse, inspect | may remain inside execution domain |
| 1 | isolated mutable | edit overlay, local throwaway state | speculative/disposable |
| 2 | external observable or compensatable | bounded HTTP read, metadata lookup | brokered |
| 3 | authoritative external mutation | Git ref update, mutating API call | brokered + policy-required decisions |
| 4 | irreversible/high-impact | publish, deploy, destructive mutation | brokered + highest decision floor |

## Prepare -> evaluate -> commit

The broker is not a direct tool dispatcher. It establishes a durable proposal, evaluates the decision floor for the exact proposal revision, then revalidates authority at the commit horizon.

```text
worker proposal
     |
     v
prepare
  validate lease / policy / target / effect class
  persist exact proposal + version vector
     |
     v
evaluate
  deterministic policy
  semantic decision (if required)
  slow verifier (if required)
  human approval (if required)
     |
     v
ready
     |
     v
commit
  re-read epoch / lease / policy / trajectory / revision
  persist commit_intent
  invoke trusted adapter
     |
     +--> committed
     +--> failed
     `--> commit_unknown -> reconciliation
```

## Where TypeSafe enters

If the policy-required decision set contains `semantic`, `EffectBroker` constructs an `Autonomic.ObservationFrame` containing:

- episode ID and epoch;
- a deterministic `:effect_evaluation` fact bound to the payload digest;
- effect class;
- effect kind;
- trusted public target data;
- exact effect revision.

It then calls:

```elixir
Runtime.sensor().observe(frame, mode: :slow)
```

With the reference composition that resolves to `Autonomic.Typesafe.Sensor`, which executes the prepared TypeSafe bank.

The current semantic decision intentionally remains simple and inspectable. It uses:

- `scope_drift`;
- `authority_escalation`; and
- `evidence_sufficiency`.

A policy `semantic.max_risk` threshold defaults to `0.65`. A semantic allow requires no scope/authority observation at or above that threshold **and** sufficient evidence. Anything else is a semantic deny. A sensor error becomes `{:semantic_unavailable, reason}` and degrades semantic health rather than manufacturing a safe answer.

`irreversibility` and `trajectory_regime` are still returned by the same TypeSafe evaluation and are important to the Homeostat path. The broker does not currently perform probability-distribution fusion over all five answers. That distinction is deliberate documentation: the TypeSafe adapter preserves richer answer structure than this policy function currently consumes.

## Decision binding

The semantic decision is persisted against the exact effect revision with evidence that contains normalized sensor references, including sensor, value, confidence, request ID, actual model, and semantic-contract fingerprint. The durable decision record also binds to effect revision, epoch, policy version, trajectory version, and payload digest.

Changing the effect revision invalidates the old decision. Semantic approval is never a reusable global token.

## Why semantic evidence is useful without being authority

TypeSafe can answer questions that deterministic policy cannot express cleanly, for example:

- has the worker materially drifted away from the requested task?
- is it seeking authority unnecessary for the stated task?
- is the evidence for the next action sufficient?
- how consequential does the proposed effect appear?
- what trajectory regime best describes the observable behavior?

The broker can use those judgments to reject an otherwise syntactically valid proposal. It cannot use them to bypass the deterministic authority floor.

## Commit horizon and `commit_unknown`

`commit_intent` is persisted before external adapter actuation. If the process dies after the external action may have happened but before its receipt is durably recorded, the broker does not blindly retry. The effect moves through reconciliation and can remain `commit_unknown` when the target cannot prove either outcome.
