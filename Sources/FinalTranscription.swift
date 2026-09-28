import Foundation

/// Offline Parakeet builds full-utterance attention (T x T), so bound the
/// native graph to one minute. This is final-pass only; preview stays short.
enum FinalTranscription {
    static let windowSamples = 16_000 * 60
    static let overlapSamples = 16_000 * 2

    static func run(
        samples: ContiguousArray<Float>,
        transcriber: Transcriber,
        runID: UInt64,
        isCancelled: () -> Bool
    ) throws -> (String, NativeASRTimings?) {
        if samples.count <= windowSamples {
            return try transcriber.transcribeWithTimings(samples: samples, runID: runID)
        }

        var start = 0
        var text = ""
        var totalMs = 0.0
        var waitMs = 0.0
        var hasTimings = true
        while start < samples.count {
            if isCancelled() { throw CancellationError() }
            let end = min(start + windowSamples, samples.count)
            let window = ContiguousArray(samples[start..<end])
            let (part, timings) = try transcriber.transcribeWithTimings(samples: window, runID: runID)
            text = merge(text, part)
            if let timings {
                totalMs += timings.totalMs
                waitMs += timings.waitMs
            } else {
                hasTimings = false
            }
            if end == samples.count { break }
            start = end - overlapSamples
        }
        if isCancelled() { throw CancellationError() }
        let timings = hasTimings ? NativeASRTimings(
            totalMs: totalMs, waitMs: waitMs, audioMs: Double(samples.count) / 16
        ) : nil
        return (text, timings)
    }

    static func merge(_ previous: String, _ next: String) -> String {
        let left = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let right = next.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !left.isEmpty else { return next.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !right.isEmpty else { return previous }
        func normalized(_ word: String) -> String {
            word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        var duplicate = 0
        for count in 1...min(20, left.count, right.count) {
            if zip(left.suffix(count), right.prefix(count)).allSatisfy({ normalized($0) == normalized($1) }) {
                duplicate = count
            }
        }
        return (left + right.dropFirst(duplicate)).joined(separator: " ")
    }
}
