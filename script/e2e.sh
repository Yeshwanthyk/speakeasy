#!/usr/bin/env bash
# Desktop end-to-end test of the installed Speakeasy.app. See README.md.
# Usage: ./script/e2e.sh [full|quick] [--no-install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG="${FFMPEG:-/opt/zerobrew/prefix/bin/ffmpeg}"
MODE="${1:-full}"
INSTALL=1
[[ "${2:-}" == "--no-install" ]] && INSTALL=0
THRESHOLD="${SPEAKEASY_E2E_MAX_WER:-0.15}"
[[ -x "$FFMPEG" ]] || { echo "ffmpeg not found at $FFMPEG" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/speakeasy-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Case plan: fixture sequences joined by 0.7 s of silence, with concatenated references.
python3 - "$ROOT/benchmarks/fixtures/manifest.json" "$WORK" "$MODE" <<'PY'
import json, pathlib, sys
manifest, out, mode = sys.argv[1:]
root = pathlib.Path(manifest).parent
out = pathlib.Path(out)
fixtures = {f['id']: f for f in json.loads(pathlib.Path(manifest).read_text())['fixtures']}
GAP = 0.7
plan = []
def add(name, ids, cancel=False, minimum=0, no_auto_stop_after=None):
    items = [fixtures[i] for i in ids]
    seconds = sum(f['duration_ms'] for f in items) / 1000 + GAP * (len(items) - 1)
    if len(items) == 1:
        audio = str(root / items[0]['audio'])
    else:
        listing = out / f'{name}.concat'
        entries = []
        for index, f in enumerate(items):
            if index:
                entries.append(str(out / 'gap.wav'))
            entries.append(str(root / f['audio']))
        listing.write_text(''.join("file '" + p.replace("'", "'\\''") + "'\n" for p in entries))
        audio = str(out / f'{name}.wav')
    plan.append(dict(name=name, audio=audio, reference=' '.join(f['reference'] for f in items),
                     seconds=seconds, cancel=cancel, minimumSegments=minimum,
                     assertNoAutoStopAfter=no_auto_stop_after))
cycle = ['long-001', 'medium-002', 'short-001', 'medium-001', 'short-002']
add('short', ['medium-001'])
add('10s', ['long-001'])
if mode != 'quick':
    add('30s', ['long-001', 'medium-002', 'medium-001', 'long-001', 'short-002'])
    add('6.5min', cycle * 18, minimum=3, no_auto_stop_after=362)
add('cancel', ['long-001'], cancel=True)
(out / 'cases.json').write_text(json.dumps(plan, indent=1))
for case in plan:
    print(f"  {case['name']:7} {case['seconds']:6.1f} s  {pathlib.Path(case['audio']).name}", file=sys.stderr)
PY
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=16000:cl=mono' -t 0.7 -c:a pcm_s16le "$WORK/gap.wav"
for list in "$WORK"/*.concat; do
  [[ -f "$list" ]] || continue
  "$FFMPEG" -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" -ar 16000 -ac 1 -c:a pcm_s16le "${list%.concat}.wav"
done

mkdir -p "$ROOT/build"
swiftc -O "$ROOT/script/e2e_driver.swift" -framework AppKit -framework ApplicationServices -o "$ROOT/build/e2e_driver"
# Fails fast with instructions if Accessibility or Notes automation is missing.
"$ROOT/build/e2e_driver" --check
if [[ "$INSTALL" == 1 ]]; then
  "$ROOT/script/build_and_run.sh" install
fi
echo "Driving Speakeasy for about $([[ "$MODE" == quick ]] && echo 1 || echo 9) minute(s); do not type or change focus." >&2
"$ROOT/build/e2e_driver" "$WORK/cases.json" "$THRESHOLD"
