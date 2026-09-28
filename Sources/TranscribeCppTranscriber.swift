import Foundation
import os

extension NativeASRTimings {
    /// Maps the C ABI timing struct returned by `asr_transcribe`.
    static func from(_ timings: AsrTimings) -> NativeASRTimings {
        NativeASRTimings(
            totalMs: timings.total_ms,
            waitMs: timings.wait_ms,
            audioMs: timings.audio_ms
        )
    }
}

enum TranscribeCppError: Error {
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case cancelled
    case emptyResult
}

/// Swift owner for a transcribe.cpp GGUF model and reusable native session.
///
/// The Rust bridge serializes calls on the session, so this instance can move
/// between the coordinator's worker tasks without external synchronization.
final class TranscribeCppTranscriber {
    private let handle: OpaquePointer
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "transcribe-cpp")
    private let warmupSampleCount: Int

    init(model: ASRModelConfiguration, warmupSampleCount: Int = 16_000) throws {
        precondition(warmupSampleCount > 0)
        self.warmupSampleCount = warmupSampleCount
        let createResult: AsrCreateResult = try model.url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                throw TranscribeCppError.modelLoadFailed(
                    "Cannot represent model URL as a filesystem path: \(model.url.absoluteString)"
                )
            }
            return asr_create(pointer)
        }
        defer { asr_create_result_free(createResult) }

        if let errorPointer = createResult.error {
            throw TranscribeCppError.modelLoadFailed(String(cString: errorPointer))
        }
        guard let handle = createResult.handle else {
            throw TranscribeCppError.modelLoadFailed("transcribe.cpp returned no handle and no error")
        }

        self.handle = handle
        logger.info("Loaded GGUF ASR model: \(model.kind.displayName, privacy: .public)")
    }

    deinit {
        asr_destroy(handle)
    }

    func transcribe(samples: ContiguousArray<Float>) throws -> String {
        try transcribe(samples: samples, runID: 0)
    }

    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String {
        try transcribeWithTimings(samples: samples, runID: runID).0
    }

    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?) {
        guard !samples.isEmpty else { return ("", nil) }

        return try samples.withUnsafeBufferPointer { buffer in
            let result = asr_transcribe(handle, buffer.baseAddress, buffer.count, runID)
            defer { asr_result_free(result) }

            if result.status == ASR_STATUS_CANCELLED {
                throw TranscribeCppError.cancelled
            }
            if let errorPointer = result.error {
                throw TranscribeCppError.transcriptionFailed(String(cString: errorPointer))
            }
            guard let textPointer = result.text else {
                throw TranscribeCppError.emptyResult
            }
            // Cross-reported timings exist only on the success path.
            let timings = NativeASRTimings.from(result.timings)
            logger.info(
                "native_timings total_ms=\(timings.totalMs, format: .fixed(precision: 1), privacy: .public) wait_ms=\(timings.waitMs, format: .fixed(precision: 1), privacy: .public) audio_ms=\(timings.audioMs, format: .fixed(precision: 1), privacy: .public) rtf=\(timings.realtimeFactor, format: .fixed(precision: 2), privacy: .public)"
            )
            return (String(cString: textPointer), timings)
        }
    }

    func cancel(runID: UInt64) {
        _ = asr_cancel(handle, runID)
    }

    func warmUp(runID: UInt64) throws {
        let silentSamples = ContiguousArray<Float>(repeating: 0, count: warmupSampleCount)
        _ = try transcribe(samples: silentSamples, runID: runID)
        logger.info("transcribe.cpp warmup inference completed")
    }
}

extension TranscribeCppTranscriber: Transcriber {}
extension TranscribeCppTranscriber: @unchecked Sendable {}
