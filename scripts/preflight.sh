#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
failed=0
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then printf 'ok   %-24s %s\n' "$1" "$(command -v "$1")"; else printf 'FAIL %-24s missing\n' "$1"; failed=1; fi
}
for cmd in elixir mix erl cargo rustc psql git unshare nsenter mount; do check_cmd "$cmd"; done

if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  echo "ok   cgroup v2                $(cat /sys/fs/cgroup/cgroup.controllers)"
else
  echo 'FAIL cgroup v2                /sys/fs/cgroup/cgroup.controllers missing'; failed=1
fi

grep -qw overlay /proc/filesystems && echo 'ok   overlayfs                 available' || { echo 'FAIL overlayfs                 unavailable'; failed=1; }

rootfs=${AUTONOMIC_ROOTFS:-/var/lib/autonomic/rootfs}
for path in "$rootfs" "$rootfs/workspace" "$rootfs/run" "$rootfs/tmp" "$rootfs/proc"; do
  [[ -d "$path" ]] && echo "ok   rootfs path               $path" || { echo "FAIL rootfs path               $path"; failed=1; }
done

launcher=${AUTONOMIC_LAUNCHER:-native/autonomic_launcher/target/release/autonomic_launcher}
[[ -x "$launcher" ]] && echo "ok   launcher                  $launcher" || { echo "FAIL launcher                  $launcher not executable"; failed=1; }

state_root=${AUTONOMIC_LINUX_STATE_ROOT:-/var/lib/autonomic}
[[ -d "$state_root" && -w "$state_root" ]] && echo "ok   state root                $state_root" || { echo "FAIL state root                $state_root not writable"; failed=1; }

if [[ -n ${AUTONOMIC_TEST_DATABASE_URL:-} ]]; then
  psql "$AUTONOMIC_TEST_DATABASE_URL" -Atqc 'select 1' >/dev/null && echo 'ok   PostgreSQL test DB         reachable' || { echo 'FAIL PostgreSQL test DB         unreachable'; failed=1; }
else
  echo 'WARN PostgreSQL test DB         AUTONOMIC_TEST_DATABASE_URL not set'
fi

if [[ ${failed} -ne 0 ]]; then
  echo 'preflight: FAILED' >&2
  exit 1
fi
echo 'preflight: PASS'
