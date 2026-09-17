#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${AUTONOMIC_TEST_DATABASE_URL:?Set AUTONOMIC_TEST_DATABASE_URL}"
: "${AUTONOMIC_ROOTFS:?Set AUTONOMIC_ROOTFS}"
export AUTONOMIC_LINUX=1

(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo || true)
(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo)
(cd integration/autonomic_acceptance && mix test test/coding_agent_test.exs --include reference --include postgres --include linux)
