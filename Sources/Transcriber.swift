import Foundation

protocol Transcriber {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
    func warmUp() async throws
}
