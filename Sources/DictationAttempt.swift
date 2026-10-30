import Foundation

/// How the most recent dictation ended, in terms a person can act on.
enum DictationAttemptResult: Equatable, Sendable {
    case delivered
    case tooShort
    /// The input produced (near) digital silence: wrong device, muted
    /// interface, or a closed laptop lid.
    case silentMicrophone
    case noSpeech
    case interrupted
    case failed
    case accessibilityDenied
    case cancelled

    /// RMS below this is treated as a dead input rather than a quiet room.
    static let silentInputRMS: Float = 0.0001

    static func rejectedSpeech(rms: Float) -> DictationAttemptResult {
        rms.isFinite && rms < silentInputRMS ? .silentMicrophone : .noSpeech
    }
}

struct DictationAttempt: Equatable, Sendable {
    let sequence: UInt64
    let result: DictationAttemptResult
}

/// Practice-step copy for an attempt that did not produce a transcript.
enum PracticeHint {
    static func message(for result: DictationAttemptResult, microphoneName: String?) -> String? {
        switch result {
        case .delivered, .cancelled:
            return nil
        case .tooShort:
            return "That was too short. Speak for at least a second before you stop."
        case .silentMicrophone:
            let device = microphoneName.map { "“\($0)”" } ?? "your microphone"
            return "Speakeasy received silence from \(device). Check the input in Settings → Microphone, or open the lid if you use the built-in mic."
        case .noSpeech:
            return "Speakeasy heard sound but no speech. Try speaking a little louder or closer to the microphone."
        case .interrupted:
            return "The microphone changed while you were speaking. Try again."
        case .failed:
            return "Transcription failed. Try again; if it keeps failing, restart Speakeasy."
        case .accessibilityDenied:
            return "Speakeasy transcribed you but can't paste without Accessibility access."
        }
    }
}
