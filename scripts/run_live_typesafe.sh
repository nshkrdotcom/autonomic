#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TYPESAFE_API_KEY:?Set TYPESAFE_API_KEY intentionally; this calls the live service}"
(cd packages/autonomic_typesafe && mix test test/live_gate_test.exs --include live)
