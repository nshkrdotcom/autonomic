# Linux Isolation Architecture

`autonomic_linux` implements `Autonomic.ExecutionDomain` for disposable Linux sandboxes.

## Isolation Layers

1. **User Namespaces**: Untrusted code runs mapped to unprivileged host UIDs.
2. **Mount Namespaces & OverlayFS**: Writable scratch layer above an immutable, verified lower rootfs. Edits are ephemeral.
3. **PID, UTS, and IPC Namespaces**: Prevents signal delivery, inter-process communication, or hostname leakage across the boundary.
4. **Network Namespaces**: Untrusted domains have no loopback routing to host services and no default route.
5. **cgroup v2 Containment**: Strict memory ceilings, CPU throttling, and PID limits enforced at kernel level.
6. **Seccomp Filters**: Restricts system calls; violations trigger freeze and containment events.
