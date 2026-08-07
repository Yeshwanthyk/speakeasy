#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_path="$repo_root/benchmarks/speech-bench/Cargo.toml"
binary_path="$repo_root/benchmarks/speech-bench/target/release/speech-bench"
config_dir="$repo_root/benchmarks/configs/candidates"
output_dir="$repo_root/benchmarks/results/compact-candidates"

cargo build --release --locked --manifest-path "$manifest_path" --bins
mkdir -p "$output_dir"

for config_path in "$config_dir"/*.json; do
  preset="$(basename "$config_path" .json)"
  "$binary_path" run "$config_path" \
    --output "$output_dir/$preset.jsonl"
done
