# Ship cleanup plan: domain-by-domain

Goal: a public macOS release of Speakeasy. Work one domain at a time. Each domain ends with clean code, tests for every state and transition, property tests for pure logic, fuzz targets for every parser of untrusted input, and a commit.

Start state (2026-09-28, branch `feat/long-dictation-redux-ui`):
- Settings redesign and first-run onboarding are committed and pushed (`6ed08a7`, `1c7c193`).
- Legacy/migration code (`com.wisp.app`, `WISP_ASR_MODEL`, removed model aliases, old history format, old stats keys) has been removed.
- There are no existing installs to migrate. Fresh install is the only supported path.
- 14.4k lines of Swift in `Sources/`, 34 test files, and one Rust crate in `rust/asr_bridge`.

## Per-domain loop

1. **Read:** list the domain's types, their states, and who owns each piece of state. Note dead code, duplication, and unclear ownership.
2. **Clean:** make the smallest structural fixes. Keep behavior the same unless it is a bug, and record each bug fixed.
3. **Test states:** write down the domain's state machine and test every transition, including failures, cancellation, and re-entry.
4. **Property tests:** for pure logic, state invariants and cover many generated inputs.
5. **Fuzz:** for anything that parses files, user text, or FFI data, add a bounded fuzz target and a replay corpus.
6. **Verify:** run `swift test`, `cargo test` if Rust was touched, `./build.sh`, and a manual check in the app where there is UI.
7. **Commit:** one commit per domain.

## Tooling decisions to make first

- **Property testing:** there are no package dependencies today. Options:
  - add SwiftCheck;
  - write a small in-repo seeded generator with shrinking;
  - use swift-testing parameterized tests with generated cases.
- **Fuzzing:** Swift supports `-sanitize=fuzzer` on the open-source toolchain, and the Rust bridge can use `cargo-fuzz`. Decide where fuzz targets live (for example a `Fuzz/` directory with a script) and the time budget per run.
- **Test pollution:** UserDefaults suites now go through `Tests/SpeakeasyTests/TestDefaults.swift` (temp-path suites, no leftovers). Temp files and directories are still left in `$TMPDIR` (about 1,100 entries). Fix this during the persistence domain.

## Domains (suggested order: core logic first, UI last)

| # | Domain | Files | Focus |
|---|---|---|---|
| 1 | Text pipeline | `TranscriptPostProcessor`, `PhoneticCorrector`, `HallucinationFilter`, `TranscriptCorrectionStore`, `CorrectionEditor` (model) | Property: idempotence, no-op with no rules, bounded output. Fuzz the corrections JSON and the rule matcher. |
| 2 | Persistence | `TranscriptStore`, `DiagnosticsStore`, `E2ETraceStore`, `OrderedSnapshotWriter`, `SettingsInsights` | Fuzz every on-disk file (history, stats, corrections). Test round-trips, capacity bounds and write ordering. |
| 3 | Audio capture | `AudioCapture`, `MicrophoneDevice`, `FloatRingBuffer`, `SpeechGate`, `FailedCaptureReplayBuffer`, `CaptureStopTiming` | Capture state machine, device change and loss, ring buffer properties, gate thresholds. |
| 4 | ASR and models | `ModelPathResolver`, `ASRModelInstaller`, `Transcriber`, `TranscribeCppTranscriber`, `FinalTranscription`, `OnlineSegmentCommit`, `LivePreview`, `rust/asr_bridge` | Install states (download, verify, cancel, retry, corrupt file), segment commit properties, FFI fuzzing. |
| 5 | Dictation orchestration | `AppCoordinator` (1960 lines), `DictationIntent`, `TranscriptionTrace` | Split by responsibility. Full dictation state machine: warmup, capture, transcribe, deliver, failure, wake/unlock. |
| 6 | Input and delivery | `KeyComboMonitor`, `DictationShortcut`, `ShortcutRecorder`, `TranscriptDelivery`, `PasteboardPaster` | Shortcut decoding and fuzzing, hotkey state machine, paste target selection, clipboard restore. |
| 7 | App shell and permissions | `AppDelegate`, `Onboarding*`, `Permissions`, `AppInstanceSelector` | Onboarding gating states. Confirm whether Input Monitoring is really required. Startup failure paths. |
| 8 | UI | `MenuBarController`, `Settings*`, `BottomOverlay`, `OverlayModel`, `RecordingIndicator`, `SpeakeasyBrand` | View-model tests, accessibility labels, light and dark checks. |
| 9 | Release | `build.sh`, `script/`, `Info.plist`, `README`, `THIRD_PARTY_NOTICES` | Developer ID signing, notarization, hardened runtime, update mechanism, crash/log privacy, model license notices (CC-BY-4.0). |

Also triage the old planning docs (`plan.md`, `NEXT.md`, `MISSION.md`, `plans/`) and delete or archive what is stale.
