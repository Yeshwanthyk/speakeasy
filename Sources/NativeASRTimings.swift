/// Cross-reported native-side timings for one transcription run.
///
/// `totalMs` is measured inside the Rust bridge; comparing it against the
/// caller's wall clock exposes boundary overhead for free, and
/// `realtimeFactor` shows how far inference is from keeping up with speech.
struct NativeASRTimings: Equatable, Sendable {
    let totalMs: Double
    /// Time spent waiting for the serialized session before inference began.
    let waitMs: Double
    /// Input duration implied by sample count at 16 kHz.
    let audioMs: Double

    /// Inference cost relative to utterance length; below 1.0 means native
    /// transcription finished faster than real time.
    var realtimeFactor: Double {
        guard audioMs > 0 else { return 0 }
        return totalMs / audioMs
    }
}
