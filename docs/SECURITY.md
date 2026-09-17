# Security and threat model

`docs/spec/07_THREAT_MODEL_AND_SECURITY.md` is normative. This implementation assumes the worker, repository contents, stdout/stderr, tool output and semantic evidence may all be hostile.

## Boundaries

- **Kernel/DB boundary:** PostgreSQL is the authority source for epoch, policy version, leases, effect state, decisions, checkpoints and recovery lineage. DB loss blocks authoritative effect commits.
- **OS boundary:** Linux namespaces, cgroup v2, chroot/read-only rootfs, overlayfs, `PR_SET_NO_NEW_PRIVS`, seccomp and a network namespace constrain the worker. Direct AF_INET/AF_INET6 `socket()` is trapped with `SIGSYS` so it becomes deterministic evidence.
- **Effect boundary:** only trusted adapters receive trusted target configuration and credentials. The worker supplies a bounded target-relative request and payload bytes, never a host target path or credential.
- **Semantic boundary:** `Autonomic.Typesafe.Evidence` redacts secret-shaped fields/text and enforces a byte budget before `TypeSafeSDK.evaluate/4`. Unknown required answer tags, configured concrete-model drift, unavailable transport guarantees and semantic outages fail closed as semantic degradation.

## Native launcher

The launcher is intentionally a small external privileged process. Requests are packet-framed JSON with protocol versioning, request/reply limits, action-specific allowed fields and structural argv/env transfer. It does not execute worker-supplied shell command strings. Each lifecycle request uses a one-shot Port process so an executing worker cannot serialize or block a concurrent destroy/freeze request. Domain metadata is persisted and validated on rehydration.

The reference seccomp filter denies namespace/mount/ptrace/key/BPF/perf escape-oriented syscalls and traps AF_INET/AF_INET6 sockets. It is not a substitute for keeping the mount surface minimal. The rootfs must not contain host secrets.

## HTTP mediation

The HTTP adapter owns DNS/TLS, redirects (`autoredirect: false`), method allowlists, host/path checks, body/response limits, broker-selected credentials, idempotency headers and rate limits. Response bytes are placed in the trusted content-addressed payload store and exposed to the worker only through bounded `fetch_response` chunks.

## Git mediation

The worker never receives the authoritative repository writable. It proposes an exact patch against an exact base OID. Slow verification replays that exact patch in a separate clean disposable domain. The trusted Git adapter materializes the patch in a trusted worktree and uses compare-and-swap ref update. Reconciliation searches for the effect identity marker and detects unrelated ref movement as ambiguous rather than claiming success.

## Operational rule

A source audit is not a sandbox qualification. Deploy only after all mandatory gates in `docs/spec/11_ACCEPTANCE_GATES.md` are green on the intended kernel/cgroup/filesystem host and the live TypeSafe gate has run with non-secret provenance.
