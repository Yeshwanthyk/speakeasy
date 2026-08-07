#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_path="$repo_root/benchmarks/speech-bench/Cargo.toml"
config_path="${1:-$repo_root/benchmarks/configs/production-parity.json}"
if (( $# > 0 )); then
  shift
fi

cargo build --release --locked --manifest-path "$manifest_path" --bins
exec "$repo_root/benchmarks/speech-bench/target/release/speech-bench" run "$config_path" "$@"
