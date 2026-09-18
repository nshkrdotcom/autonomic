# Trust Boundary, TypeSafe, and the Execution Plane

This guide states the current boundary precisely so that deployment claims match the implementation.

## What runs where today

With `Autonomic.Linux.Backend`, all of these processes are on one Linux machine:

- trusted BEAM Autonomic control plane;
- `Autonomic.Typesafe.Bank` and TypeSafeSDK client;
- `Autonomic.Store.Postgres` client;
- native Rust launcher;
- untrusted worker contained by namespaces/cgroup/seccomp/OverlayFS.

The worker does **not** need the TypeSafe client or its API key. Semantic evaluation happens in the trusted BEAM process from bounded/redacted observation frames.

## Control loop across the boundary

```text
contained worker
   |
   | stdout/stderr, execution result,
   | deterministic boundary facts, effect proposal
   v
trusted BEAM control plane
   |
   +--> deterministic policy / AuthorityGovernor
   |
   +--> TypeSafe semantic sensor bank
   |       scope drift
   |       authority escalation
   |       evidence sufficiency
   |       irreversibility
   |       trajectory regime
   |
   +--> Homeostat / EffectBroker
   |
   `--> continue / narrow / yield / preempt / deny
```

TypeSafe is therefore a control-plane semantic sensor over observable worker behavior; it is not software installed into the untrusted domain to police itself.

## What this backend protects against

It is intended to constrain ordinary process/filesystem/network/resource behavior using Linux isolation primitives and to convert certain violations into deterministic evidence.

## What this backend does not claim

The current implementation does not provide:

- a remote worker fleet;
- SSH runtime orchestration;
- BEAM-clustered sandbox hosts;
- Firecracker/Kata/microVM isolation;
- a dedicated guest kernel;
- physical host separation;
- protection from every same-machine microarchitectural/power/thermal side channel;
- protection if a hostile worker obtains a successful host-kernel escape.

## Path to a stronger boundary

A stronger deployment can keep the same core interfaces while replacing only the execution backend:

```text
trusted Autonomic control plane
       |
       | authenticated narrow lifecycle protocol
       v
untrusted execution host / VM service
       |
       v
microVM or dedicated machine per episode
```

That remote/hardware-backed backend is not implemented by `autonomic_linux` today. Documenting it as future topology should not be confused with current capability.
