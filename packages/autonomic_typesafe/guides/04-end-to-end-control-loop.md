# End-to-End TypeSafe Semantic Control Loop

This guide follows one semantic evaluation from observable worker state to a concrete Autonomic control decision.

## 1. Produce an observation frame

Core components build `Autonomic.ObservationFrame` values from trusted observation channels. For an effect evaluation the frame includes the exact effect class, kind, target, revision, and payload digest. For trajectory monitoring it may also include visible tool output, resource summaries, and deterministic facts.

## 2. Redact and bound evidence

`Autonomic.Typesafe.Evidence` creates a bounded observable-state map and removes secret-shaped material before the SDK sees it.

## 3. Evaluate the prepared TypeSafe bank

The bank is prepared once:

```elixir
prepared = Autonomic.Typesafe.SensorBank.prepare!()
```

`Autonomic.Typesafe.Bank` submits the bounded state and prepared bank through `TypeSafeSDK.OTP.Server` with strict request/response options.

Conceptually:

```elixir
{:ok, observations} =
  Autonomic.Typesafe.Sensor.observe(frame, mode: :slow)
```

returns five `Autonomic.SemanticObservation` values.

## 4. Preserve rich answers

A representative observation set can express:

```text
scope_drift
  value: false
  confidence: 0.95
  probabilities: %{true => 0.05, false => 0.95}

authority_escalation
  value: false
  confidence: 0.90
  probabilities: %{true => 0.10, false => 0.90}

evidence_sufficiency
  value: "Partial"
  probabilities: %{...}
  metadata:
    expected_level: ...
    expected_label: "Partial"
    modal: ...
    ranked: ...
    normalized: ...

irreversibility
  value: <normalized score>
  probabilities: %{...}
  metadata: <expected/modal/ranked/normalized>

trajectory_regime
  value: :drifting
  probabilities: %{stable: ..., uncertain: ..., drifting: ..., unstable: ...}
  metadata:
    ranked: ...
    margin: ...
```

The exact numeric values come from the TypeSafe response; the structure above is the adapter's normalized contract.

## 5A. EffectBroker path

For an effect whose decision floor requires semantic evidence:

```text
TypeSafe observations
        |
        v
scope/authority risk threshold + evidence sufficiency
        |
        +--> semantic allow
        `--> semantic deny
```

The semantic decision is stored against the exact effect revision. Other required decisions—deterministic policy, slow verifier, human approval—remain independent.

## 5B. Homeostat path

For trajectory control:

```text
TypeSafe observations
      |
      v
semantic risk vector
      |
      v
EWMA temporal state
      |
      v
stable / uncertain / drifting / unstable
      |
      +--> continue
      +--> yield
      +--> narrow authority
      `--> preempt
```

This is where TypeSafe becomes more than a one-shot classifier: repeated typed semantic measurements influence a stateful control loop with hysteresis.

## 6. Persist the evidence and consequences

With `autonomic_postgres`, observation frames, trajectory state, and exact-revision effect decisions are durable. The semantic-contract fingerprint and model/request provenance remain attached to the observations and decision evidence.

## 7. Failure is also a signal

If TypeSafe becomes unavailable, violates the request/response contract, drifts outside an allowed model set, or saturates its local in-flight bound, the semantic path returns an error and updates semantic health. Sensitive commits can then be paused instead of silently skipping required semantic evidence.

## What is deliberately simple today

The TypeSafe-facing layer retains rich distributions, rankings, margins, and provenance. Current core policy does **not** yet perform probabilistic fusion across every distribution. EffectBroker uses selected thresholded signals, while Homeostat converts values/confidence into smoothed risk state.

That is the actual present implementation boundary. The rich TypeSafe results are available without claiming a more sophisticated decision algorithm than the code currently contains.
