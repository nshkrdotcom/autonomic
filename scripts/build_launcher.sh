#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cargo >/dev/null || { echo 'cargo is required' >&2; exit 1; }
MANIFEST="packages/autonomic_linux/native/autonomic_launcher/Cargo.toml"
cargo fmt --manifest-path "$MANIFEST" -- --check
cargo clippy --locked --manifest-path "$MANIFEST" --all-targets -- -D warnings
cargo test --locked --manifest-path "$MANIFEST"
cargo build --locked --release --manifest-path "$MANIFEST" --target-dir packages/autonomic_linux/native/autonomic_launcher/target
TARGET_BIN="packages/autonomic_linux/native/autonomic_launcher/target/release/autonomic_launcher"
mkdir -p packages/autonomic_linux/priv
cp "$TARGET_BIN" packages/autonomic_linux/priv/autonomic_launcher
chmod 0755 packages/autonomic_linux/priv/autonomic_launcher
if [[ $# -gt 0 || ${1:-} != "" ]]; then
  install -D -m 0755 "$TARGET_BIN" "${1}"
elif [[ -w /usr/local/libexec ]]; then
  install -D -m 0755 "$TARGET_BIN" /usr/local/libexec/autonomic_launcher
fi
