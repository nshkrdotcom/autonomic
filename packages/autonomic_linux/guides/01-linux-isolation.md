# Linux Isolation Architecture

`autonomic_linux` implements `Autonomic.ExecutionDomain` using a real native Linux containment backend.

## Current isolation layers

The launcher creates and manages:

1. user namespaces;
2. mount namespaces and an OverlayFS workspace;
3. PID namespaces;
4. network namespaces;
5. IPC namespaces;
6. UTS namespaces;
7. cgroup v2 CPU/memory/PID controls;
8. chroot/read-only rootfs boundaries;
9. `PR_SET_NO_NEW_PRIVS` / seccomp filtering;
10. a per-episode AF_UNIX effect-broker socket mounted into the domain.

The backend also converts detected seccomp violations and selected forbidden host-path attempts into deterministic observation facts that can trigger hard containment through core.

## Exact trust statement

The current backend is **host-local shared-kernel containment**.

```text
same Linux machine
+--------------------------------------------------+
| BEAM trusted control plane                       |
| PostgreSQL client / TypeSafe client / broker     |
|                                                  |
| host kernel                                      |
|    +----------------------------------------+    |
|    | worker namespaces + cgroup + seccomp   |    |
|    | overlay workspace                      |    |
|    +----------------------------------------+    |
+--------------------------------------------------+
```

It is not a Firecracker/Kata/microVM backend. It is not a remote worker-fleet protocol. It is not a hardware-side-channel boundary. A hostile workload that escapes the shared kernel could threaten the control plane on the same machine.

Those limitations must be part of any security claim made about this package.

## Relationship to TypeSafe

TypeSafe does not run inside the sandbox and is not a substitute for isolation. The worker generates observable activity; trusted control-plane code turns that activity into `ObservationFrame`s and may send bounded/redacted state through `Autonomic.Typesafe.Sensor`.

A semantic answer can cause the core to narrow, yield, or preempt. It cannot disable namespaces/seccomp or widen filesystem/network access.

## Extension point for stronger backends

The core `Autonomic.ExecutionDomain` behaviour is intentionally backend-neutral (`create`, `exec`, `signal`, `checkpoint`, `restore`, `destroy`, `inspect_domain`). A future remote VM/microVM backend can implement that contract without changing the TypeSafe semantic bank or the core effect policy.
