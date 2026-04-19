import AVFoundation
import XCTest
@testable import Wisp

final class AudioCaptureTests: XCTestCase {
    private func makeEngine() throws -> FakeAudioEngine {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        return FakeAudioEngine(input: FakeAudioInputNode(format: format))
    }

    func testPrepareInstallsTapAndStartsEngine() throws {
        let engine = try makeEngine()
        let capture = try AudioCapture(engine: engine)

        try capture.prepare()

        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.input.installTapCount, 1)
        XCTAssertEqual(engine.input.removeTapCount, 0)
    }

    func testPrepareStartFailureSurfacesAndRemovesTap() throws {
        let engine = try makeEngine()
        engine.startError = TestError()
        let capture = try AudioCapture(engine: engine)

        XCTAssertThrowsError(try capture.prepare()) { error in
            guard case AudioCaptureError.engineStartFailed = error else {
                XCTFail("Expected engineStartFailed, got \(error)")
                return
            }
        }
        XCTAssertEqual(engine.input.installTapCount, 1)
        XCTAssertEqual(engine.input.removeTapCount, 1)

        engine.startError = nil
        try capture.prepare()

        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(engine.input.installTapCount, 2)
    }

    func testShutdownStopsEngineAndRemovesTap() throws {
        let engine = try makeEngine()
        let capture = try AudioCapture(engine: engine)

        try capture.prepare()
        capture.shutdown()
        capture.shutdown()

        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.input.removeTapCount, 1)
    }

    func testLimitReachedDuringGraceSignalsStopWait() throws {
        let engine = try makeEngine()
        let awaitingGrace = expectation(description: "awaiting grace")
        let capture = try AudioCapture(maxRecordingSamples: 1, engine: engine) {
            awaitingGrace.fulfill()
        }
        let resultBox = CaptureResultBox()
        let stopped = expectation(description: "stop returned")

        try capture.prepare()
        capture.beginRecording()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.set(capture.endRecording())
            stopped.fulfill()
        }

        wait(for: [awaitingGrace], timeout: 1.0)
        try engine.input.emit(frameLength: 10_000)

        wait(for: [stopped], timeout: 0.2)
        let result = try XCTUnwrap(resultBox.result)
        XCTAssertLessThan(result.graceDurationMs, 80)
        XCTAssertFalse(result.samples.isEmpty)
    }
}

private final class FakeAudioEngine: AudioEngineProtocol {
    let input: FakeAudioInputNode
    var startError: Error?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var captureInputNode: AudioInputNodeProtocol { input }

    init(input: FakeAudioInputNode) {
        self.input = input
    }

    func prepare() {
        prepareCount += 1
    }

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }
}

private final class FakeAudioInputNode: AudioInputNodeProtocol {
    let format: AVAudioFormat
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private var tapBlock: AVAudioNodeTapBlock?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
        format
    }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block tapBlock: @escaping AVAudioNodeTapBlock
    ) {
        installTapCount += 1
        self.tapBlock = tapBlock
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        removeTapCount += 1
        tapBlock = nil
    }

    func emit(frameLength: AVAudioFrameCount) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength))
        buffer.frameLength = frameLength

        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameLength) {
                channel[index] = 0.1
            }
        }

        let time = AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        tapBlock?(buffer, time)
    }
}

private final class CaptureResultBox {
    private let lock = UnfairLock()
    private var storedResult: AudioCaptureResult?

    var result: AudioCaptureResult? {
        lock.withLock { storedResult }
    }

    func set(_ result: AudioCaptureResult) {
        lock.withLock { storedResult = result }
    }
}

private struct TestError: Error {}
