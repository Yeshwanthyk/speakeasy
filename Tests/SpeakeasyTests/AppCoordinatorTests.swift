import Foundation
import XCTest
@testable import Speakeasy

@MainActor
final class AppCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    /// Enough loud samples to pass both minActiveSamples and RMS threshold.
    static let validSamples = ContiguousArray<Float>(repeating: 0.1, count: 8_000)
    /// Representative quiet speech observed from the built-in microphone.
    static let quietSpeechSamples = ContiguousArray<Float>(repeating: 0.004, count: 8_000)
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
        skipWarmup: Bool = true,
        transcriptStore: TranscriptStore? = nil,
        diagnosticsStore: DiagnosticsStore? = nil,
        hallucinationFilter: HallucinationFilter = HallucinationFilter(),
        transcriptPostProcessor: TranscriptPostProcessor = TranscriptPostProcessor(),
        transcriptionQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.tests.transcription"),
        deliveryTargetProvider: DeliveryTargetProviding = TestCoordinatorTargetProvider()
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: flash ?? FlashStub(),
            feedback: feedback,
            accessibilityChecker: accessibility,
            hallucinationFilter: hallucinationFilter,
            transcriptionTimeoutProvider: { _ in timeout },
            keyMonitorFactory: { _ in nil },
            transcriptStore: transcriptStore,
            diagnosticsStore: diagnosticsStore,
            transcriptPostProcessor: transcriptPostProcessor,
            transcriptionQueue: transcriptionQueue,
            deliveryTargetProvider: deliveryTargetProvider
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

    private func decodedHistory(at url: URL) -> [TranscriptRecord]? {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(TranscriptHistoryDocument.self, from: data)
        else {
            return nil
        }
        return decoded.records
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

    func testTimeoutDropsLateResultsAndBlocksNewCaptureUntilWorkerReturns() {
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

        coordinator.toggleRecording()
        coordinator.toggleRecording()
        XCTAssertEqual(audio.beginCount, 1)
        XCTAssertEqual(audio.endCount, 1)

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(paster.pastedTexts.isEmpty)

        coordinator.toggleRecording()
        XCTAssertEqual(audio.beginCount, 2)
    }

    func testTimeoutAndLateResultProduceOneDiagnosticTerminalOutcome() {
        let diagnostics = DiagnosticsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-timeout-stats-\(UUID().uuidString)")
                .appendingPathComponent("stats.json")
        )
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("late private text"), delay: 0.15)
        let feedback = FeedbackStub()
        let timedOut = expectation(description: "timeout")
        feedback.onError = { message in
            if message == "Transcription timed out" { timedOut.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            feedback: feedback,
            timeout: 0.02,
            diagnosticsStore: diagnostics
        )
        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [timedOut], timeout: 1.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.lifetime.attemptCount, 1)
        XCTAssertEqual(snapshot.lifetime.outcomes.timedOut, 1)
        XCTAssertEqual(snapshot.lifetime.outcomes.eventsPosted, 0)
        XCTAssertFalse(diagnostics.report().contains("late private text"))
    }

    func testEmptySamplesDoNotTriggerTranscription() {
        let audio = AudioCaptureStub(samples: ContiguousArray<Float>())
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let paster = PasterStub()

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertTrue(waitUntil { audio.endCount == 1 })
        let restartDeadline = Date().addingTimeInterval(1.0)
        var restarted = false
        while !restarted, Date() < restartDeadline {
            coordinator.toggleRecording()
            restarted = audio.beginCount == 2
            if !restarted {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        XCTAssertTrue(restarted)

        coordinator.toggleRecording()
        XCTAssertTrue(waitUntil { audio.endCount == 2 })
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

    func testQuietSpeechReachesTranscriber() {
        let audio = AudioCaptureStub(samples: Self.quietSpeechSamples)
        let transcriber = FakeTranscriber(result: .success("Quiet but valid"))
        let paster = PasterStub()
        let pasted = expectation(description: "quiet speech pasted")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(paster.pastedTexts, ["Quiet but valid"])
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

    func testIsRecordingExposesRecordingState() {
        let audio = AudioCaptureStub(samples: Self.shortSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber)

        XCTAssertFalse(coordinator.isRecording)

        coordinator.toggleRecording()
        XCTAssertTrue(coordinator.isRecording)

        coordinator.toggleRecording()
        XCTAssertFalse(coordinator.isRecording)
    }

    func testSwitchASRModelLoadsSelectedTranscriberAndPersistsSelection() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let initialTranscriber = FakeTranscriber(result: .success("Parakeet text"))
        let replacementTranscriber = FakeTranscriber(result: .success("Nemotron text"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let switchLock = UnfairLock()
        let queue = DispatchQueue(label: "com.speakeasy.app.tests.model-switch")
        let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var resolvedKinds: [ASRModelKind] = []
        var factoryKinds: [ASRModelKind] = []
        var persistedKinds: [ASRModelKind] = []

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: initialTranscriber,
            paster: paster,
            flash: FlashStub(),
            feedback: feedback,
            accessibilityChecker: AccessibilityStub(allowed: true),
            asrModelKind: .parakeetTDT,
            asrModelResolver: { kind in
                switchLock.withLock { resolvedKinds.append(kind) }
                return ASRModelConfiguration(kind: kind, url: modelURL, language: nil)
            },
            transcriberFactory: { model in
                switchLock.withLock { factoryKinds.append(model.kind) }
                return replacementTranscriber
            },
            modelArtifactVerifier: { _ in },
            modelSelectionStore: { kind in
                switchLock.withLock { persistedKinds.append(kind) }
            },
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil },
            transcriptionQueue: queue
        )
        coordinator.skipWarmup()

        coordinator.switchASRModel(to: .nemotron)

        XCTAssertTrue(waitUntil {
            coordinator.selectedASRModelKind() == .nemotron && replacementTranscriber.warmUpCount == 1
        })
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        let pasted = expectation(description: "paste from switched model")
        paster.onPaste = { pasted.fulfill() }

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(paster.pastedTexts, ["Nemotron text"])
        XCTAssertEqual(initialTranscriber.callCount, 0)
        XCTAssertTrue(feedback.errors.isEmpty)
        XCTAssertEqual(switchLock.withLock { resolvedKinds }, [.nemotron])
        XCTAssertEqual(switchLock.withLock { factoryKinds }, [.nemotron])
        XCTAssertEqual(switchLock.withLock { persistedKinds }, [.nemotron])
    }

    func testSwitchASRModelRejectsCorruptArtifactBeforeLoadingAndPreservesPreviousModel() {
        let initialTranscriber = FakeTranscriber(result: .success("Previous text"))
        let candidateTranscriber = FakeTranscriber(result: .success("Candidate text"))
        let feedback = FeedbackStub()
        var factoryCallCount = 0
        var persistedKinds: [ASRModelKind] = []

        let coordinator = AppCoordinator(
            audioCapture: AudioCaptureStub(samples: Self.validSamples),
            transcriber: initialTranscriber,
            paster: PasterStub(),
            flash: FlashStub(),
            feedback: feedback,
            accessibilityChecker: AccessibilityStub(allowed: true),
            asrModelKind: .parakeetTDT,
            asrModelResolver: { kind in
                ASRModelConfiguration(
                    kind: kind,
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("corrupt.gguf")
                )
            },
            transcriberFactory: { _ in
                factoryCallCount += 1
                return candidateTranscriber
            },
            modelArtifactVerifier: { _ in
                throw ModelArtifactVerificationError.checksumMismatch(
                    expected: "expected",
                    actual: "corrupt"
                )
            },
            modelSelectionStore: { persistedKinds.append($0) },
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )
        coordinator.skipWarmup()

        coordinator.switchASRModel(to: .nemotron)

        XCTAssertTrue(waitUntil { feedback.errors == ["Failed to switch audio model"] })
        XCTAssertEqual(coordinator.selectedASRModelKind(), .parakeetTDT)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertEqual(candidateTranscriber.warmUpCount, 0)
        XCTAssertTrue(persistedKinds.isEmpty)
    }

    func testSwitchASRModelWarmupFailurePreservesPreviousBackendAndSelection() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let initialTranscriber = FakeTranscriber(result: .success("Previous text"))
        let candidateTranscriber = FakeTranscriber(
            result: .success("Candidate text"),
            warmUpError: TestError()
        )
        let paster = PasterStub()
        let feedback = FeedbackStub()
        var persistedKinds: [ASRModelKind] = []

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: initialTranscriber,
            paster: paster,
            flash: FlashStub(),
            feedback: feedback,
            accessibilityChecker: AccessibilityStub(allowed: true),
            asrModelKind: .parakeetTDT,
            asrModelResolver: { kind in
                ASRModelConfiguration(
                    kind: kind,
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("candidate.gguf")
                )
            },
            transcriberFactory: { _ in candidateTranscriber },
            modelArtifactVerifier: { _ in },
            modelSelectionStore: { persistedKinds.append($0) },
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )
        coordinator.skipWarmup()

        coordinator.switchASRModel(to: .nemotron)

        XCTAssertTrue(waitUntil {
            candidateTranscriber.warmUpCount == 1
                && feedback.errors == ["Failed to switch audio model"]
        })
        XCTAssertEqual(coordinator.selectedASRModelKind(), .parakeetTDT)
        XCTAssertTrue(persistedKinds.isEmpty)

        let pasted = expectation(description: "previous backend remains active")
        paster.onPaste = { pasted.fulfill() }
        coordinator.toggleRecording()
        coordinator.toggleRecording()
        wait(for: [pasted], timeout: 1.0)

        XCTAssertEqual(paster.pastedTexts, ["Previous text"])
        XCTAssertEqual(initialTranscriber.callCount, 1)
        XCTAssertEqual(candidateTranscriber.callCount, 0)
    }

    func testSwitchASRModelIsRejectedWhileRecording() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let feedback = FeedbackStub()
        var factoryCallCount = 0

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: PasterStub(),
            flash: FlashStub(),
            feedback: feedback,
            accessibilityChecker: AccessibilityStub(allowed: true),
            asrModelKind: .parakeetTDT,
            asrModelResolver: { kind in
                ASRModelConfiguration(kind: kind, url: FileManager.default.temporaryDirectory, language: nil)
            },
            transcriberFactory: { _ in
                factoryCallCount += 1
                return transcriber
            },
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil }
        )
        coordinator.skipWarmup()

        coordinator.toggleRecording()
        coordinator.switchASRModel(to: .nemotron)

        XCTAssertEqual(coordinator.selectedASRModelKind(), .parakeetTDT)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertEqual(feedback.errors, ["Stop recording before switching models"])
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

    func testCorrectionsDoNotRescueHallucinatedTranscription() throws {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Yeah."))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let postProcessor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "yeah", written: "accepted text")
        ])
        let notified = expectation(description: "no speech")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback,
            transcriptPostProcessor: postProcessor
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testSilenceGuardUsesActiveSamplesWithoutPreRoll() {
        let samples = ContiguousArray(
            Array(repeating: Float(0.1), count: 100)
                + Array(repeating: Float(0.0001), count: 8_000)
        )
        let audio = AudioCaptureStub(samples: samples, prependedSampleCount: 100)
        let transcriber = FakeTranscriber(result: .success("Should not run"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let notified = expectation(description: "active audio is silent")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
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

    func testDegenerateDenseTranscriptionIsVetoedBeforeCorrectionsOrPaste() throws {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let text = (1...13).map(String.init).joined(separator: " ")
        let transcriber = FakeTranscriber(result: .success(text))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let postProcessor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "1", written: "rescued")
        ])
        let notified = expectation(description: "dense transcription rejected")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback,
            transcriptPostProcessor: postProcessor
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testRepeatedLoopTranscriptionIsVetoedAtTheDeliveryBoundary() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let text = Array(repeating: "one two three", count: 4).joined(separator: " ")
        let transcriber = FakeTranscriber(result: .success(text))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let notified = expectation(description: "repeated loop rejected")
        feedback.onError = { message in
            if message == "No speech detected" { notified.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [notified], timeout: 1.0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testAccessibilityDeniedPreventsPaste() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let accessibility = AccessibilityStub(allowed: false)
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-accessibility-denied-\(UUID().uuidString)")
        let store = TranscriptStore(fileURL: historyURL)

        let denied = expectation(description: "accessibility denied")
        feedback.onError = { message in
            if message == "Accessibility permission required" { denied.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback,
            accessibility: accessibility,
            transcriptStore: store
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [denied], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
        XCTAssertEqual(decodedHistory(at: historyURL)?.map(\.finalText), ["Hello"])
    }

    func testPasteFailureReportsClipboardBoundaryAndDoesNotClaimEventsPosted() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let paster = PasterStub(pasteOutcome: .clipboardWriteFailed)
        let feedback = FeedbackStub()

        let failed = expectation(description: "paste failure")
        feedback.onError = { message in
            if message == "Could not update clipboard" { failed.fulfill() }
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [failed], timeout: 1.0)
        XCTAssertEqual(paster.pastedTexts, ["Hello"])
        XCTAssertEqual(paster.pasteOutcomes, [.clipboardWriteFailed])
    }

    func testPersistenceFailureSkipsAccessibilityAndPaste() throws {
        let blockedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-coordinator-blocker-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let store = TranscriptStore(fileURL: blockedParent.appendingPathComponent("history.json"))
        let accessibility = AccessibilityProbe(allowed: true)
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Not pasted"))
        let paster = PasterStub()
        let feedback = FeedbackStub()

        let failed = expectation(description: "persistence failure")
        feedback.onError = { message in
            if message == "Transcript could not be saved" { failed.fulfill() }
        }

        let coordinator = AppCoordinator(
            audioCapture: audio,
            transcriber: transcriber,
            paster: paster,
            flash: FlashStub(),
            feedback: feedback,
            accessibilityChecker: accessibility,
            transcriptionTimeoutProvider: { _ in 1.0 },
            keyMonitorFactory: { _ in nil },
            transcriptStore: store
        )
        coordinator.skipWarmup()

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [failed], timeout: 1.0)
        XCTAssertEqual(store.allEntries(), ["Not pasted"])
        XCTAssertEqual(accessibility.checkCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
    }

    func testThirdToggleIsIgnoredWhileTranscribing() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"), delay: 0.2)
        let paster = PasterStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(audio: audio, transcriber: transcriber, paster: paster)

        coordinator.toggleRecording()
        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(audio.beginCount, 1)
        XCTAssertEqual(audio.endCount, 1)
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(paster.pastedTexts, ["Hello"])
    }

    func testSuccessfulTranscriptionIsStoredBeforePaste() {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-persist-before-paste-\(UUID().uuidString)")
        let store = TranscriptStore(fileURL: historyURL)
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Stored text"))
        let paster = PasterStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = {
            XCTAssertEqual(store.allEntries(), ["Stored text"])
            XCTAssertEqual(self.decodedHistory(at: historyURL)?.map(\.finalText), ["Stored text"])
            pasted.fulfill()
        }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            transcriptStore: store
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(paster.pastedTexts, ["Stored text"])
    }

    func testAcceptedTranscriptionIsCorrectedBeforePersistenceAndPaste() throws {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-corrected-before-paste-\(UUID().uuidString)")
        let store = TranscriptStore(fileURL: historyURL)
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("hello comma world"))
        let paster = PasterStub()
        let postProcessor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "world", written: "Wisp")
        ])

        let pasted = expectation(description: "corrected paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            transcriptStore: store,
            transcriptPostProcessor: postProcessor
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(paster.pastedTexts, ["hello, Wisp"])
        XCTAssertEqual(store.allEntries(), ["hello, Wisp"])
        XCTAssertEqual(decodedHistory(at: historyURL)?.map(\.finalText), ["hello, Wisp"])
    }

    func testCopyLastTranscriptUsesStoredTextWithoutRetranscription() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-copy-last-(UUID().uuidString)"))
        store.append("Last transcript")
        let transcriber = FakeTranscriber(result: .success("Should not run"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: AudioCaptureStub(samples: Self.validSamples),
            transcriber: transcriber,
            paster: paster,
            feedback: feedback,
            transcriptStore: store
        )

        let outcome = coordinator.copyLastTranscript()

        XCTAssertEqual(outcome, .clipboardUpdated)
        XCTAssertEqual(paster.copiedTexts, ["Last transcript"])
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertEqual(feedback.events, [.status("Last transcript copied")])
    }

    func testPasteLastTranscriptUsesStoredTextWithoutRetranscription() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-paste-last-(UUID().uuidString)"))
        store.append("Last transcript")
        let transcriber = FakeTranscriber(result: .success("Should not run"))
        let paster = PasterStub(pasteOutcome: .eventsPosted)
        let coordinator = makeCoordinator(
            audio: AudioCaptureStub(samples: Self.validSamples),
            transcriber: transcriber,
            paster: paster,
            transcriptStore: store
        )

        let outcome = coordinator.pasteLastTranscript()

        XCTAssertEqual(outcome, .eventsPosted)
        XCTAssertEqual(paster.pastedTexts, ["Last transcript"])
        XCTAssertEqual(transcriber.callCount, 0)
    }

    func testAutomaticPasteUsesTargetCapturedAtRecordingStart() {
        let firstTarget = TranscriptDeliveryApplication(
            processIdentifier: 301,
            bundleIdentifier: "com.example.first"
        )
        let secondTarget = TranscriptDeliveryApplication(
            processIdentifier: 302,
            bundleIdentifier: "com.example.second"
        )
        let targetProvider = TestCoordinatorTargetProvider(target: .external(firstTarget))
        let paster = PasterStub()
        let pasted = expectation(description: "automatic paste")
        paster.onPaste = { pasted.fulfill() }
        let coordinator = makeCoordinator(
            audio: AudioCaptureStub(samples: Self.validSamples),
            transcriber: FakeTranscriber(result: .success("Captured target")),
            paster: paster,
            deliveryTargetProvider: targetProvider
        )

        coordinator.toggleRecording()
        targetProvider.target = .external(secondTarget)
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1)
        XCTAssertEqual(paster.pastedTargets, [.external(firstTarget)])
    }

    func testRecoveryPasteResolvesTheCurrentExternalTarget() {
        let firstTarget = TranscriptDeliveryApplication(
            processIdentifier: 401,
            bundleIdentifier: "com.example.first"
        )
        let secondTarget = TranscriptDeliveryApplication(
            processIdentifier: 402,
            bundleIdentifier: "com.example.second"
        )
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-current-target-(UUID().uuidString)"))
        store.append("Stored text")
        let targetProvider = TestCoordinatorTargetProvider(target: .external(firstTarget))
        let paster = PasterStub()
        let coordinator = makeCoordinator(
            audio: AudioCaptureStub(samples: Self.validSamples),
            transcriber: FakeTranscriber(result: .success("Should not run")),
            paster: paster,
            transcriptStore: store,
            deliveryTargetProvider: targetProvider
        )

        targetProvider.target = .external(secondTarget)
        XCTAssertEqual(coordinator.pasteLastTranscript(), .eventsPosted)
        XCTAssertEqual(paster.pastedTargets, [.external(secondTarget)])
    }

    func testPasteLastTranscriptHonorsAccessibilityWithoutRetranscription() {
        let store = TranscriptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-paste-last-denied-(UUID().uuidString)"))
        store.append("Last transcript")
        let transcriber = FakeTranscriber(result: .success("Should not run"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: AudioCaptureStub(samples: Self.validSamples),
            transcriber: transcriber,
            paster: paster,
            feedback: feedback,
            accessibility: AccessibilityStub(allowed: false),
            transcriptStore: store
        )

        let outcome = coordinator.pasteLastTranscript()

        XCTAssertNil(outcome)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertEqual(feedback.errors, ["Accessibility permission required"])
    }

    func testInjectedTranscriptionQueueRunsStopAndTranscribeWork() {
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "com.speakeasy.app.tests.injected-transcription")
        queue.setSpecific(key: key, value: "injected")

        let audio = AudioCaptureStub(samples: Self.validSamples, expectedQueue: (key, "injected"))
        let transcriber = FakeTranscriber(result: .success("Hello"), expectedQueue: (key, "injected"))
        let paster = PasterStub()

        let pasted = expectation(description: "paste")
        paster.onPaste = { pasted.fulfill() }

        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            transcriptionQueue: queue
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        wait(for: [pasted], timeout: 1.0)
        XCTAssertEqual(audio.endRecordingUsedExpectedQueue, true)
        XCTAssertEqual(transcriber.transcribeUsedExpectedQueue, true)
    }

    // MARK: - Capture recovery

    func testCaptureStartFailureRollsBackAndKeepsFlashHidden() {
        let audio = AudioCaptureStub(
            samples: Self.validSamples,
            beginError: AudioCaptureError.unavailable
        )
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            flash: flash,
            feedback: feedback
        )

        coordinator.toggleRecording()

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(audio.beginCount, 1)
        XCTAssertEqual(flash.showCount, 0)
        XCTAssertEqual(feedback.errors, ["Microphone reconnecting, try again shortly"])
    }

    func testCaptureInterruptionReturnsCoordinatorToIdleAndHidesFlash() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let flash = FlashStub()
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            flash: flash,
            feedback: feedback
        )

        coordinator.toggleRecording()
        XCTAssertTrue(waitUntil { flash.showCount == 1 })
        audio.emit(.recoveryStarted(interruptedRecording: true))
        audio.emit(.recoverySucceeded)

        XCTAssertTrue(waitUntil {
            feedback.errors.contains("Recording interrupted by microphone change")
        })
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(flash.hideCount, 1)
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertEqual(
            feedback.events,
            [.error("Recording interrupted by microphone change")]
        )

        coordinator.toggleRecording()
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(audio.beginCount, 2)
    }

    func testInterruptedStopRetainsSessionOwnershipUntilEndRecordingReturns() {
        let endRecordingStarted = DispatchSemaphore(value: 0)
        let releaseEndRecording = DispatchSemaphore(value: 0)
        let audio = AudioCaptureStub(
            samples: Self.validSamples,
            wasInterrupted: true,
            endRecordingStarted: endRecordingStarted,
            endRecordingGate: releaseEndRecording
        )
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            feedback: feedback
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()
        XCTAssertEqual(endRecordingStarted.wait(timeout: .now() + 1), .success)

        let recoveryEventsApplied = expectation(description: "recovery events applied")
        audio.emit(.recoveryStarted(interruptedRecording: true))
        audio.emit(.recoverySucceeded)
        DispatchQueue.main.async {
            recoveryEventsApplied.fulfill()
        }
        wait(for: [recoveryEventsApplied], timeout: 1)

        coordinator.toggleRecording()
        XCTAssertEqual(audio.beginCount, 1)
        XCTAssertTrue(feedback.events.isEmpty)

        releaseEndRecording.signal()
        XCTAssertTrue(waitUntil {
            feedback.errors == ["Recording interrupted by microphone change"]
        })
        XCTAssertEqual(transcriber.callCount, 0)

        coordinator.toggleRecording()
        XCTAssertEqual(audio.beginCount, 2)
    }

    func testInterruptedCaptureResultNeverReachesTranscriber() {
        let audio = AudioCaptureStub(
            samples: Self.validSamples,
            wasInterrupted: true
        )
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let paster = PasterStub()
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            paster: paster,
            feedback: feedback
        )

        coordinator.toggleRecording()
        coordinator.toggleRecording()

        XCTAssertTrue(waitUntil {
            feedback.errors.contains("Recording interrupted by microphone change")
        })
        XCTAssertEqual(transcriber.callCount, 0)
        XCTAssertTrue(paster.pastedTexts.isEmpty)
        XCTAssertFalse(coordinator.isRecording)
    }

    func testRecoveryEventsPreserveStatusAndFailureMessages() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("ignored"))
        let feedback = FeedbackStub()
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            feedback: feedback
        )

        audio.emit(.recoveryStarted(interruptedRecording: false))
        audio.emit(.recoverySucceeded)
        audio.emit(.recoveryFailed)

        XCTAssertTrue(waitUntil { feedback.events.count == 3 })
        XCTAssertEqual(
            feedback.events,
            [
                .status("Microphone reconnecting…"),
                .status("Microphone reconnected"),
                .error("Microphone reconnection failed")
            ]
        )
        XCTAssertFalse(coordinator.isRecording)
    }

    // MARK: - Phase 1: Warmup gate

    /// Hotkey during warmup must be silently dropped; no audio start.
    func testHotkeyDuringWarmupIsIgnored() {
        let audio = AudioCaptureStub(samples: Self.validSamples)
        let transcriber = FakeTranscriber(result: .success("Hello"))
        let feedback = FeedbackStub()
        let diagnostics = DiagnosticsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("speakeasy-warmup-stats-\(UUID().uuidString)")
                .appendingPathComponent("stats.json")
        )

        // skipWarmup: false — coordinator starts in .warming / .pending
        let coordinator = makeCoordinator(
            audio: audio,
            transcriber: transcriber,
            feedback: feedback,
            skipWarmup: false,
            diagnosticsStore: diagnostics
        )

        coordinator.toggleRecording()

        // Audio must not start because warmup hasn't finished
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertEqual(diagnostics.snapshot().lifetime.outcomes.warmupBlocked, 1)
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
    private var _endRecordingUsedExpectedQueue: Bool?
    private let prepareError: Error?
    private let beginError: Error?
    private var eventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    private let samples: ContiguousArray<Float>
    private let prependedSampleCount: Int
    private let graceDurationMs: Double
    private let wasInterrupted: Bool
    private let expectedQueue: (key: DispatchSpecificKey<String>, value: String)?
    private let endRecordingStarted: DispatchSemaphore?
    private let endRecordingGate: DispatchSemaphore?

    var prepareCount: Int { counterLock.withLock { _prepareCount } }
    var beginCount: Int { counterLock.withLock { _beginCount } }
    var endCount: Int { counterLock.withLock { _endCount } }
    var shutdownCount: Int { counterLock.withLock { _shutdownCount } }
    var lastEndRecordingWasMainThread: Bool? { counterLock.withLock { _lastEndRecordingWasMainThread } }
    var endRecordingUsedExpectedQueue: Bool? { counterLock.withLock { _endRecordingUsedExpectedQueue } }

    /// Convenience aliases used by older tests.
    var startCount: Int { beginCount }
    var stopCount: Int { endCount }

    init(
        samples: ContiguousArray<Float>,
        prepareError: Error? = nil,
        beginError: Error? = nil,
        prependedSampleCount: Int = 0,
        graceDurationMs: Double = 0,
        wasInterrupted: Bool = false,
        expectedQueue: (key: DispatchSpecificKey<String>, value: String)? = nil,
        endRecordingStarted: DispatchSemaphore? = nil,
        endRecordingGate: DispatchSemaphore? = nil
    ) {
        self.samples = samples
        self.prepareError = prepareError
        self.beginError = beginError
        self.prependedSampleCount = prependedSampleCount
        self.graceDurationMs = graceDurationMs
        self.wasInterrupted = wasInterrupted
        self.expectedQueue = expectedQueue
        self.endRecordingStarted = endRecordingStarted
        self.endRecordingGate = endRecordingGate
    }

    func prepare() throws {
        counterLock.withLock { _prepareCount += 1 }
        if let error = prepareError { throw error }
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioCaptureEvent) -> Void) {
        counterLock.withLock {
            eventHandler = handler
        }
    }

    func beginRecording() throws {
        counterLock.withLock { _beginCount += 1 }
        if let beginError {
            throw beginError
        }
    }

    func emit(_ event: AudioCaptureEvent) {
        let handler = counterLock.withLock { eventHandler }
        handler?(event)
    }

    func endRecording() -> AudioCaptureResult {
        counterLock.withLock {
            _endCount += 1
            _lastEndRecordingWasMainThread = Thread.isMainThread
            if let expectedQueue {
                _endRecordingUsedExpectedQueue = DispatchQueue.getSpecific(key: expectedQueue.key) == expectedQueue.value
            }
        }
        endRecordingStarted?.signal()
        endRecordingGate?.wait()
        return AudioCaptureResult(
            samples: samples,
            prependedSampleCount: prependedSampleCount,
            graceDurationMs: graceDurationMs,
            wasInterrupted: wasInterrupted
        )
    }

    func shutdown() {
        counterLock.withLock { _shutdownCount += 1 }
    }
}

