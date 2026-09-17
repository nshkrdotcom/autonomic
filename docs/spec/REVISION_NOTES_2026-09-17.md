# Revision Notes — 2026-09-17

This revision updates the original Autonomic Kernel implementation docset from the TypeSafeSDK 0.1-era assumptions to the production TypeSafeSDK 0.2.0 semantic layer.

Key changes:

- TypeSafe dependency baseline moved to `~> 0.2.0`.
- Production semantic integration moved from legacy `SystemOne.run`/legacy question structs to strict `noul/choice/score` + reusable `prepare` + `evaluate`.
- SDK-owned responsibilities are removed from the Autonomic implementation scope: semantic question validation/encoding, request-relative response validation, answer enrichment/uncertainty helpers, semantic telemetry, bounded per-enumeration batching, application test transport, runtime-capability reporting and wire-schema maintenance.
- `autonomic_typesafe` now owns only domain-specific evidence construction/redaction, bank definition, provenance, health policy, response normalization and kernel-specific fail-closed rules.
- Required unknown future answer tags are explicitly degradation/unavailability, never safe.
- Actual response model and semantic-contract identity are first-class provenance.
- Deterministic component testing uses `TypeSafeSDK.Test`, while the real live `evaluate` gate remains mandatory.
- Added `12_TYPESAFE_SDK_INTEGRATION.md` with the normative 0.2 contract and optional 0.3 migration.
- Optional future TypeSafeSDK 0.3 scope is limited to reusable semantic-contract fingerprinting, strict response contracts, and final serialized-request byte limits. The kernel does not depend on 0.3.

The five kernel invariants, Linux containment model, effect transaction protocol, durable authority, Homeostat, GenStage backpressure, snapshot/repair design and acceptance philosophy remain unchanged.
