import Foundation

protocol Transcriber: Sendable {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String
    func cancel(runID: UInt64)
    func warmUp() async throws
    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?)
}

extension Transcriber {
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String {
        try transcribe(samples: samples)
    }

    func cancel(runID: UInt64) {}
}

extension Transcriber {
    func transcribeWithTimings(samples: ContiguousArray<Float>, runID: UInt64) throws -> (String, NativeASRTimings?) {
        (try transcribe(samples: samples, runID: runID), nil)
    }
}
