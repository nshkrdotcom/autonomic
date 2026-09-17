# 18 · LLM agent loop

| | |
| :--- | :--- |
| **Demonstrates** | A bounded model/tool loop routes local work to ExecutionDomain and external actions to EffectBroker. |
| **Requires** | API key for live model; deterministic scripted mode by default. |
| **Runtime** | Seconds for the local path unless noted. |
| **Real** | Kernel routing boundary. |
| **Simulated** | Model responses in default mode. |
| **Do not copy** | Do not give the model direct credentials or network mutation tools. |

Run from this directory:

```bash
mix deps.get
mix run
```

The script exits non-zero if its final invariant does not hold.

`run.exs` uses a deterministic `ExampleAgentModel` implementation so the example is reproducible. The model boundary is a behaviour: replace it with your live provider client without changing the tool router. A live provider must return structured tool intents only; credentials remain outside the worker/model state.
