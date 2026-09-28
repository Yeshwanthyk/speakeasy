import Foundation

protocol Transcriber: Sendable {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String
    func cancel(runID: UInt64)
    func warmUp(runID: UInt64) throws
    func warmUp() async throws
    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?)
}

extension Transcriber {
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String {
        try transcribe(samples: samples)
    }

    func cancel(runID: UInt64) {}
}

/// Startup and model-switch warmups use this reserved run ID. Nothing cancels
/// it; idle rewarms take unique IDs from `nextRunID()` so they stay cancellable.
let startupWarmupRunID: UInt64 = 0

private enum WarmupWorker {
    static let queue = DispatchQueue(label: "com.speakeasy.app.model-warmup", qos: .userInitiated)
}

extension Transcriber {
    func warmUp() async throws {
        try await withCheckedThrowingContinuation { continuation in
            WarmupWorker.queue.async {
                do { try self.warmUp(runID: startupWarmupRunID); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?) {
        (try transcribe(samples: samples, runID: runID), nil)
    }
}
