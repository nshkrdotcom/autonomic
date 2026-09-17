# Changelog: `autonomic_linux`

All notable changes to the `autonomic_linux` execution domain package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-17

### Added
- Linux execution domain implementation of `Autonomic.ExecutionDomain`.
- Privileged external Rust launcher daemon (`native/autonomic_launcher`).
- User, mount, PID, network, IPC, and UTS namespace containment.
- cgroup v2 controller configuration (CPU, memory, PIDs).
- Seccomp system call filtering.
- OverlayFS disposable layer management with rollback capability.
- Preflight validation suite for host prerequisites.
