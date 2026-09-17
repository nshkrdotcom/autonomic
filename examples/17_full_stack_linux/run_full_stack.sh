#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { echo "requires Linux" >&2; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo "requires root (or adapt commands to sudo deliberately)" >&2; exit 2; }
command -v psql >/dev/null || { echo "PostgreSQL client required" >&2; exit 2; }
command -v cargo >/dev/null || { echo "Rust/cargo required" >&2; exit 2; }
command -v mix >/dev/null || { echo "Elixir/Mix required" >&2; exit 2; }

resolve_root() {
  local env_name="$1" tool="$2" asdf_name="$3"
  local explicit="${!env_name:-}"
  if [[ -n "$explicit" ]]; then printf '%s\n' "$explicit"; return 0; fi
  if command -v mise >/dev/null; then mise where "$tool" 2>/dev/null && return 0; fi
  if command -v asdf >/dev/null; then asdf where "$asdf_name" 2>/dev/null && return 0; fi
  return 1
}
OTP_ROOT="$(resolve_root AUTONOMIC_OTP_ROOT erlang erlang)" || { echo "set AUTONOMIC_OTP_ROOT or install/configure Erlang via mise/asdf" >&2; exit 2; }
ELIXIR_ROOT="$(resolve_root AUTONOMIC_ELIXIR_ROOT elixir elixir)" || { echo "set AUTONOMIC_ELIXIR_ROOT or install/configure Elixir via mise/asdf" >&2; exit 2; }

bash "$repo/scripts/provision_host.sh"
bash "$repo/scripts/build_launcher.sh" /tmp/autonomic_launcher
install -D -m 0755 /tmp/autonomic_launcher /usr/local/libexec/autonomic_launcher
rm -rf /opt/autonomic/rootfs
python3 "$repo/scripts/build_rootfs.py" --destination /opt/autonomic/rootfs --otp "$OTP_ROOT" --elixir "$ELIXIR_ROOT"
bash "$repo/scripts/preflight.sh"
echo "Full host preflight sequence completed. Run PostgreSQL migrations and privileged acceptance per docs/HOST_PROVISIONING.md."
