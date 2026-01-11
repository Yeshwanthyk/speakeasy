# Plan

- [x] Add test scaffold (Package.swift, Tests/) and minimal interfaces for testability.
- [x] Implement fixes (event tap teardown, transcription timeout + feedback, audio buffer cap, regex precompile).
- [x] Add tests covering AppCoordinator flows, WordCorrector rules, audio buffer cap.
- [ ] Run tests, document gaps, commit.

## Gaps
- No automated coverage for CGEvent tap lifecycle, paste posting success, or Accessibility prompt behavior (requires system APIs/UI).
- No integration tests for Parakeet FFI (SwiftPM build excludes `ParakeetTranscriber.swift` and the Rust dylib).
- Audio engine conversion and AVAudioEngine tap behavior remain untested (hardware + real-time constraints).
