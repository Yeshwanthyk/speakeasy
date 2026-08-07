#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_manifest="$repo_root/benchmarks/speech-bench/Cargo.toml"
production_manifest="$repo_root/rust/asr_bridge/Cargo.toml"

production_version="$(cargo tree --locked --manifest-path "$production_manifest" -p transcribe-cpp --depth 0)"
benchmark_version="$(cargo tree --locked --manifest-path "$benchmark_manifest" -p transcribe-cpp --depth 0)"
if [[ "$production_version" != "$benchmark_version" ]]; then
  printf 'transcribe.cpp version mismatch:\n  production: %s\n  benchmark:  %s\n' "$production_version" "$benchmark_version" >&2
  exit 1
fi

cargo fmt --manifest-path "$benchmark_manifest" -- --check
cargo test --locked --manifest-path "$benchmark_manifest"
cargo clippy --locked --manifest-path "$benchmark_manifest" --all-targets -- -D warnings

while IFS= read -r -d '' config; do
  cargo run --locked --quiet --manifest-path "$benchmark_manifest" -- validate "$config" >/dev/null
done < <(find "$repo_root/benchmarks/configs" -type f -name '*.json' -print0 | sort -z)

cargo run --locked --quiet --manifest-path "$benchmark_manifest" -- catalog >/dev/null

printf 'benchmark harness checks passed (%s)\n' "$benchmark_version"
