#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cargo >/dev/null || { echo 'cargo is required' >&2; exit 1; }
cargo fmt --manifest-path native/autonomic_launcher/Cargo.toml -- --check
cargo clippy --manifest-path native/autonomic_launcher/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path native/autonomic_launcher/Cargo.toml
cargo build --release --manifest-path native/autonomic_launcher/Cargo.toml
install -m 0755 native/autonomic_launcher/target/release/autonomic_launcher "${1:-/usr/local/libexec/autonomic_launcher}"