private final class FakeTranscriber: Transcriber, @unchecked Sendable {
    private let counterLock = UnfairLock()
    private let result: Result<String, Error>
    private let delay: TimeInterval
    private let warmUpError: Error?
    private let expectedQueue: (key: DispatchSpecificKey<String>, value: String)?
    private var _callCount = 0
    private var _warmUpCount = 0
    private var _transcribeUsedExpectedQueue: Bool?

    var callCount: Int { counterLock.withLock { _callCount } }
    var warmUpCount: Int { counterLock.withLock { _warmUpCount } }
    var transcribeUsedExpectedQueue: Bool? { counterLock.withLock { _transcribeUsedExpectedQueue } }

    init(
        result: Result<String, Error>,
        delay: TimeInterval = 0,
        warmUpError: Error? = nil,
        expectedQueue: (key: DispatchSpecificKey<String>, value: String)? = nil
    ) {
        self.result = result
        self.delay = delay
        self.warmUpError = warmUpError
        self.expectedQueue = expectedQueue
    }

    func transcribe(samples: ContiguousArray<Float>) throws -> String {
        counterLock.withLock {
            _callCount += 1
            if let expectedQueue {
                _transcribeUsedExpectedQueue = DispatchQueue.getSpecific(key: expectedQueue.key) == expectedQueue.value
            }
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func warmUp() async throws {
        counterLock.withLock { _warmUpCount += 1 }
        if let error = warmUpError { throw error }
    }
}

private final class PasterStub: Pasting {
    private(set) var pastedTexts: [String] = []
    private(set) var copiedTexts: [String] = []
    private(set) var pasteOutcomes: [TranscriptDeliveryOutcome] = []
    private(set) var pastedTargets: [TranscriptDeliveryTarget?] = []
    private(set) var copyOutcomes: [TranscriptDeliveryOutcome] = []
    var onPaste: (() -> Void)?
    var pasteOutcome: TranscriptDeliveryOutcome
    var copyOutcome: TranscriptDeliveryOutcome

    init(
        pasteOutcome: TranscriptDeliveryOutcome = .eventsPosted,
        copyOutcome: TranscriptDeliveryOutcome = .clipboardUpdated
    ) {
        self.pasteOutcome = pasteOutcome
        self.copyOutcome = copyOutcome
    }

    func copy(_ text: String) -> TranscriptDeliveryOutcome {
        copiedTexts.append(text)
        copyOutcomes.append(copyOutcome)
        return copyOutcome
    }

    func paste(_ text: String) -> TranscriptDeliveryOutcome {
        pastedTexts.append(text)
        onPaste?()
        pasteOutcomes.append(pasteOutcome)
        return pasteOutcome
    }

    func paste(
        _ text: String,
        target: TranscriptDeliveryTarget?
    ) -> TranscriptDeliveryOutcome {
        pastedTargets.append(target)
        return paste(text)
    }
}

private final class TestCoordinatorTargetProvider: DeliveryTargetProviding {
    var target: TranscriptDeliveryTarget

    init(target: TranscriptDeliveryTarget = .unavailable) {
        self.target = target
    }

    func currentTarget() -> TranscriptDeliveryTarget { target }

    func isRunning(_ application: TranscriptDeliveryApplication) -> Bool { true }
}

private final class FlashStub: Flashing {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func show(lineWidth: CGFloat) { showCount += 1 }
    func hide(completion: (() -> Void)?) { hideCount += 1; completion?() }
}

private final class FeedbackStub: UserFeedback {
    private(set) var events: [UserFeedbackEvent] = []
    var errors: [String] {
        events.compactMap { event in
            if case let .error(message) = event {
                return message
            }
            return nil
        }
    }
    var onError: ((String) -> Void)?

    func notify(event: UserFeedbackEvent) {
        events.append(event)
        if case let .error(message) = event {
            onError?(message)
        }
    }
}

private struct AccessibilityStub: AccessibilityChecking {
    let allowed: Bool
    func hasAccessibilityAccess() -> Bool { allowed }
}

private final class AccessibilityProbe: AccessibilityChecking {
    let allowed: Bool
    private(set) var checkCount = 0

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func hasAccessibilityAccess() -> Bool {
        checkCount += 1
        return allowed
    }
}

private struct TestError: Error {}
