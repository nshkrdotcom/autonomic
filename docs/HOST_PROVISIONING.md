# Linux host provisioning and preflight

The launcher is designed for a dedicated Linux host or VM where privileged namespace/cgroup operations are intentional. Do not grant these privileges to an arbitrary desktop plugin/session without understanding the boundary.

## Kernel/filesystem prerequisites

- unified cgroup v2 mounted at `/sys/fs/cgroup` with CPU/memory/PID controllers;
- user, mount, PID, network, IPC and UTS namespaces enabled;
- overlayfs available;
- seccomp filter support;
- `unshare`, `nsenter`, `mount`, Git;
- PostgreSQL server/client;
- Elixir 1.20 / OTP 29 and Rust toolchain.

`sudo bash scripts/provision_host.sh` installs the distro-level packages on Debian/Ubuntu but deliberately does not silently choose a different Elixir/OTP/Rust version from `.tool-versions`.

## Rootfs

`AUTONOMIC_ROOTFS` is a trusted immutable base directory. It must include the binaries/libraries needed by the worker and empty mountpoints `/workspace`, `/run`, `/tmp`, `/proc`. It must not contain host secrets, private SSH keys, cloud credentials, Docker sockets or user home data. Keep it versioned/checksummed outside the worker.

## Privilege model

By default the BEAM process invokes the launcher as `sudo -n -- <launcher> daemon`. Configure a narrow sudoers rule for the exact immutable launcher path and trusted operator account, or run the kernel under an already-privileged service account and set `AUTONOMIC_NO_SUDO=1`. Never permit workers to execute the launcher binary directly.

## Validation

Run `bash scripts/preflight.sh` before integration gates. Then run the native build and the Linux containment tests. A preflight pass is necessary but not sufficient: only the containment gate proves the exercised host behavior.
