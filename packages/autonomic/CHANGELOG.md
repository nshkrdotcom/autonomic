# Changelog

All notable changes to `autonomic` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-17

### Added
- Core BEAM/OTP control plane and episode supervisor trees.
- `Autonomic.AuthorityGovernor` with epoch-fenced capability leasing.
- `Autonomic.EffectBroker` for mediated external side effects and commit horizons.
- `Autonomic.Homeostat` and `Autonomic.SystemRegulator` for health and trajectory monitoring.
- `Autonomic.SensorArray` and sensor stream management.
- `Autonomic.VerificationRunner` and `Autonomic.RepairManager`.
- Authoritative effect adapters for Git, GitRemote CAS, bounded HTTP, and content-addressed artifacts.
- Behaviours for execution domains (`Autonomic.ExecutionDomain`), stores (`Autonomic.Store`), and sensors (`Autonomic.SemanticSensor`).
- Poncho standalone package structure with independent Hex publication support.

[0.1.0]: https://github.com/nshkrdotcom/autonomic/releases/tag/autonomic-v0.1.0
