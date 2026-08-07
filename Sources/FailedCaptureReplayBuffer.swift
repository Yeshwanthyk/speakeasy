import Foundation

/// The only native transcription outcomes that make a PCM capture retryable.
enum FailedCaptureReplayReason: String, Equatable, Sendable {
    case transcriptionFailed
    case timedOut
}

/// A one-shot owner for a failed capture. Acquiring a lease removes the
/// capture from the buffer, so a retry cannot be started twice.
final class FailedCaptureReplayBuffer: @unchecked Sendable {
    /// Matches AudioCapture's six-minute recording bound at 16 kHz.
    static let maxSampleCount = 16_000 * 60 * 6

    struct Lease: @unchecked Sendable {
        let samples: ContiguousArray<Float>
        let reason: FailedCaptureReplayReason
    }

    private struct Entry {
        let samples: ContiguousArray<Float>
        let reason: FailedCaptureReplayReason
    }

    private let lock = UnfairLock()
    private var entry: Entry?

    var hasCapture: Bool {
        lock.withLock { entry != nil }
    }

    /// Replaces any older failure. Oversized input is rejected rather than
    /// truncated so a retry always uses the exact captured samples.
    @discardableResult
    func install(
        samples: ContiguousArray<Float>,
        reason: FailedCaptureReplayReason
    ) -> Bool {
        guard !samples.isEmpty, samples.count <= Self.maxSampleCount else {
            return false
        }

        lock.withLock {
            entry = Entry(samples: samples, reason: reason)
        }
        return true
    }

    /// Atomically claims the current capture for one explicit retry.
    func acquireLease() -> Lease? {
        lock.withLock {
            guard let entry else { return nil }
            self.entry = nil
            return Lease(samples: entry.samples, reason: entry.reason)
        }
    }

    func clear() {
        lock.withLock { entry = nil }
    }
}
