import Foundation
import XCTest
@testable import Wisp

@MainActor
final class AppCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Enough loud samples to pass both minActiveSamples and RMS threshold.
    static let validSamples = ContiguousArray<Float>(repeating: 0.1, count: 8_000)
    /// Enough samples but too quiet (silence).
    static let silentSamples = ContiguousArray<Float>(repeating: 0.0001, count: 8_000)
    /// Too few active samples.
    static let shortSamples = ContiguousArray<Float>(repeating: 0.1, count: 100)

    private func makeCoordinator(
        audio: AudioCaptureStub,
        transcriber: FakeTranscriber,
        paster: PasterStub = PasterStub(),
        flash: FlashStub? = nil,
        feedback: FeedbackStub = FeedbackStub(),
        accessibility: AccessibilityStub = AccessibilityStub(allowed: true),
        timeout: TimeInterval = 1.0,
        skipWarmup: Bool = true
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash ?? FlashStub(),
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in timeout },
            keyMonitorFactory: { _ in nil }
        )
        if skipWarmup {
            coordinator.skipWarmup()
        }
        return coordinator
    }

    private func waitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: - Existing behaviour

    func testToggleRecordingStopsAndPastes() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let paster = PasterStub()
        let flash = FlashStub()
        let feedback = FeedbackStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, flash: flash, feedback: feedback)

        coordinator.toggleRecording()
        XCTAssertEqual(audio.startCount, 1)

        coordinator.toggleRecording()
        wait(for: [pasted], timeout: 1.0)

        XCTAssertEqual(paster.pastedTexts, ["Hello"])
        XCTAssertEqual(flash.showCount, 1)
        XCTAssertEqual(flash.hideCount, 1)
        XCTAssertTrue(feedback.errors.isEmpty)
    }

    func testTranscriptionFailureNotifiesUser() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .failure(TestError()))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let notified = expectation(description: "error")
        feedback.onError = { _ in notified.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testTimeoutDropsLateResults() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Late"), delay: 0.2)
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let timedOut = expectation(description: "timeout")
        feedback.onError = { message in
            if message == "Transcription timed out" { timedOut.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback, timeout: 0.05)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [timedOut], timeout: 1.0)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testEmptySamplesDoNotTriggerTranscription() {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let paster = PasterStub()

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertTrue(waitUntil { audio.endCount == 1 })
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testEmptyTranscriptionNotifies() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("   "))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let notified = expectation(description: "no speech")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    // MARK: - Audio validation guards

    func testShortRecordingIsRejected() {
        let audio = AudioCaptureStub(samples: Self.shortSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let rejected = expectation(description: "short rejected")
        feedback.onError = { message in
            if message == "Recording too short" { rejected.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [rejected], timeout: 1.0)

        XCTAssertEqual(transcriber.callCount, 0, "Short recordings should not reach the transcriber")
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testSilentAudioIsRejected() {
        let audio = AudioCaptureStub(samples: Self.silentSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let rejected = expectation(description: "silent rejected")
        feedback.onError = { message in
            if message == "No speech detected" { rejected.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [rejected], timeout: 1.0)

        XCTAssertEqual(transcriber.callCount, 0, "Silent audio should not reach the transcriber")
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testEndRecordingRunsOffMainThread() {
        let audio = AudioCaptureStub(samples: Self.shortSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertTrue(waitUntil { audio.endCount == 1 })
        XCTAssertEqual(audio.lastEndRecordingWasMainThread, false)
    }

    func testHallucinationIsFiltered() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Yeah."))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let notified = expectation(description: "no speech")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, feedback: feedback)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty, "Hallucinated 'Yeah.' should not be pasted")
    }

    func testRealTranscriptionPassesHallucinationFilter() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Yeah, that sounds good."))
        let paster = PasterStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(paster.pastedTexts, ["Yeah, that sounds good."])
    }

    // MARK: - Phase 1: Warmup gate

    /// Hotkey during warmup must be silently dropped; no audio start.
    func testHotkeyDuringWarmupIsIgnored() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let feedback = FeedbackStub()

        // skipWarmup: false — coordinator starts in .warming / .pending
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, feedback: feedback, skipWarmup: false)

        coordinator.toggleRecording()

        // Audio must not start because warmup hasn't finished
        XCTAssertEqual(audio.startCount, 0)
    }

    /// Hotkey during warmup must emit user-visible feedback.
    func testHotkeyDuringWarmupEmitsFeedback() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let feedback = FeedbackStub()

        let feedbackReceived = expectation(description: "warming feedback")
        feedback.onError = { message in
            if message == "Model warming up, please wait" { feedbackReceived.fulfill() }
        }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, feedback: feedback, skipWarmup: false)

        // Simulate hotkey while warming (state is .pending → treated as not ready)
        coordinator.toggleRecording()

        wait(for: [feedbackReceived], timeout: 1.0)
    }

    /// After warmup success, hotkey should start recording normally.
    func testHotkeyAfterWarmupSuccessStartsRecording() async {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let paster = PasterStub()

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, skipWarmup: false)

        await coordinator.warmUpModel()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        await fulfillment(of: [pasted], timeout: 1.0)

        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(paster.pastedTexts, ["Hello"])
    }

    /// After warmup failure, hotkey should still work (degrade gracefully).
    func testHotkeyAfterWarmupFailureStillTranscribes() async {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Recovered"), warmUpError: TestError())
        let paster = PasterStub()

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster, skipWarmup: false)

        await coordinator.warmUpModel()

        let pasted = expectation(description: "paste after failed warmup")
        paster.onPaste = { pasted.fulfill() }

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        await fulfillment(of: [pasted], timeout: 1.0)

        XCTAssertEqual(paster.pastedTexts, ["Recovered"])
    }

    /// warmUpModel() transitions to .ready — subsequent warmUp calls don't re-run (tested via callCount).
    func testWarmupSuccessTransitionsToReady() async {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success(""))

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, skipWarmup: false)

        await coordinator.warmUpModel()

        XCTAssertEqual(transcriber.warmUpCount, 1)

        // After warmup, hotkey works — toggling starts audio
        coordinator.toggleRecording()
        XCTAssertEqual(audio.startCount, 1)
    }
}

