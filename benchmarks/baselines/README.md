# Benchmark baselines

A baseline is an immutable JSONL result from a clean, stable run on one identified Mac. It contains no transcript text, but it does contain hardware/build identity, model and corpus hashes, timing, memory, and accuracy counts. Review it before sharing.

## Promotion workflow

1. Run `./script/test_benchmark.sh` and the relevant Swift tests.
2. Use a clean worktree/commit. Dirty-state fingerprints intentionally prevent comparison with a different source state.
3. Record the production-parity release preset at least twice while on power and thermally settled.
4. Confirm repeated p50/p95, WER, RSS, errors, actual backend, and device are stable.
5. Copy the chosen JSONL here using a descriptive path such as `m4-pro/parakeet-unified-q8/2026-08-06.jsonl`.
6. Add a neighboring Markdown note with macOS version, power/thermal conditions, corpus ID, rationale, and the command used.
7. Compare a same-configuration regression run without allowances. For a one-knob optimization, pass exactly one `--allow-change` path. Source-level candidates must additionally declare `build.repository`; dependency changes must declare `build.lockfiles`.
8. Update a baseline only deliberately after reviewing the result artifact; never overwrite it automatically.

Do not compare results when the harness reports `incomparable`. Model, corpus, host, backend/device, lockfiles, protocol, and all undeclared configuration fields must match.

Performance baselines are not executed in hosted CI because shared-runner noise makes p95 gates misleading.
