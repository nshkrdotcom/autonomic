# Autonomic Acceptance Test Suite

This project (`integration/autonomic_acceptance`) is a private, non-published integration harness for the Autonomic Kernel monorepo.

## Purpose

It owns cross-package system tests that verify the end-to-end composition of:
- `autonomic` (core kernel control plane)
- `autonomic_linux` (cgroup v2 / namespace execution domain)
- `autonomic_postgres` (PostgreSQL durable authority store)
- `autonomic_typesafe` (TypeSafe/Jev semantic sensor bank)

## Running Acceptance Tests

```bash
AUTONOMIC_LINUX=1 \
AUTONOMIC_ROOTFS=/opt/autonomic/rootfs \
AUTONOMIC_TEST_DATABASE_URL='ecto://autonomic:autonomic@127.0.0.1/autonomic_test' \
mix test test/coding_agent_test.exs --include reference --include postgres --include linux
```
