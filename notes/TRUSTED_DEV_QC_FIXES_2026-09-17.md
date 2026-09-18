# Trusted development / QC fixes

Runtime validation host: omen-ubuntu26-dev, Ubuntu 26.04.1.

## Confirmed runtime evidence

- examples: 24/24 PASS
- privileged example 17: PASS
- host preflight: PASS
- Linux containment integration: 3/3 PASS
- PostgreSQL + Linux reference acceptance: 2/2 PASS
- repository-wide handoff QC:
  - every executable/local mandatory gate PASS
  - only typesafe_live_evaluate_v4 PEND because the QC process did not have a configured credential

## Required source changes

### 1. Trusted local development configuration

Support a machine-local file:

  ~/.config/autonomic/dev.toml

with a separate secret file:

  ~/.config/autonomic/secrets/typesafe_api_key

Requirements:

- repository files never contain the credential
- no .env sourcing
- no eval
- no shell prompt for normal trusted-dev QC
- explicit environment variables retain highest precedence
- support explicit TYPESAFE_API_KEY_FILE
- trusted dev config is fallback only
- secret file must be regular, owned by invoking UID, non-symlink, mode 0600
- config/secrets directories must not be group/world writable
- reject unknown profile keys
- never print credential values
- pass TypeSafe credential only to the process that needs the live TypeSafe gate

Credential precedence:

1. TYPESAFE_API_KEY
2. TYPESAFE_API_KEY_FILE
3. trusted dev profile api_key_file
4. unavailable

### 2. QC UX

scripts/qc / scripts/qc.py must no longer appear hung.

Print:

- START <gate>
- PASS/FAIL/PEND <gate> <elapsed>
- package/substep for aggregate gates
- periodic heartbeat for genuinely long-running subprocesses
- final concise summary and report path

Full command output may remain in artifacts/logs.

Ensure subprocess/terminal cleanup is correct.

### 3. run_reference.sh

Make a fresh checkout self-contained regarding Mix dependencies.

It must obtain the required MIX_ENV=test dependencies before attempting
ecto.create, ecto.migrate or acceptance tests.

### 4. Secret leakage tests

Prove the TypeSafe key is absent from:

- artifacts/typesafe_live_gate.json
- artifacts/conformance_report.json
- artifacts/logs/*
- command strings recorded in conformance evidence

### 5. Previously discovered source/runtime fixes

Preserve all examples-suite runtime fixes and the AuthorityGovernor audit-reason
serialization fix. Add/retain the regression test for non-JSON-safe containment
reason terms.
