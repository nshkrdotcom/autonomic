# 11 — Acceptance Gates

The project is not complete until every mandatory gate below is green in an environment capable of running it.

## A. Five kernel invariants

### A1 — No unmediated irreversible effects

- sandbox has no direct routable network;
- direct INET/INET6 socket attempt fails;
- authoritative repository is not writable/mounted into sandbox;
- Class 3/4 effects only occur through broker adapters;
- worker holds no broker long-lived credential.

### A2 — Semantic evidence cannot exceed deterministic authority

- semantic “safe” cannot override deterministic deny fixture;
- fast semantic path cannot widen hard envelope or max effect class;
- sensor poisoning scenario contains/rolls back correctly.

### A3 — Authority is epoch-fenced

- epoch monotonic under concurrent updates;
- lease stale immediately after durable bump;
- prepared old-epoch effect stale;
- old process race to commit is rejected;
- new sandbox generation carries current epoch.

### A4 — Speculation precedes commitment

- Class 0/1 execute only inside disposable domain;
- Class 3/4 have durable proposal + evaluation before commit;
- durable commit intent exists before external mutation;
- Class 4 cannot cross horizon without required slow/human authorization.

### A5 — Worker disposable, kernel authoritative

- kill agent process and recover without authority loss;
- kill entire domain and restore from checkpoint;
- old cgroup empty and upperdir discarded;
- controller reconstructs from durable state after BEAM process restart.

## B. OS containment

- namespaces verified;
- cgroup v2 limits verified;
- seccomp/no-new-privileges verified;
- mount boundary verified;
- direct network denied;
- broker AF_UNIX channel works;
- daemon/fork cleanup verified;
- teardown proof fails closed when old processes remain.

## C. Effect protocol

- all effect states/transitions tested;
- revision-bound decisions tested;
- stale epoch race both orderings tested;
- compare-and-swap Git commit adapter tested;
- HTTP adapter destination/redirect/credential boundaries tested;
- ambiguous commit reconciliation tested;
- no automatic retry of unresolved Class 4 `commit_unknown`.

## D. Semantic supervision

- production TypeSafeSDK 0.2+ integrated, not reimplemented;
- production adapter uses strict `noul/choice/score` + reusable `prepare` + `evaluate`, not the legacy wire-oriented API;
- mandatory live `evaluate` gate green and records SDK version, actual model, request id, usage/retries/timing with secrets excluded;
- Noul/Choice/Score sensor bank decoded and normalized correctly through SDK response/answer helpers;
- sensor-bank version and semantic-contract id are persisted with observations;
- secret redaction and bounded semantic-state/request budget tested before transport;
- required unknown future answer tags become semantic degradation/unavailability, never `safe`;
- configured actual-model contract drift is detected and routed through policy without treating model difference itself as deterministic danger;
- TypeSafe outage/degradation path tested;
- `TypeSafeSDK.RuntimeCapabilities` is reported and any transport capability the deployment relies on is required fail-closed;
- `TypeSafeSDK.Test` covers deterministic adapter semantics but is not counted as the live gate;
- temporal Homeostat/hysteresis tested;
- model output does not directly invoke authority mutation;
- completion does not depend on TypeSafeSDK 0.3: if 0.3 native contract-fingerprint/strict-response/request-budget features are absent, equivalent adapter-level semantics are proven on 0.2.

## E. Backpressure

- GenStage demand path tested under overload;
- deterministic violations never dropped;
- semantic saturation raises pressure;
- admission mode changes under sustained pressure;
- sensitive effects yield instead of bypassing verification;
- speculation budget prevents endless work while commit horizon blocked.

## F. Durability/recovery

- real PostgreSQL integration green;
- epoch transaction race green;
- effect commit intent survives BEAM crash;
- reconciliation on restart green;
- checkpoint digest/metadata agreement enforced;
- owner lease behavior tested if clustering enabled;
- DB outage blocks authoritative effects.

## G. Reference coding-agent scenario

Both required variants green:

1. normal repair succeeds and broker commits verified authoritative Git commit;
2. worker attempts secret path/direct network, deterministic tripwire wins, epoch advances, old domain is destroyed, checkpoint restored, repaired worker succeeds, final commit authorized under new epoch.

## H. Quality

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- full ExUnit suite
- `mix credo --strict`
- Dialyzer green
- docs warnings-as-errors
- Rust launcher fmt/clippy/test green
- no checked-in credentials
- dependency/audit review complete
- host preflight script green

## I. Evidence

`artifacts/conformance_report.json` exists and records the actual environment and gate outcomes. Mandatory skipped gates mean the implementation is a handoff candidate, not a completed release.

## J. Documentation

Repository includes:

- architecture/invariants;
- threat model;
- Linux host provisioning/preflight;
- effect adapter authoring guide;
- semantic sensor authoring/calibration guide;
- operator runbooks;
- PostgreSQL migrations/data model;
- development/testing guide;
- HANDOFF with no ambiguous “probably works” statements.
