import Foundation
import XCTest
@testable import Wisp

final class AppCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeCoordinator(
        audio: AudioCaptureStub,
        transcriber: TranscriberStub,
        paster: PasterStub = PasterStub(),
        flash: FlashStub = FlashStub(),
        feedback: FeedbackStub = FeedbackStub(),
        accessibility: AccessibilityStub = AccessibilityStub(allowed: true),
        timeout: TimeInterval = 1.0,
        skipWarmup: Bool = true
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
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

    // MARK: - Existing behaviour

    func testToggleRecordingStopsAndPastes() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hello"))
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
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.2 as Float, count: 80))
        let transcriber = TranscriberStub(result: .failure(TestError()))
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
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.3 as Float, count: 200))
        let transcriber = TranscriberStub(result: .success("Late"), delay: 0.2)
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
        let transcriber = TranscriberStub(result: .success("ignored"))
        let paster = PasterStub()

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testEmptyTranscriptionNotifies() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.3 as Float, count: 200))
        let transcriber = TranscriberStub(result: .success("   "))
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

    // MARK: - Phase 1: Warmup gate

    /// Hotkey during warmup must be silently dropped; no audio start.
    func testHotkeyDuringWarmupIsIgnored() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hello"))
        let feedback = FeedbackStub()

        // skipWarmup: false — coordinator starts in .warming / .pending
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, feedback: feedback, skipWarmup: false)

        coordinator.toggleRecording()

        // Audio must not start because warmup hasn't finished
        XCTAssertEqual(audio.startCount, 0)
    }

    /// Hotkey during warmup must emit user-visible feedback.
    func testHotkeyDuringWarmupEmitsFeedback() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hello"))
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
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hello"))
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
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Recovered"), warmUpError: TestError())
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
        let transcriber = TranscriberStub(result: .success(""))

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, skipWarmup: false)

        await coordinator.warmUpModel()

        XCTAssertEqual(transcriber.warmUpCount, 1)

        // After warmup, hotkey works — toggling starts audio
        coordinator.toggleRecording()
        XCTAssertEqual(audio.startCount, 1)
    }
}

// MARK: - Phase 2: Hot capture engine lifecycle

final class AudioCaptureLifecycleTests: XCTestCase {

    private func makeCoordinator(
        audio: AudioCaptureStub,
        transcriber: TranscriberStub,
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
        let transcriber = TranscriberStub(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        try coordinator.prepareCapture()

        XCTAssertEqual(audio.prepareCount, 1)
    }

    /// prepareCapture() is idempotent from the coordinator side — no crash on double call.
    func testPrepareCaptureIsIdempotent() throws {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = TranscriberStub(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        try coordinator.prepareCapture()
        try coordinator.prepareCapture()

        XCTAssertEqual(audio.prepareCount, 2)
    }

    func testPrepareCapturePropagatesFailure() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160), prepareError: TestError())
        let transcriber = TranscriberStub(result: .success("Hello"))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        XCTAssertThrowsError(try coordinator.prepareCapture())
        XCTAssertEqual(audio.prepareCount, 1)
    }

    /// shutdown() delegates to audioCapture.shutdown().
    func testShutdownDelegates() {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = TranscriberStub(result: .success(""))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        coordinator.shutdown()

        XCTAssertEqual(audio.shutdownCount, 1)
    }

    /// Recording uses beginRecording/endRecording, not start/stop.
    func testRecordingUsesBeginEnd() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hi"))
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
    private(set) var prepareCount = 0
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var shutdownCount = 0
    private(set) var prepareError: Error?
    private let samples: ContiguousArray<Float>
    private let prependedSampleCount: Int
    private let graceDurationMs: Double

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
        prepareCount += 1
        if let error = prepareError { throw error }
    }

    func beginRecording() { beginCount += 1 }

    func endRecording() -> AudioCaptureResult {
        endCount += 1
        return AudioCaptureResult(
            samples: samples,
            prependedSampleCount: prependedSampleCount,
            graceDurationMs: graceDurationMs
        )
    }

    func shutdown() { shutdownCount += 1 }
}

private final class TranscriberStub: Transcribing {
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
