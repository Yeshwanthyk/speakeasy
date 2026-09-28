@preconcurrency import AVFoundation
import Foundation
import os

/// Desktop end-to-end audio input, enabled only when the app is launched with
/// `SPEAKEASY_E2E_AUDIO=/a.wav:/b.wav`.
///
/// Each successful `beginRecording` arms the next file in order. While a file is
/// armed, every real converted microphone callback is replaced one-for-one by
/// the same number of fixture samples (the clip, then silence), so the hardware
/// tap remains the only producer, sets the real-time pace, and still drives
/// readiness, stop-grace cadence, and recovery. Microphone samples never reach
/// the level meter, ring buffer, or recording while this source exists.
final class E2EAudioFixtureSource: @unchecked Sendable {
    static let environmentKey = "SPEAKEASY_E2E_AUDIO"

    private struct ActiveFixture {
        let index: Int
        let samples: ContiguousArray<Float>
        var cursor = 0
        var silenceCount = 0
    }

    private let paths: [String]
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "e2e-audio")
    private let loadQueue = DispatchQueue(label: "com.speakeasy.app.e2e-audio-load", qos: .userInitiated)
    private let lock = UnfairLock()
    private var loaded: [ContiguousArray<Float>?] = []
    private var nextIndex = 0
    private var active: ActiveFixture?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> E2EAudioFixtureSource? {
        guard let raw = environment[environmentKey] else { return nil }
        let paths = raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }
        return E2EAudioFixtureSource(paths: paths)
    }

    private init(paths: [String]) {
        self.paths = paths
        logger.notice("E2E audio source enabled with \(paths.count) file(s)")
        loadQueue.async { [self] in
            let decoded = paths.map { Self.load(path: $0, logger: logger) }
            lock.withLock { loaded = decoded }
        }
    }

    /// Arms the next fixture. Called once per recording that actually began.
    func arm() {
        loadQueue.sync {}
        let description = lock.withLock { () -> String in
            let index = nextIndex
            nextIndex += 1
            let samples = index < loaded.count ? loaded[index] ?? [] : []
            active = ActiveFixture(index: index, samples: samples)
            return index < paths.count
                ? "E2E fixture \(index) armed: \(samples.count) samples from \(paths[index])"
                : "E2E fixture \(index) armed past the configured list; recording silence"
        }
        logger.notice("\(description, privacy: .public)")
    }

    /// Ends the armed fixture. Called after the recording snapshot is taken.
    func disarm() {
        guard let finished = lock.withLock({ () -> ActiveFixture? in
            defer { active = nil }
            return active
        }) else { return }
        logger.notice(
            "E2E fixture \(finished.index) disarmed: consumed \(finished.cursor)/\(finished.samples.count) clip samples, \(finished.silenceCount) silence samples"
        )
    }

    /// Replaces one converted microphone callback. `body` receives the fixture
    /// samples when a fixture is armed and `nil` otherwise.
    func substitute(count: Int, _ body: (UnsafeBufferPointer<Float>?) -> Void) {
        let replacement = lock.withLock { () -> ContiguousArray<Float>? in
            guard var fixture = active else { return nil }
            var output = ContiguousArray<Float>(repeating: 0, count: count)
            let available = min(count, fixture.samples.count - fixture.cursor)
            if available > 0 {
                output.withUnsafeMutableBufferPointer { destination in
                    fixture.samples.withUnsafeBufferPointer { source in
                        for offset in 0..<available {
                            destination[offset] = source[fixture.cursor + offset]
                        }
                    }
                }
                fixture.cursor += available
            }
            fixture.silenceCount += count - max(0, available)
            active = fixture
            return output
        }
        guard let replacement else {
            body(nil)
            return
        }
        replacement.withUnsafeBufferPointer { body($0) }
    }

    private static func load(path: String, logger: Logger) -> ContiguousArray<Float>? {
        do {
            let file = try AVAudioFile(
                forReading: URL(fileURLWithPath: path),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let format = file.processingFormat
            guard format.sampleRate == 16_000, format.channelCount == 1 else {
                logger.error("E2E fixture must be 16 kHz mono: \(path, privacy: .public) is \(format.sampleRate) Hz × \(format.channelCount)")
                return nil
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                return nil
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            return ContiguousArray(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        } catch {
            logger.error("E2E fixture unreadable: \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