// MARK: - Phase 2: Hot capture engine lifecycle

@MainActor
final class AudioCaptureLifecycleTests: XCTestCase {

    private func makeCoordinator(
        audio: AudioCaptureStub,
        transcriber: FakeTranscriber,
        paster: PasterStub = PasterStub(),
        skipWarmup: Bool = true
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: FlashStub(),
            feedback: FeedbackStub(),
            accessibilityChecker: AccessibilityStub(allowed: true),
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )
        if skipWarmup { coordinator.skipWarmup() }
        return coordinator
    }

    /// prepareCapture() delegates to audioCapture.prepare() exactly once.
    func testPrepareCaptureCallsPrepare() throws {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        try coordinator.prepareCapture()

        XCTAssertEqual(audio.prepareCount, 1)
    }

    /// prepareCapture() is idempotent from the coordinator side — no crash on double call.
    func testPrepareCaptureIsIdempotent() throws {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        try coordinator.prepareCapture()
        try coordinator.prepareCapture()

        XCTAssertEqual(audio.prepareCount, 2)
    }

    func testPrepareCapturePropagatesFailure() {
        let audio = AudioCaptureStub(samples: AppCoordinatorTests.validSamples, prepareError: TestError())
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        XCTAssertThrowsError(try coordinator.prepareCapture())
        XCTAssertEqual(audio.prepareCount, 1)
    }

    /// shutdown() delegates to audioCapture.shutdown().
    func testShutdownDelegates() {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        coordinator.shutdown()

        XCTAssertEqual(audio.shutdownCount, 1)
    }

    /// Recording uses beginRecording/endRecording, not start/stop.
    func testRecordingUsesBeginEnd() {
        let audio = AudioCaptureStub(samples: AppCoordinatorTests.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hi"))
        let paster = PasterStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)
        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)

        XCTAssertEqual(audio.beginCount, 1)
        XCTAssertEqual(audio.endCount, 1)
    }
}

