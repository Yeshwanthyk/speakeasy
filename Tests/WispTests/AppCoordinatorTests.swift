import Foundation
import XCTest
@testable import Wisp

final class AppCoordinatorTests: XCTestCase {
    func testToggleRecordingStopsAndPastes() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.1 as Float, count: 160))
        let transcriber = TranscriberStub(result: .success("Hello"))
        let paster = PasterStub()
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: true)

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )

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
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: true)

        let notified = expectation(description: "error")
        feedback.onError = { _ in notified.fulfill() }

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testTimeoutDropsLateResults() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.3 as Float, count: 200))
        let transcriber = TranscriberStub(result: .success("Late"), delay: 0.2)
        let paster = PasterStub()
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: true)

        let timedOut = expectation(description: "timeout")
        feedback.onError = { message in
            if message == "Transcription timed out" {
                timedOut.fulfill()
            }
        }

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 0.05 },
            keyMonitorFactory: { _ in nil }
        )

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
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: true)

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
        XCTAssertTrue(feedback.errors.isEmpty)
    }

    func testEmptyTranscriptionNotifies() {
        let audio = AudioCaptureStub(samples: ContiguousArray(repeating: 0.3 as Float, count: 200))
        let transcriber = TranscriberStub(result: .success("   "))
        let paster = PasterStub()
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: true)

        let notified = expectation(description: "no speech")
        feedback.onError = { message in
            if message == "No speech detected" {
                notified.fulfill()
            }
        }

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }
}

private final class AudioCaptureStub: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let samples: ContiguousArray<Float>

    init(samples: ContiguousArray<Float>) {
        self.samples = samples
    }

    func start() {
        startCount += 1
    }

    func stop() -> ContiguousArray<Float> {
        stopCount += 1
        return samples
    }
}

private final class TranscriberStub: Transcribing {
    private let result: Result<String, Error>
    private let delay: TimeInterval
    private(set) var callCount = 0

    init(result: Result<String, Error>, delay: TimeInterval = 0) {
        self.result = result
        self.delay = delay
    }

    func transcribe(samples: ContiguousArray<Float>) throws -> String {
        callCount += 1
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }

        switch result {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        }
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

    func show(lineWidth: CGFloat) {
        showCount += 1
    }

    func hide(completion: (() -> Void)?) {
        hideCount += 1
        completion?()
    }

    func flash(duration: TimeInterval, lineWidth: CGFloat) {
        flashCount += 1
    }
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

    func ensureAccessibilityPrompted() -> Bool {
        allowed
    }
}

private struct TestError: Error {}
