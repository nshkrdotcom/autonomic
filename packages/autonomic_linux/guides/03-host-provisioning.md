# Host Provisioning Prerequisites

The current `autonomic_linux` backend requires a Linux host capable of running its shared-kernel containment mechanisms.

## Host prerequisites

- Linux with unified cgroup v2;
- `cpu`, `memory`, and `pids` controllers;
- user/mount/PID/network/IPC/UTS namespaces;
- OverlayFS;
- seccomp filtering;
- a rootfs suitable for the worker workload;
- Rust/Cargo when compiling the native launcher from source;
- privilege configuration allowing the launcher to create/manage the required namespaces, mounts, and cgroups.

## Provisioning is not security qualification

Passing preflight means required kernel features are present. It does **not** prove the host is an adequate trust boundary for every adversarial-agent threat model.

The current backend shares the host kernel with the trusted BEAM control plane. Deployments that require stronger separation from kernel escape or same-machine hardware side channels need a stronger execution backend and/or separate execution hardware. That is outside the present `autonomic_linux` implementation.

## Control-plane placement

In the current backend, the BEAM control plane and launcher execute on the same host as the contained worker. TypeSafe semantic evaluation and database access remain trusted-side concerns and should not be exposed inside the worker namespace/rootfs.

Do not place TypeSafe credentials, PostgreSQL credentials, cloud credentials, authoritative Git credentials, or host home directories into the worker rootfs.
