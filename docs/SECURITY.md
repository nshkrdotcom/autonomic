# Security and Threat Model

`docs/spec/07_THREAT_MODEL_AND_SECURITY.md` is normative. The implementation assumes the worker, repository contents, tool output, stdout/stderr, and semantic evidence may all be hostile or wrong.

## Security boundaries

### Durable authority boundary

PostgreSQL is the authority source for epoch, policy version, leases, effect state, decisions, checkpoints, and recovery lineage. Database loss blocks authoritative progress; TypeSafe availability cannot substitute for a provable current epoch.

### Linux execution boundary

The current `autonomic_linux` backend uses user/mount/PID/network/IPC/UTS namespaces, cgroup v2, chroot/read-only rootfs, OverlayFS, `PR_SET_NO_NEW_PRIVS`, and seccomp. Direct INET socket creation is trapped/denied by the launcher policy and selected violations become deterministic evidence.

This is **same-host shared-kernel isolation**. It is not a VM/microVM boundary, remote worker fleet, or physical separation. A successful host-kernel escape can cross the intended trust boundary; same-machine hardware side channels are outside the guarantees of this backend.

### Effect boundary

Only trusted adapters receive trusted target configuration and credentials. The worker supplies bounded target-relative requests/payloads and cannot widen its own destination/credential scope.

### TypeSafe semantic boundary

The semantic model is not the security root of trust. Before TypeSafeSDK receives state, `Autonomic.Typesafe.Evidence` constructs a bounded observable view and recursively redacts secret-shaped material.

TypeSafeSDK enforces exact final request size, response contracts, model allow-set policy, and answer decoding. Autonomic verifies Prepared-fingerprint identity and required answer-family compatibility. Errors degrade the semantic channel; they never produce a synthetic safe result.

The TypeSafe API key stays on the trusted control-plane side and is not a worker/sandbox credential.

## Defense against semantic manipulation

A repository or worker can attempt to influence the semantic model. Autonomic therefore applies a dominance rule rather than weighted voting:

```text
deterministic denial > semantic approval
```

A high-confidence TypeSafe answer cannot override a forbidden path, stale epoch, invalid lease, disallowed target, seccomp violation, or signed-policy restriction.

Semantic evidence can still make the system more conservative: Homeostat can yield/narrow/preempt, and EffectBroker can deny a proposal whose deterministic syntax was otherwise valid.

## Native launcher

The privileged launcher is an external Rust process rather than an in-process NIF. Requests are bounded structured messages and worker commands are transferred as argv/env/stdin fields. Host provisioning and source review are not equivalent to security qualification on the intended kernel.

## Operational rule

Do not describe `autonomic_linux` as a hardened hostile-agent VM sandbox. Describe it as the current Linux containment backend and qualify it on the intended host. If the threat model requires a stronger kernel/hardware boundary, implement/use a stronger `Autonomic.ExecutionDomain` backend and keep trusted TypeSafe/DB/control-plane credentials off the execution host as appropriate.

Run every mandatory acceptance gate and the live TypeSafe gate before claiming the reference composition is qualified for a deployment environment.
