import AppKit
import AVFoundation
import XCTest
@testable import Speakeasy

final class AudioCaptureTests: XCTestCase {
    private func makeFormat(sampleRate: Double = 16_000) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
    }

    private func makeEngine(sampleRate: Double = 16_000) throws -> FakeAudioEngine {
        FakeAudioEngine(input: FakeAudioInputNode(format: try makeFormat(sampleRate: sampleRate)))
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
        try engine.input.emit(frameLength: 1_024)
        try capture.beginRecording()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.set(capture.endRecording())
            stopped.fulfill()
        }

        wait(for: [awaitingGrace], timeout: 1.0)
        try engine.input.emit(frameLength: 10_000)

        wait(for: [stopped], timeout: 0.2)
        let result = try XCTUnwrap(resultBox.result)
        XCTAssertLessThan(result.graceDurationMs, 200)
        XCTAssertFalse(result.samples.isEmpty)
    }

    func testRecordingGrowsPastSixMinutesWithoutStopping() throws {
        let engine = try makeEngine()
        let capture = try AudioCapture(engine: engine)
        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        try capture.beginRecording()
        for _ in 0..<421 {
            try engine.input.emit(frameLength: 16_000)
        }
        XCTAssertEqual(capture.livePreviewSamples().count, 240_000)
        let result = capture.endRecording()
        XCTAssertGreaterThan(result.samples.count, 16_000 * 60 * 6)
    }

    func testPreviewIncludesPendingBackBufferAndOnlyLastFifteenSeconds() throws {
        let engine = try makeEngine()
        let capture = try AudioCapture(engine: engine)
        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        try capture.beginRecording()
        for _ in 0..<15 {
            try engine.input.emit(frameLength: 16_000)
        }
        try engine.input.emit(frameLength: 16_000, value: 0.2)
        try engine.input.emit(frameLength: 1_024, value: 0.3)
        let preview = capture.livePreviewSamples()
        XCTAssertEqual(preview.count, 240_000)
        XCTAssertEqual(preview.first, 0.1)
        XCTAssertTrue(preview.contains(0.2))
        XCTAssertEqual(preview.last, 0.3)
    }

    func testInjectedSafetyCeilingStopsAtExactSampleCount() throws {
        let engine = try makeEngine()
        var notifications = 0
        let capture = try AudioCapture(maxRecordingSamples: 20_000, onLimitReached: {
            notifications += 1
        }, engine: engine)
        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        try capture.beginRecording()
        try engine.input.emit(frameLength: 16_000)
        try engine.input.emit(frameLength: 16_000)
        try engine.input.emit(frameLength: 16_000)
        XCTAssertEqual(capture.endRecording().samples.count, 20_000)
        XCTAssertEqual(notifications, 1)
    }

    func testConfigurationChangeRebuildsGraphWithFreshInputFormat() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let recovered = expectation(description: "capture recovered")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.input.format = try makeFormat(sampleRate: 48_000)
        engine.forceStopped()
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [recovered], timeout: 1.0)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.prepareCount, 2)
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(engine.input.installTapCount, 2)
        XCTAssertEqual(engine.input.removeTapCount, 1)
        XCTAssertEqual(engine.input.installedSampleRates, [16_000, 48_000])
    }

    func testConfigurationChangeBurstCoalescesIntoOneRebuild() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let lifecycleQueue = DispatchQueue(label: "com.speakeasy.app.tests.audio-lifecycle")
        let recovered = expectation(description: "capture recovered once")
        recovered.expectedFulfillmentCount = 1
        let capture = try AudioCapture(
            engine: engine,
            lifecycleQueue: lifecycleQueue,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }

        lifecycleQueue.suspend()
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        lifecycleQueue.resume()

        wait(for: [recovered], timeout: 1.0)
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(engine.input.installTapCount, 2)
        XCTAssertEqual(engine.input.removeTapCount, 1)
    }

    func testConfigurationChangeDuringRecoverySchedulesLatestRoute() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let recovered = expectation(description: "latest route recovered")
        recovered.expectedFulfillmentCount = 1
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            switch engine.startCount {
            case 2:
                notificationCenter.post(
                    name: .AVAudioEngineConfigurationChange,
                    object: engine
                )
                try? engine.input.emit(frameLength: 1_024)
            case 3:
                try? engine.input.emit(frameLength: 1_024)
            default:
                break
            }
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [recovered], timeout: 1)
        XCTAssertEqual(engine.startCount, 3)
        XCTAssertEqual(engine.input.installTapCount, 3)
        XCTAssertEqual(engine.input.removeTapCount, 2)
    }

    func testStaleRecoverySuccessIsSuppressedWhenLatestRouteFails() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let failed = expectation(description: "latest route failed")
        let staleSuccess = expectation(description: "stale recovery success")
        staleSuccess.isInverted = true
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            switch event {
            case .recoverySucceeded:
                staleSuccess.fulfill()
            case .recoveryFailed:
                failed.fulfill()
            case .recoveryStarted:
                break
            case .inputDeviceSelectionSucceeded, .inputDeviceSelectionFailed:
                break
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            guard engine.startCount == 2 else {
                return
            }
            try? engine.input.emit(frameLength: 1_024)
            engine.startError = TestError()
            notificationCenter.post(
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [failed, staleSuccess], timeout: 1)
        XCTAssertEqual(engine.startCount, 4)
    }

    func testMissingFirstCallbackRetriesAutomatically() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let recovered = expectation(description: "capture recovered after timeout retry")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter,
            firstCallbackTimeout: 0.01
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            if engine.startCount == 3 {
                try? engine.input.emit(frameLength: 1_024)
            }
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [recovered], timeout: 1)
        XCTAssertEqual(engine.startCount, 3)
    }

    func testCallbackThenStoppedEngineUsesBoundedRetryBudget() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let failed = expectation(description: "callback validation exhausted retries")
        let falseSuccess = expectation(description: "stopped engine reported success")
        falseSuccess.isInverted = true
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            switch event {
            case .recoverySucceeded:
                falseSuccess.fulfill()
            case .recoveryFailed:
                failed.fulfill()
            case .recoveryStarted:
                break
            case .inputDeviceSelectionSucceeded, .inputDeviceSelectionFailed:
                break
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
            engine.forceStopped()
        }

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)

        wait(for: [failed, falseSuccess], timeout: 1)
        XCTAssertEqual(engine.startCount, 4)
    }

    func testStaleCallbackRejectsRecordingAndSelfHeals() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let clock = TestClock(now: 1_000)
        let recovered = expectation(description: "stale capture recovered")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter,
            clock: clock.read,
            callbackFreshnessNs: 100
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        clock.advance(by: 101)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }

        XCTAssertThrowsError(try capture.beginRecording()) { error in
            guard case AudioCaptureError.unavailable = error else {
                XCTFail("Expected unavailable, got \(error)")
                return
            }
        }
        wait(for: [recovered], timeout: 1.0)

        XCTAssertNoThrow(try capture.beginRecording())
        XCTAssertEqual(engine.startCount, 2)
    }

    func testWakeWithStaleCallbackRebuildsCapture() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let wakeNotificationCenter = NotificationCenter()
        let clock = TestClock(now: 1_000)
        let recovered = expectation(description: "wake recovery completed")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: wakeNotificationCenter,
            clock: clock.read,
            callbackFreshnessNs: 100
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        clock.advance(by: 101)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }

        wakeNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        wait(for: [recovered], timeout: 1.0)
        XCTAssertEqual(engine.startCount, 2)
    }

    func testRecoveryFailureCanRetryOnNextRecordingAttempt() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let failed = expectation(description: "capture recovery failed")
        let recovered = expectation(description: "capture retry recovered")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            switch event {
            case .recoveryFailed:
                failed.fulfill()
            case .recoverySucceeded:
                recovered.fulfill()
            case .recoveryStarted:
                break
            case .inputDeviceSelectionSucceeded, .inputDeviceSelectionFailed:
                break
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.startError = TestError()
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        wait(for: [failed], timeout: 1.0)

        engine.startError = nil
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }
        XCTAssertThrowsError(try capture.beginRecording())
        wait(for: [recovered], timeout: 1.0)

        XCTAssertNoThrow(try capture.beginRecording())
        XCTAssertEqual(engine.startCount, 5)
    }

    func testConfigurationChangeDuringGraceReturnsInterruptedResult() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let awaitingGrace = expectation(description: "awaiting grace")
        let stopped = expectation(description: "stop returned")
        let resultBox = CaptureResultBox()
        let capture = try AudioCapture(
            engine: engine,
            onAwaitingGrace: { awaitingGrace.fulfill() },
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        try capture.beginRecording()
        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.set(capture.endRecording())
            stopped.fulfill()
        }

        wait(for: [awaitingGrace], timeout: 1.0)
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        wait(for: [stopped], timeout: 0.2)

        let result = try XCTUnwrap(resultBox.result)
        XCTAssertTrue(result.wasInterrupted)
        XCTAssertLessThan(result.graceDurationMs, 80)
    }

    func testOldTapCallbackIsDiscardedAfterRecovery() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let recovered = expectation(description: "capture recovered")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            wakeNotificationCenter: notificationCenter
        )
        capture.setEventHandler { event in
            if event == .recoverySucceeded {
                recovered.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024)
        }
        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        wait(for: [recovered], timeout: 1.0)

        try capture.beginRecording()
        try engine.input.emit(frameLength: 8_000, throughRetainedTapAt: 0)
        let result = capture.endRecording()

        XCTAssertEqual(result.samples.count, result.prependedSampleCount)
        XCTAssertFalse(result.wasInterrupted)
    }

    func testInputDeviceSelectionCommitsOnlyAfterFreshCallback() throws {
        let engine = try makeEngine()
        let provider = FakeInputDeviceProvider(devices: [
            MicrophoneDevice(uid: "built-in", name: "Built-in"),
            MicrophoneDevice(uid: "usb", name: "USB")
        ])
        let selected = expectation(description: "route selected")
        let capture = try AudioCapture(
            engine: engine,
            firstCallbackTimeout: 0.1,
            inputDeviceProvider: provider
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionSucceeded(uid: "usb") {
                selected.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        XCTAssertNil(capture.selectedInputDeviceUID())

        engine.onStart = { try? engine.input.emit(frameLength: 1_024) }
        capture.selectInputDevice(uid: "usb")
        wait(for: [selected], timeout: 1)

        XCTAssertEqual(provider.setUIDs, ["usb"])
        XCTAssertEqual(capture.selectedInputDeviceUID(), "usb")
    }

    func testInputDeviceSelectionReadsFormatAfterApplyingRoute() throws {
        let engine = try makeEngine()
        let routeFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let provider = FakeInputDeviceProvider(devices: [MicrophoneDevice(uid: "usb", name: "USB")])
        provider.onSet = { uid in
            if uid == "usb" {
                engine.input.format = routeFormat
            }
        }
        let selected = expectation(description: "route selected")
        let capture = try AudioCapture(engine: engine, inputDeviceProvider: provider)
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionSucceeded(uid: "usb") {
                selected.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = { try? engine.input.emit(frameLength: 1_024) }
        capture.selectInputDevice(uid: "usb")
        wait(for: [selected], timeout: 1)

        XCTAssertEqual(engine.input.installedSampleRates.last, 48_000)
    }

    func testRouteConfigurationNotificationDoesNotSupersedeSelectionTransaction() throws {
        let engine = try makeEngine()
        let notificationCenter = NotificationCenter()
        let provider = FakeInputDeviceProvider(devices: [MicrophoneDevice(uid: "usb", name: "USB")])
        provider.onSet = { uid in
            guard uid == "usb" else { return }
            notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
        let selected = expectation(description: "route selected")
        let capture = try AudioCapture(
            engine: engine,
            notificationCenter: notificationCenter,
            inputDeviceProvider: provider
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionSucceeded(uid: "usb") {
                selected.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = { try? engine.input.emit(frameLength: 1_024) }

        capture.selectInputDevice(uid: "usb")
        wait(for: [selected], timeout: 1)

        XCTAssertEqual(capture.selectedInputDeviceUID(), "usb")
        XCTAssertEqual(engine.startCount, 2)
    }

    func testSystemDefaultRouteIsRestoredAfterCandidateFailure() throws {
        let engine = try makeEngine()
        let provider = FakeInputDeviceProvider(
            devices: [
                MicrophoneDevice(uid: "built-in", name: "Built-in"),
                MicrophoneDevice(uid: "usb", name: "USB")
            ],
            defaultUID: "built-in",
            failures: ["usb"]
        )
        let failed = expectation(description: "route failed")
        let capture = try AudioCapture(
            engine: engine,
            inputDeviceProvider: provider,
            initialInputDeviceUID: "built-in"
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionFailed(uid: "usb", rollback: .restored) {
                failed.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        XCTAssertEqual(capture.selectedInputDeviceUID(), "built-in")
        engine.onStart = { try? engine.input.emit(frameLength: 1_024) }

        capture.selectInputDevice(uid: "usb")
        wait(for: [failed], timeout: 1)

        XCTAssertEqual(provider.setUIDs, ["built-in", "usb", "built-in"])
        XCTAssertEqual(capture.selectedInputDeviceUID(), "built-in")
    }

    func testInputDeviceSelectionRollsBackOnRouteFailure() throws {
        let engine = try makeEngine()
        let provider = FakeInputDeviceProvider(
            devices: [MicrophoneDevice(uid: "usb", name: "USB")],
            failures: ["usb"]
        )
        let failed = expectation(description: "route failed")
        let capture = try AudioCapture(
            engine: engine,
            firstCallbackTimeout: 0.1,
            inputDeviceProvider: provider
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionFailed(uid: "usb", rollback: .restored) {
                failed.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = { try? engine.input.emit(frameLength: 1_024) }
        capture.selectInputDevice(uid: "usb")

        wait(for: [failed], timeout: 1)
        XCTAssertNil(capture.selectedInputDeviceUID())
        XCTAssertEqual(engine.startCount, 2, "The previous system route was restarted")
    }

    func testInputDeviceSelectionFailsIfRollbackProducesNoCallback() throws {
        let engine = try makeEngine()
        let provider = FakeInputDeviceProvider(
            devices: [MicrophoneDevice(uid: "usb", name: "USB")],
            failures: ["usb"]
        )
        let failed = expectation(description: "route failed after rollback timeout")
        let capture = try AudioCapture(
            engine: engine,
            firstCallbackTimeout: 0.01,
            inputDeviceProvider: provider
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionFailed(uid: "usb", rollback: .unavailable) {
                failed.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        capture.selectInputDevice(uid: "usb")

        wait(for: [failed], timeout: 1)
        XCTAssertNil(capture.selectedInputDeviceUID())
    }

    func testStaleInputCallbackCannotCommitNewRoute() throws {
        let engine = try makeEngine()
        let provider = FakeInputDeviceProvider(devices: [MicrophoneDevice(uid: "usb", name: "USB")])
        let selected = expectation(description: "route selected")
        let capture = try AudioCapture(
            engine: engine,
            firstCallbackTimeout: 0.1,
            inputDeviceProvider: provider
        )
        capture.setEventHandler { event in
            if event == .inputDeviceSelectionSucceeded(uid: "usb") {
                selected.fulfill()
            }
        }

        try capture.prepare()
        try engine.input.emit(frameLength: 1_024)
        engine.onStart = {
            try? engine.input.emit(frameLength: 1_024, throughRetainedTapAt: 0)
            try? engine.input.emit(frameLength: 1_024)
        }
        capture.selectInputDevice(uid: "usb")

        wait(for: [selected], timeout: 1)
        XCTAssertEqual(capture.selectedInputDeviceUID(), "usb")
    }
}

private final class FakeAudioEngine: NSObject, AudioEngineProtocol {
    let input: FakeAudioInputNode
    var startError: Error?
    var onStart: (() -> Void)?
    private(set) var isRunning = false
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
        isRunning = true
        onStart?()
    }

    func forceStopped() {
        isRunning = false
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

private final class FakeAudioInputNode: AudioInputNodeProtocol {
    var format: AVAudioFormat
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private(set) var installedSampleRates: [Double] = []
    private var tapBlock: AVAudioNodeTapBlock?
    private var retainedTapBlocks: [AVAudioNodeTapBlock] = []

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
        installedSampleRates.append(format?.sampleRate ?? 0)
        self.tapBlock = tapBlock
        retainedTapBlocks.append(tapBlock)
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        removeTapCount += 1
        tapBlock = nil
    }

    func emit(frameLength: AVAudioFrameCount, value: Float = 0.1) throws {
        try emit(frameLength: frameLength, through: tapBlock, value: value)
    }

    func emit(frameLength: AVAudioFrameCount, throughRetainedTapAt index: Int) throws {
        try emit(frameLength: frameLength, through: retainedTapBlocks[index], value: 0.1)
    }

    private func emit(
        frameLength: AVAudioFrameCount,
        through tapBlock: AVAudioNodeTapBlock?,
        value: Float
    ) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength))
        buffer.frameLength = frameLength

        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameLength) {
                channel[index] = value
            }
        }

        let time = AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        tapBlock?(buffer, time)
    }
}

private final class FakeInputDeviceProvider: AudioInputDeviceProviding {
    let devices: [MicrophoneDevice]
    let failures: Set<String>
    let defaultUID: String?
    var onSet: ((String) -> Void)?
    private(set) var setUIDs: [String] = []

    init(
        devices: [MicrophoneDevice],
        defaultUID: String? = nil,
        failures: Set<String> = []
    ) {
        self.devices = devices
        self.defaultUID = defaultUID
        self.failures = failures
    }

    func enumerateInputDevices() -> [MicrophoneDevice] { devices }

    func defaultInputDeviceUID() -> String? { defaultUID }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {
        setUIDs.append(uid)
        onSet?(uid)
        if failures.contains(uid) {
            throw TestError()
        }
    }
}

private final class CaptureResultBox: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storedResult: AudioCaptureResult?

    var result: AudioCaptureResult? {
        lock.withLock { storedResult }
    }

    func set(_ result: AudioCaptureResult) {
        lock.withLock { storedResult = result }
    }
}

private final class TestClock {
    private let lock = UnfairLock()
    private var now: UInt64

    init(now: UInt64) {
        self.now = now
    }

    func read() -> UInt64 {
        lock.withLock { now }
    }

    func advance(by interval: UInt64) {
        lock.withLock {
            now += interval
        }
    }
}

private struct TestError: Error {}
