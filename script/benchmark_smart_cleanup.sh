#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-smart}"
repetitions="${2:-3}"
output="${3:-$repo_root/benchmarks/results/app-aware-$(date +%Y%m%d-%H%M%S)-$mode.jsonl}"
arch="$(uname -m)"
binary="${TMPDIR:-/tmp}/speakeasy-smart-cleanup-bench"

case "$mode" in
  exact|basic|smart) ;;
  *) printf 'mode must be exact, basic, or smart\n' >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$output")"

swiftc \
  -O \
  -parse-as-library \
  -target "$arch-apple-macosx12.0" \
  "$repo_root/Sources/TranscriptPostProcessor.swift" \
  "$repo_root/Sources/SmartCleanupCore.swift" \
  "$repo_root/Sources/FoundationModelsSmartCleanupProvider.swift" \
  "$repo_root/benchmarks/smart-cleanup/main.swift" \
  -o "$binary"

"$binary" \
  "$repo_root/benchmarks/smart-cleanup/fixtures.json" \
  "$mode" \
  "$repetitions" \
  > "$output"

python3 - "$output" <<'PY'
import json
import pathlib
import statistics
import sys

path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
wall = sorted(row["wallMs"] for row in rows)
provider = sorted(row["providerMs"] for row in rows if row.get("providerMs") is not None)

def percentile(values, fraction):
    if not values:
        return None
    return values[round((len(values) - 1) * fraction)]

summary = {
    "artifact": str(path),
    "mode": rows[0]["mode"] if rows else None,
    "samples": len(rows),
    "wall_ms_p50": statistics.median(wall) if wall else None,
    "wall_ms_p95": percentile(wall, 0.95),
    "provider_ms_p50": statistics.median(provider) if provider else None,
    "provider_ms_p95": percentile(provider, 0.95),
    "fallbacks": sum(1 for row in rows if row["usedFallback"]),
    "anchor_failures": sum(1 for row in rows if not row["anchorsPreserved"]),
    "peak_rss_mib": max((row["peakRSSBytes"] for row in rows), default=0) / 1048576,
}
summary_path = path.with_suffix(".summary.json")
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
