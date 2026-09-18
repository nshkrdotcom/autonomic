# Launcher Protocol and Native Integration

The current Linux backend talks to an external Rust launcher through an OTP Port. The launcher is kept outside the BEAM VM so privileged native lifecycle work is not implemented as an in-process NIF.

## Current topology

```text
Autonomic.Linux.Backend
        |
        v
Autonomic.Linux.Launcher
        |
        | packet-framed JSON over local stdio Port
        v
privileged autonomic_launcher
        |
        v
local Linux namespaces / cgroup / OverlayFS / seccomp
```

This is a **local** protocol. The current implementation does not SSH to worker machines, use BEAM distribution for sandbox lifecycle, or expose a remote execution RPC service.

## Requests

`Autonomic.Linux.Backend` uses launcher operations for domain lifecycle including creation, execution, signaling, checkpointing, restore, destruction, and inspection. The backend passes structured argv/env/stdin fields; it does not need to turn a worker request into an arbitrary shell command string.

## Why this matters to the rest of Autonomic

The launcher produces deterministic evidence such as seccomp violations and lifecycle/destruction results. Core can feed those facts into SensorArray/Homeostat independently of any semantic model.

TypeSafe semantic evaluation remains on the trusted control-plane side. The launcher does not receive the TypeSafe API key and does not call TypeSafeSDK.

## Remote-worker implication

If a future implementation moves execution onto separate machines or hardware-backed VMs, this local Port protocol is not by itself the remote transport. A remote backend would need its own authenticated lifecycle protocol and worker-host service while preserving the `Autonomic.ExecutionDomain` contract.
