#!/usr/bin/env bash
# Runs the in-process fuzz targets for longer than the default `swift test`
# budget. Usage: script/fuzz.sh [seconds-per-target] [test-filter]
#   SPEAKEASY_FUZZ_SEED=<n> script/fuzz.sh   reproduces a printed run.
set -euo pipefail
cd "$(dirname "$0")/.."
export SPEAKEASY_FUZZ_SECONDS="${1:-60}"
swift test --filter "${2:-Fuzz}"
