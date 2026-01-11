import Foundation
import os

struct ParakeetResult {
    var text: UnsafeMutablePointer<CChar>?
    var error: UnsafeMutablePointer<CChar>?
}

@_silgen_name("parakeet_create")
private func parakeet_create(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

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

final class ParakeetTranscriber {
    private let handle: UnsafeMutableRawPointer
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "parakeet")

    init(modelPath: URL) throws {
        let handle = modelPath.withUnsafeFileSystemRepresentation { pointer -> UnsafeMutableRawPointer? in
            guard let pointer else {
                return nil
            }
            return parakeet_create(pointer)
        }

        guard let handle else {
            throw ParakeetError.modelLoadFailed("Failed to load Parakeet V3 model")
        }

        self.handle = handle
        logger.debug("Parakeet model loaded")
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
}
