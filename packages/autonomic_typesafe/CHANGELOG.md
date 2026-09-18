# Changelog

All notable changes to `autonomic_typesafe` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-17

### Added
- Semantic sensor backend implementing `Autonomic.SemanticSensor`.
- Greenfield integration with TypeSafeSDK 0.4.0 and the Jev model family.
- SDK-native `Prepared` fingerprints as the semantic contract identity.
- SDK-native strict response contracts and exact serialized request-byte budgets.
- Bounded non-blocking semantic execution through `TypeSafeSDK.OTP.Server` on the package-owned `Autonomic.Typesafe.Tasks` supervisor.
- Required Pristine-backed unary cancellation and cancellation-cleanup capabilities, checked through `TypeSafeSDK.RuntimeCapabilities`.
- Privacy-safe TypeSafe response/error metadata and per-answer telemetry correlation without logging semantic payloads.
- Evidence redaction, sanitization, and bounding in `Autonomic.Typesafe.Evidence`.
- Fixed Prepared sensor bank for scope drift, authority escalation, evidence sufficiency, effect irreversibility, and trajectory regime.
- Deterministic component testing suite with `TypeSafeSDK.Test`.
- Explicit live integration gate.

[0.1.0]: https://github.com/nshkrdotcom/autonomic/releases/tag/autonomic_typesafe-v0.1.0
