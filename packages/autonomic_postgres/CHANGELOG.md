# Changelog: `autonomic_postgres`

All notable changes to the `autonomic_postgres` authority store package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-17

### Added
- PostgreSQL durable authority store implementing `Autonomic.Store`.
- Ecto schemas for episodes, leases, checkpoints, effects, decisions, events, observation frames, and recovery records.
- Complete initial PostgreSQL migration creating all authoritative tables and indexes.
- Atomic epoch advancement with strict CAS fencing.
- Transactional effect ledger with commit-intent and reconciliation tracking.
