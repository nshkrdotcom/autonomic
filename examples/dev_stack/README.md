# Example development stack

| | |
| :--- | :--- |
| **Demonstrates** | A zero-service implementation of Autonomic extension contracts for checking kernel-plane semantics on a laptop. |
| **Requires** | Elixir/OTP and the repository checkout. No PostgreSQL, API key, Rust launcher, or privileged Linux host. |
| **Runtime** | Seconds. |
| **Real** | Core `autonomic` OTP processes, authority leases, epoch fencing, policy evaluation, effect state machine, signatures, Homeostat/SystemRegulator logic. |
| **Simulated** | Persistence, OS execution isolation, external effect targets, semantic observations. |
| **Do not copy** | `Autonomic.Dev.UnsafeLocalDomain`, `MemoryStore`, `MemoryAdapter`, and `ScriptedSensor` are example-only implementations. |

> **NOT FOR PRODUCTION.** `UnsafeLocalDomain` runs commands as the current OS user. It provides **no namespaces, cgroups, seccomp, network isolation, durable authority store, or host-secret boundary**.

The point of this package is not to weaken the architecture. It makes kernel-plane claims executable without pretending that laptop process execution is equivalent to the `autonomic_linux` isolation boundary. Examples that require the OS-plane guarantees say so explicitly and use the production packages instead.

This is an ordinary local Mix dependency used by the numbered examples:

```elixir
{:autonomic_examples_dev, path: "../dev_stack"}
```

It is deliberately outside `packages/` and must never become a dependency of a publishable package.
