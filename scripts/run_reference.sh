#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${AUTONOMIC_TEST_DATABASE_URL:?Set AUTONOMIC_TEST_DATABASE_URL}"
: "${AUTONOMIC_ROOTFS:?Set AUTONOMIC_ROOTFS}"
export AUTONOMIC_LINUX=1

echo '[reference] resolving PostgreSQL package dependencies'
(cd packages/autonomic_postgres && MIX_ENV=test mix deps.get)

echo '[reference] resolving acceptance project dependencies'
(cd integration/autonomic_acceptance && MIX_ENV=test mix deps.get)

echo '[reference] ensuring PostgreSQL test database exists'
(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.create -r Autonomic.Store.Repo || true)

echo '[reference] applying PostgreSQL migrations'
(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo)

echo '[reference] running privileged PostgreSQL + Linux acceptance scenario'
(cd integration/autonomic_acceptance && \
  MIX_ENV=test \
  mix test test/coding_agent_test.exs --include reference --include postgres --include linux)
