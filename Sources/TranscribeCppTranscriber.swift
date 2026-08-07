import Foundation
import os

private struct AsrResult {
    var text: UnsafeMutablePointer<CChar>?
    var error: UnsafeMutablePointer<CChar>?
    var status: Int32
}

private struct AsrCreateResult {
    var handle: UnsafeMutableRawPointer?
    var error: UnsafeMutablePointer<CChar>?
}

@_silgen_name("asr_create")
private func asr_create(_ path: UnsafePointer<CChar>) -> AsrCreateResult

@_silgen_name("asr_create_result_free")
private func asr_create_result_free(_ result: AsrCreateResult)

@_silgen_name("asr_destroy")
private func asr_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("asr_transcribe")
private func asr_transcribe(
    _ handle: UnsafeMutableRawPointer?,
    _ samples: UnsafePointer<Float>?,
    _ length: Int,
    _ runID: UInt64
) -> AsrResult

@_silgen_name("asr_result_free")
private func asr_result_free(_ result: AsrResult)

@_silgen_name("asr_cancel")
private func asr_cancel(_ handle: UnsafeMutableRawPointer?, _ runID: UInt64) -> Bool

private let asrStatusCancelled: Int32 = 2

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
    private let handle: UnsafeMutableRawPointer
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "transcribe-cpp")

    init(model: ASRModelConfiguration) throws {
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
        guard !samples.isEmpty else {
            return ""
        }

        return try samples.withUnsafeBufferPointer { buffer in
            let result = asr_transcribe(handle, buffer.baseAddress, buffer.count, runID)
            defer { asr_result_free(result) }

            if result.status == asrStatusCancelled {
                throw TranscribeCppError.cancelled
            }
            if let errorPointer = result.error {
                throw TranscribeCppError.transcriptionFailed(String(cString: errorPointer))
            }
            guard let textPointer = result.text else {
                throw TranscribeCppError.emptyResult
            }
            return String(cString: textPointer)
        }
    }

    func cancel(runID: UInt64) {
        _ = asr_cancel(handle, runID)
    }

    func warmUp() async throws {
        let silentSamples = ContiguousArray<Float>(repeating: 0, count: 16_000)
        _ = try transcribe(samples: silentSamples)
        logger.info("transcribe.cpp warmup inference completed")
    }
}

extension TranscribeCppTranscriber: Transcriber {}
extension TranscribeCppTranscriber: @unchecked Sendable {}
