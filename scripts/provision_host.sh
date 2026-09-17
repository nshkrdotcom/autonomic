#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'run as root: sudo bash scripts/provision_host.sh' >&2
  exit 1
fi

# Debian/Ubuntu reference packages. Elixir/OTP and Rust versions are pinned by .tool-versions;
# install them with the host's chosen asdf/mise setup rather than silently downgrading here.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential git curl ca-certificates pkg-config jq \
  postgresql postgresql-client \
  util-linux iproute2 mount cgroup-tools libseccomp2

install -d -m 0700 /var/lib/autonomic /var/lib/autonomic/kernel
install -d -m 0755 /usr/local/libexec /opt/autonomic

if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
  echo 'ERROR: unified cgroup v2 is required' >&2
  exit 1
fi

cat <<'MSG'
Base host packages installed.
Next:
  1. install the exact .tool-versions (Elixir 1.20.4/OTP 29.0.6, Rust 1.90.0)
  2. build the trusted runtime image with scripts/build_rootfs.py (see docs/DEVELOPMENT.md)
  3. run: sudo bash scripts/build_launcher.sh
  4. provision PostgreSQL role/databases and set DATABASE_URL/AUTONOMIC_TEST_DATABASE_URL
  5. run: bash scripts/preflight.sh
MSG
