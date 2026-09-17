#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v pg_config >/dev/null 2>&1; then
  pg_bindir=$(pg_config --bindir)
else
  pg_bindir=$(dirname "$(command -v initdb || true)")
fi
for bin in initdb pg_ctl createdb; do
  [[ -x "$pg_bindir/$bin" ]] || { echo "missing PostgreSQL server binary: $pg_bindir/$bin" >&2; exit 1; }
done

port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
tmp=$(mktemp -d)
pgdata="$tmp/data"
mkdir -p "$pgdata"
run_as=""
cleanup() {
  set +e
  if [[ -n "$run_as" ]]; then runuser -u "$run_as" -- "$pg_bindir/pg_ctl" -D "$pgdata" stop -m immediate >/dev/null 2>&1
  else "$pg_bindir/pg_ctl" -D "$pgdata" stop -m immediate >/dev/null 2>&1; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  id postgres >/dev/null 2>&1 || { echo 'root execution requires a postgres OS user' >&2; exit 1; }
  run_as=postgres
  chown -R postgres:postgres "$tmp"
  runuser -u postgres -- "$pg_bindir/initdb" -D "$pgdata" -U postgres -A trust --no-locale >/dev/null
  runuser -u postgres -- "$pg_bindir/pg_ctl" -D "$pgdata" -o "-F -p $port -h 127.0.0.1 -k $tmp" -w start >/dev/null
  runuser -u postgres -- "$pg_bindir/createdb" -U postgres -h 127.0.0.1 -p "$port" autonomic_outage
else
  "$pg_bindir/initdb" -D "$pgdata" -U postgres -A trust --no-locale >/dev/null
  "$pg_bindir/pg_ctl" -D "$pgdata" -o "-F -p $port -h 127.0.0.1 -k $tmp" -w start >/dev/null
  "$pg_bindir/createdb" -U postgres -h 127.0.0.1 -p "$port" autonomic_outage
fi

export AUTONOMIC_TEST_DATABASE_URL="ecto://postgres@127.0.0.1:$port/autonomic_outage"
export AUTONOMIC_EPHEMERAL_PGDATA="$pgdata"
export AUTONOMIC_PG_CTL="$pg_bindir/pg_ctl"
if [[ -n "$run_as" ]]; then export AUTONOMIC_PG_RUN_AS="$run_as"; fi

(cd packages/autonomic_postgres && MIX_ENV=test mix ecto.migrate -r Autonomic.Store.Repo)
(cd packages/autonomic_postgres && mix test test/integration/db_outage_test.exs --include postgres --include db_outage)