// MARK: - Shared Stubs

private final class AudioCaptureStub: AudioCapturing {
    // Counters are written from `transcriptionQueue` (for `endRecording`) and
    // read from the test thread. Protect each with a lock so TSAN is happy
    // and ordering is formal rather than coincidental.
    private let counterLock = UnfairLock()
    private var _prepareCount = 0
    private var _beginCount = 0
    private var _endCount = 0
    private var _shutdownCount = 0
    private var _lastEndRecordingWasMainThread: Bool?
    private let prepareError: Error?
    private let samples: ContiguousArray<Float>
    private let prependedSampleCount: Int
    private let graceDurationMs: Double

    var prepareCount: Int { counterLock.withLock { _prepareCount } }
    var beginCount: Int { counterLock.withLock { _beginCount } }
    var endCount: Int { counterLock.withLock { _endCount } }
    var shutdownCount: Int { counterLock.withLock { _shutdownCount } }
    var lastEndRecordingWasMainThread: Bool? { counterLock.withLock { _lastEndRecordingWasMainThread } }

    /// Convenience aliases used by older tests.
    var startCount: Int { beginCount }
    var stopCount: Int { endCount }

    init(
        samples: ContiguousArray<Float>,
        prepareError: Error? = nil,
        prependedSampleCount: Int = 0,
        graceDurationMs: Double = 0
    ) {
        self.samples = samples
        self.prepareError = prepareError
        self.prependedSampleCount = prependedSampleCount
        self.graceDurationMs = graceDurationMs
    }

    func prepare() throws {
        counterLock.withLock { _prepareCount += 1 }
        if let error = prepareError { throw error }
    }

    func beginRecording() {
        counterLock.withLock { _beginCount += 1 }
    }

    func endRecording() -> AudioCaptureResult {
        counterLock.withLock {
            _endCount += 1
            _lastEndRecordingWasMainThread = Thread.isMainThread
        }
        return AudioCaptureResult(
            samples: samples,
            prependedSampleCount: prependedSampleCount,
            graceDurationMs: graceDurationMs
        )
    }

    func shutdown() {
        counterLock.withLock { _shutdownCount += 1 }
    }
}

private final class FakeTranscriber: Transcriber {
    private let result: Result<String, Error>
    private let delay: TimeInterval
    private let warmUpError: Error?
    private(set) var callCount = 0
    private(set) var warmUpCount = 0

    init(result: Result<String, Error>, delay: TimeInterval = 0, warmUpError: Error? = nil) {
        self.result = result
        self.delay = delay
        self.warmUpError = warmUpError
    }

    func transcribe(samples: ContiguousArray<Float>) throws -> String {
        callCount += 1
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func warmUp() async throws {
        warmUpCount += 1
        if let error = warmUpError { throw error }
    }
}

private final class PasterStub: Pasting {
    private(set) var pastedTexts: [String] = []
    var onPaste: (() -> Void)?

    func paste(_ text: String) {
        pastedTexts.append(text)
        onPaste?()
    }
}

private final class FlashStub: Flashing {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var flashCount = 0

    func show(lineWidth: CGFloat) { showCount += 1 }
    func hide(completion: (() -> Void)?) { hideCount += 1; completion?() }
    func flash(duration: TimeInterval, lineWidth: CGFloat) { flashCount += 1 }
}

private final class FeedbackStub: UserFeedback {
    private(set) var errors: [String] = []
    var onError: ((String) -> Void)?

    func error(_ message: String) {
        errors.append(message)
        onError?(message)
    }
}

private struct AccessibilityStub: AccessibilityChecking {
    let allowed: Bool
    func ensureAccessibilityPrompted() -> Bool { allowed }
}

private struct TestError: Error {}
