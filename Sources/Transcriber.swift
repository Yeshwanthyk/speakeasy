import Foundation

protocol Transcriber: Sendable {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
    func warmUp() async throws
}
