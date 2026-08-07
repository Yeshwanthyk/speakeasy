import Foundation

protocol Transcriber: Sendable {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String
    func cancel(runID: UInt64)
    func warmUp() async throws
}

extension Transcriber {
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String {
        try transcribe(samples: samples)
    }

    func cancel(runID: UInt64) {}
}
