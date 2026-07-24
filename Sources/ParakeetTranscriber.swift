import Foundation
import os

struct ParakeetResult {
    var text: UnsafeMutablePointer<CChar>?
    var error: UnsafeMutablePointer<CChar>?
}

struct ParakeetCreateResult {
    var handle: UnsafeMutableRawPointer?
    var error: UnsafeMutablePointer<CChar>?
}

@_silgen_name("parakeet_create")
private func parakeet_create(
    _ path: UnsafePointer<CChar>,
    _ modelKind: Int32,
    _ language: UnsafePointer<CChar>?
) -> ParakeetCreateResult

@_silgen_name("parakeet_create_result_free")
private func parakeet_create_result_free(_ result: ParakeetCreateResult)

@_silgen_name("parakeet_destroy")
private func parakeet_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("parakeet_transcribe")
private func parakeet_transcribe(
    _ handle: UnsafeMutableRawPointer?,
    _ samples: UnsafePointer<Float>?,
    _ length: Int
) -> ParakeetResult

@_silgen_name("parakeet_result_free")
private func parakeet_result_free(_ result: ParakeetResult)

enum ParakeetError: Error {
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case emptyResult
}

/// Swift-side wrapper around the Rust Parakeet FFI.
///
/// Thread-safe: the underlying Rust handle serialises concurrent calls to
/// `transcribe` with an internal mutex. This type is therefore safe to share
/// across tasks or dispatch queues without external synchronisation.
final class ParakeetTranscriber {
    private let handle: UnsafeMutableRawPointer
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "parakeet")

    init(model: ASRModelConfiguration) throws {
        // Pre-flight: URL must be representable as a filesystem path before
        // we cross the FFI boundary.
        let createResult: ParakeetCreateResult = try model.url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                throw ParakeetError.modelLoadFailed(
                    "Cannot represent model URL as a filesystem path: \(model.url.absoluteString)"
                )
            }

            if let language = model.language {
                return language.withCString {
                    parakeet_create(pointer, model.kind.ffiValue, $0)
                }
            }

            return parakeet_create(pointer, model.kind.ffiValue, nil)
        }

        // Always free the error string on this code path. Safe if error is null.
        defer { parakeet_create_result_free(createResult) }

        if let errorPointer = createResult.error {
            throw ParakeetError.modelLoadFailed(String(cString: errorPointer))
        }
        guard let handle = createResult.handle else {
            throw ParakeetError.modelLoadFailed("Parakeet returned no handle and no error")
        }

        self.handle = handle
        logger.debug("ASR model loaded")
    }

    deinit {
        parakeet_destroy(handle)
    }

    func transcribe(samples: ContiguousArray<Float>) throws -> String {
        guard !samples.isEmpty else {
            return ""
        }

        return try samples.withUnsafeBufferPointer { buffer in
            let result = parakeet_transcribe(handle, buffer.baseAddress, buffer.count)
            defer {
                parakeet_result_free(result)
            }

            if let errorPointer = result.error {
                throw ParakeetError.transcriptionFailed(String(cString: errorPointer))
            }

            guard let textPointer = result.text else {
                throw ParakeetError.emptyResult
            }

            return String(cString: textPointer)
        }
    }

    /// Warm up the model by running a short silent transcription.
    /// This pre-compiles any lazy-loaded CoreML/Metal shaders.
    func warmUp() async throws {
        let silentSamples = ContiguousArray<Float>(repeating: 0, count: 16_000)
        _ = try transcribe(samples: silentSamples)
        logger.info("Model warmup inference completed")
    }
}

extension ParakeetTranscriber: Transcriber {}
extension ParakeetTranscriber: @unchecked Sendable {}

private extension ASRModelKind {
    var ffiValue: Int32 {
        switch self {
        case .parakeetTDT:
            return 0
        case .nemotron:
            return 1
        }
    }
}
