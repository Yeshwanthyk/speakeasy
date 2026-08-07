import Carbon
import CoreGraphics
import Foundation
import os

protocol AudioCapturing {
    /// Arm the engine at startup. Must be called before `beginRecording()`.
    func prepare() throws
    /// Receive runtime capture recovery and interruption events.
    func setEventHandler(_ handler: @escaping @Sendable (AudioCaptureEvent) -> Void)
    /// Begin accumulating audio only when the engine and input callback are healthy.
    func beginRecording() throws
    /// Stop accumulating; flush and return all captured samples plus capture metadata.
    func endRecording() -> AudioCaptureResult
    /// Stop the engine entirely. Call at app termination.
    func shutdown()
}

protocol Pasting {
    func copy(_ text: String) -> TranscriptDeliveryOutcome
    func paste(_ text: String) -> TranscriptDeliveryOutcome
    func paste(_ text: String, target: TranscriptDeliveryTarget?) -> TranscriptDeliveryOutcome
}

extension Pasting {
    func paste(
        _ text: String,
        target: TranscriptDeliveryTarget?
    ) -> TranscriptDeliveryOutcome {
        paste(text)
    }
}

@MainActor
protocol Flashing {
    func show(lineWidth: CGFloat)
    func hide(completion: (() -> Void)?)
}

protocol AccessibilityChecking {
    func hasAccessibilityAccess() -> Bool
}

typealias KeyMonitorFactory = (_ callback: @escaping () -> Void) -> KeyComboMonitor?
typealias ASRModelResolver = (_ kind: ASRModelKind) async throws -> ASRModelConfiguration
typealias TranscriberFactory = (_ model: ASRModelConfiguration) throws -> Transcriber
typealias ASRModelArtifactVerifier = (_ model: ASRModelConfiguration) throws -> Void
typealias ASRModelSelectionStore = (_ kind: ASRModelKind) -> Void

extension AudioCapture: AudioCapturing {}
extension ScreenEdgeFlash: Flashing {}

struct SystemAccessibilityChecker: AccessibilityChecking {
    func hasAccessibilityAccess() -> Bool {
        Permissions.hasAccessibilityAccess()
    }
}

final class AppCoordinator: @unchecked Sendable {
    private enum State {
        case idle
        case startingCapture
        case recording
        case transcribing(UUID, didTimeOut: Bool)
    }

    /// Readiness of the transcription model.
    private enum WarmupState {
        /// Warmup has not started yet.
        case pending
        /// Warmup is in progress.
        case warming
        /// Model ready — warmup succeeded.
        case ready
        /// Warmup threw; model may still be usable for real transcriptions.
        case failed(Error)

        var isReady: Bool {
            switch self {
            case .ready, .failed: return true
            case .pending, .warming: return false
            }
        }
    }

    private enum Transition {
        case start(TranscriptionTrace, TranscriptDeliveryTarget)
        case stop(UUID, TranscriptionTrace, TranscriptDeliveryTarget)
        case blocked(TranscriptionTrace, String)
        case ignore(String?)
    }

    private enum ModelSwitchStart {
        case start(id: UUID, previousWarmupState: WarmupState)
        case alreadySelected
        case reject(String)
    }

    private static let flashLineWidth: CGFloat = 3
    private static let transcriptionSampleRate: Double = 16_000
    private static let minTranscriptionTimeout: TimeInterval = 30
    private static let maxTranscriptionTimeout: TimeInterval = 600
    /// Minimum active (non-preroll) samples required. 4800 = 300ms at 16kHz.
    private static let minActiveSamples = 4_800
    /// Keep this conservative: microphone gain can put valid speech near -48 dBFS.
    private static let silenceRmsThreshold: Float = 0.002

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private let audioCapture: AudioCapturing
    private var transcriber: Transcriber
    let paster: Pasting
    let transcriptStore: TranscriptStore?
    let diagnosticsStore: DiagnosticsStore?
    private let feedback: UserFeedback
    private let accessibilityChecker: AccessibilityChecking
    private let deliveryTargetProvider: DeliveryTargetProviding
    private let hallucinationFilter: HallucinationFilter
    private let transcriptPostProcessor: TranscriptPostProcessor
    private var currentASRModelKind: ASRModelKind
    private let asrModelResolver: ASRModelResolver?
    private let transcriberFactory: TranscriberFactory?
    private let modelArtifactVerifier: ASRModelArtifactVerifier
    private let modelSelectionStore: ASRModelSelectionStore
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private var warmupState: WarmupState = .pending
    private var activeModelSwitchID: UUID?
    private var suppressRecoverySuccessStatus = false
    /// Partial trace built during a recording session; nil when idle or transcribing.
    private var activeTrace: TranscriptionTrace?
    /// Target captured before automatic recording starts. Recovery actions do
    /// not use this value; they resolve a fresh external target.
    private var activeDeliveryTarget: TranscriptDeliveryTarget?
    private let transcriptionQueue: DispatchQueue
    private let flash: Flashing
    private var keyMonitor: KeyComboMonitor?

    var isRecording: Bool {
        stateLock.withLock {
            if case .recording = state {
                return true
            }
            return false
        }
    }

    init(
        audioCapture: AudioCapturing,
        transcriber: Transcriber,
        paster: Pasting,
        flash: Flashing,
        feedback: UserFeedback,
        accessibilityChecker: AccessibilityChecking,
        hallucinationFilter: HallucinationFilter = HallucinationFilter(),
        asrModelKind: ASRModelKind = .parakeetUnified,
        asrModelResolver: ASRModelResolver? = nil,
        transcriberFactory: TranscriberFactory? = nil,
        modelArtifactVerifier: @escaping ASRModelArtifactVerifier = { model in
            try ModelPathResolver.verifyModelArtifact(kind: model.kind, at: model.url)
        },
        modelSelectionStore: @escaping ASRModelSelectionStore = { _ in },
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?,
        transcriptStore: TranscriptStore? = nil,
        diagnosticsStore: DiagnosticsStore? = nil,
        transcriptPostProcessor: TranscriptPostProcessor = TranscriptPostProcessor(),
        transcriptionQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInteractive),
        deliveryTargetProvider: DeliveryTargetProviding = SystemDeliveryTargetProvider()
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.paster = paster
        self.flash = flash
        self.feedback = feedback
        self.accessibilityChecker = accessibilityChecker
        self.deliveryTargetProvider = deliveryTargetProvider
        self.hallucinationFilter = hallucinationFilter
        self.transcriptPostProcessor = transcriptPostProcessor
        self.currentASRModelKind = asrModelKind
        self.asrModelResolver = asrModelResolver
        self.transcriberFactory = transcriberFactory
        self.modelArtifactVerifier = modelArtifactVerifier
        self.modelSelectionStore = modelSelectionStore
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider
        self.transcriptStore = transcriptStore
        self.diagnosticsStore = diagnosticsStore
        self.transcriptionQueue = transcriptionQueue

        audioCapture.setEventHandler { [weak self] event in
            self?.handleAudioCaptureEvent(event)
        }

        keyMonitor = keyMonitorFactory? { [weak self] in
            self?.toggleRecording()
        }

        logger.debug("AppCoordinator ready")
    }

    /// Arm the audio engine so it's hot before the first hotkey press.
    /// Called once at startup, in parallel with or before `warmUpModel()`.
    func prepareCapture() throws {
        try audioCapture.prepare()
        logger.info("Audio capture prepared")
    }

    /// Warm up the transcription model; blocks hotkey until complete.
    /// Must be called once at startup. Safe to `await` from any context.
    func warmUpModel() async {
        stateLock.withLock { warmupState = .warming }
        logger.info("Model warmup started")

        let model = stateLock.withLock { transcriber }
        do {
            try await model.warmUp()
            stateLock.withLock { warmupState = .ready }
            logger.info("Model warmup completed successfully")
        } catch {
            stateLock.withLock { warmupState = .failed(error) }
            // Distinct failure log — model may still handle real transcriptions
            logger.error("Model warmup failed (will still attempt transcription): \(error)")
        }
    }

    /// Shut down the audio engine. Call from `applicationWillTerminate`.
    func shutdown() {
        audioCapture.shutdown()
    }

    /// Mark the model ready without running warmup. Used in tests and SWIFT_PACKAGE builds
    /// where warmup is not needed or not available.
    func skipWarmup() {
        stateLock.withLock { warmupState = .ready }
    }

    func selectedASRModelKind() -> ASRModelKind {
        stateLock.withLock { currentASRModelKind }
    }

    func switchASRModel(to kind: ASRModelKind) {
        guard let asrModelResolver, let transcriberFactory else {
            logger.error("Model switching requested without a transcriber factory")
            feedback.notify(event: .error("Model switching unavailable"))
            return
        }

        let start = stateLock.withLock { () -> ModelSwitchStart in
            guard currentASRModelKind != kind else {
                return .alreadySelected
            }

            guard activeModelSwitchID == nil else {
                return .reject("Model switching already in progress")
            }

            guard warmupState.isReady else {
                return .reject("Model warming up, please wait")
            }

            switch state {
            case .idle:
                let previousWarmupState = warmupState
                let switchID = UUID()
                activeModelSwitchID = switchID
                warmupState = .warming
                return .start(id: switchID, previousWarmupState: previousWarmupState)
            case .startingCapture:
                return .reject("Wait for microphone reconnection")
            case .recording:
                return .reject("Stop recording before switching models")
            case .transcribing:
                return .reject("Wait for transcription to finish")
            }
        }

        switch start {
        case .alreadySelected:
            return

        case .reject(let message):
            logger.info("Ignoring ASR model switch to \(kind.displayName): \(message)")
            feedback.notify(event: .error(message))

        case .start(let switchID, let previousWarmupState):
            Task.detached(priority: .userInitiated) { [asrModelResolver, transcriberFactory, modelArtifactVerifier] in
                let result: Result<(ASRModelConfiguration, Transcriber), Error>
                do {
                    let model = try await asrModelResolver(kind)
                    try modelArtifactVerifier(model)
                    let transcriber = try transcriberFactory(model)
                    try await transcriber.warmUp()
                    result = .success((model, transcriber))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async { [weak self] in
                    self?.completeASRModelSwitch(
                        id: switchID,
                        to: kind,
                        restoring: previousWarmupState,
                        result: result
                    )
                }
            }
        }
    }

    #if !SWIFT_PACKAGE
    @MainActor
    convenience init(feedback: UserFeedback) async throws {
        let (model, transcriber) = try await Task.detached(priority: .userInitiated) {
            let kind = try ModelPathResolver.configuredASRModelKind()
            let model = try await ASRModelInstaller().resolveOrInstall(kind: kind)
            let transcriber = try TranscribeCppTranscriber(model: model)
            return (model, transcriber)
        }.value

        let audioCapture = try AudioCapture(
            onLimitReached: { [feedback] in
                feedback.notify(event: .error("Recording limit reached (6 minutes)"))
            }
        )
        let paster = PasteboardPaster()
        let flash = ScreenEdgeFlash()
        let correctionStore = TranscriptCorrectionStore()
        let postProcessor = (try? TranscriptPostProcessor(corrections: correctionStore.allCorrections()))
            ?? TranscriptPostProcessor()

        let keyCode = CGKeyCode(kVK_ANSI_S)
        let requiredFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let forbiddenFlags: CGEventFlags = []
        let keyMonitorFactory: KeyMonitorFactory = { callback in
            KeyComboMonitor(
                keyCode: keyCode,
                requiredFlags: requiredFlags,
                forbiddenFlags: forbiddenFlags,
                callback: callback
            )
        }

        self.init(
            audioCapture: audioCapture,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            accessibilityChecker: SystemAccessibilityChecker(),
            asrModelKind: model.kind,
            asrModelResolver: {
                try await ASRModelInstaller().resolveOrInstall(kind: $0)
            },
            transcriberFactory: { try TranscribeCppTranscriber(model: $0) },
            modelSelectionStore: { ModelPathResolver.persistSelectedModelKind($0) },
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory,
            transcriptStore: TranscriptStore(),
            diagnosticsStore: DiagnosticsStore(),
            transcriptPostProcessor: postProcessor
        )
    }
    #endif

    // MARK: - State Machine
    //
    // Hotkey input advances the coordinator through a single linear recording
    // session: idle -> startingCapture -> recording -> transcribing(token) -> idle. The token
    // prevents timeout and transcription callbacks from completing stale work
    // after a later session has already moved the state forward.

    func toggleRecording() {
        let now = TranscriptionTrace.timestamp()

        let transition = stateLock.withLock { () -> Transition in
            guard warmupState.isReady else {
                return .blocked(
                    TranscriptionTrace(
                        hotkeyPressedAt: now,
                        backend: currentASRModelKind.preferenceValue
                    ),
                    "Model warming up, please wait"
                )
            }

            switch state {
            case .idle:
                state = .startingCapture
                return .start(
                    TranscriptionTrace(
                        hotkeyPressedAt: now,
                        backend: currentASRModelKind.preferenceValue
                    ),
                    deliveryTargetProvider.currentTarget()
                )
            case .startingCapture:
                return .ignore("Microphone reconnecting, please wait")
            case .recording:
                let token = UUID()
                state = .transcribing(token, didTimeOut: false)
                var trace = activeTrace ?? TranscriptionTrace(hotkeyPressedAt: now)
                trace.markHotkeyReleased(at: now)
                let target = activeDeliveryTarget ?? .unavailable
                activeTrace = nil
                activeDeliveryTarget = nil
                return .stop(token, trace, target)
            case .transcribing:
                return .ignore(nil)
            }
        }

        switch transition {
        case .start(var trace, let target):
            do {
                try audioCapture.beginRecording()
                trace.markCaptureStarted()
                let didStart = stateLock.withLock { () -> Bool in
                    guard case .startingCapture = state else {
                        return false
                    }
                    state = .recording
                    activeTrace = trace
                    activeDeliveryTarget = target
                    return true
                }
                guard didStart else {
                    return
                }

                Task { @MainActor [flash] in
                    flash.show(lineWidth: Self.flashLineWidth)
                }
            } catch {
                stateLock.withLock {
                    if case .startingCapture = state {
                        state = .idle
                    }
                    activeTrace = nil
                    activeDeliveryTarget = nil
                }
                logger.error("Recording start rejected: audio capture unavailable")
                feedback.notify(event: .error("Microphone reconnecting, try again shortly"))
            }

        case .stop(let token, let trace, let target):
            Task { @MainActor [flash] in
                flash.hide(completion: nil)
            }
            stopAndTranscribe(token: token, trace: trace, target: target)

        case .blocked(let trace, let message):
            recordTerminal(trace: trace, outcome: .warmupBlocked)
            feedback.notify(event: .error(message))

        case .ignore(let message):
            guard let message else {
                logger.debug("Ignoring hotkey while transcribing")
                return
            }
            logger.info("Ignoring hotkey: \(message, privacy: .public)")
            feedback.notify(event: .error(message))
        }
    }

    private func handleAudioCaptureEvent(_ event: AudioCaptureEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.applyAudioCaptureEvent(event)
        }
    }

    private func applyAudioCaptureEvent(_ event: AudioCaptureEvent) {
        dispatchPrecondition(condition: .onQueue(.main))

        switch event {
        case .recoveryStarted(let interruptedRecording):
            guard interruptedRecording else {
                feedback.notify(event: .status("Microphone reconnecting…"))
                return
            }

            let interruption = stateLock.withLock { () -> (shouldNotify: Bool, shouldHideFlash: Bool) in
                suppressRecoverySuccessStatus = true
                switch state {
                case .idle:
                    return (false, false)
                case .startingCapture:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return (true, false)
                case .recording:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return (true, true)
                case .transcribing:
                    // `endRecording()` still owns the capture buffers. Keep the
                    // token until its interrupted result releases that ownership.
                    return (false, false)
                }
            }
            guard interruption.shouldNotify else {
                return
            }
            if interruption.shouldHideFlash {
                MainActor.assumeIsolated {
                    flash.hide(completion: nil)
                }
            }
            logger.error("Recording interrupted by microphone configuration change")
            feedback.notify(event: .error("Recording interrupted by microphone change"))

        case .recoverySucceeded:
            let shouldNotify = stateLock.withLock { () -> Bool in
                let shouldNotify = !suppressRecoverySuccessStatus
                suppressRecoverySuccessStatus = false
                return shouldNotify
            }
            logger.info("Microphone reconnected")
            if shouldNotify {
                feedback.notify(event: .status("Microphone reconnected"))
            }

        case .recoveryFailed:
            stateLock.withLock {
                suppressRecoverySuccessStatus = false
                switch state {
                case .startingCapture, .recording:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                case .idle, .transcribing:
                    break
                }
            }
            logger.error("Microphone reconnection failed")
            feedback.notify(event: .error("Microphone reconnection failed"))
        }
    }

    private func stopAndTranscribe(
        token: UUID,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
        // `endRecording` blocks on a grace-window semaphore (up to ~220ms)
        // waiting for the trailing audio frame. Run it off-main so the UI
        // stays responsive during the wait.
        transcriptionQueue.async { [weak self] in
            guard let self else { return }
            let captureResult = self.audioCapture.endRecording()
            let rms = Self.rms(
                of: captureResult.samples,
                startingAt: captureResult.prependedSampleCount
            )
            DispatchQueue.main.async { [weak self] in
                self?.processCaptureResult(
                    token: token,
                    trace: trace,
                    captureResult: captureResult,
                    rms: rms,
                    target: target
                )
            }
        }
    }

    private func processCaptureResult(
        token: UUID,
        trace: TranscriptionTrace,
        captureResult: AudioCaptureResult,
        rms: Float,
        target: TranscriptDeliveryTarget
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let samples = captureResult.samples

        var trace = trace
        trace.markStopReturned(
            sampleCount: samples.count,
            prependedSampleCount: captureResult.prependedSampleCount,
            graceDurationMs: captureResult.graceDurationMs
        )

        guard !captureResult.wasInterrupted else {
            if finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .captureInterrupted)
                feedback.notify(event: .error("Recording interrupted by microphone change"))
            }
            return
        }

        guard !samples.isEmpty else {
            if finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .emptyAudio)
            }
            return
        }

        let activeSampleCount = max(0, samples.count - captureResult.prependedSampleCount)
        logger.info(
            "Audio stats: \(samples.count) samples (\(activeSampleCount) active, \(captureResult.prependedSampleCount) preroll), RMS=\(rms, format: .fixed(precision: 4))"
        )

        guard activeSampleCount >= Self.minActiveSamples else {
            logger.debug("Recording too short: \(activeSampleCount) active samples < \(Self.minActiveSamples) minimum")
            feedback.notify(event: .error("Recording too short"))
            if finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .noSpeech)
            }
            return
        }

        guard rms > Self.silenceRmsThreshold else {
            logger.debug("Audio below silence threshold: RMS \(rms) < \(Self.silenceRmsThreshold)")
            feedback.notify(event: .error("No speech detected"))
            if finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .noSpeech)
            }
            return
        }

        let timeout = transcriptionTimeoutProvider(samples)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTranscriptionTimeout(token: token, timeout: timeout, trace: trace)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        transcriptionQueue.async { [weak self] in
            guard let self else { return }

            trace.markTranscriptionStarted()
            let result: Result<String, Error>
            do {
                let transcriber = self.stateLock.withLock { self.transcriber }
                let text = try transcriber.transcribe(samples: samples)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            trace.markTranscriptionEnded()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                timeoutWorkItem.cancel()
                guard self.finishTranscription(token: token) else { return }

                switch result {
                case .success(let text):
                    self.handleTranscriptionResult(
                        text,
                        trace: trace,
                        activeDurationSeconds: Double(activeSampleCount) / Self.transcriptionSampleRate,
                        activeRMS: rms,
                        target: target
                    )
                case .failure(let error):
                    self.recordTerminal(trace: trace, outcome: .transcriptionFailed)
                    self.logger.error("Transcription failed: \(String(describing: error))")
                    self.feedback.notify(event: .error("Transcription failed"))
                }
            }
        }
    }

    private func handleTranscriptionResult(
        _ text: String,
        trace: TranscriptionTrace,
        activeDurationSeconds: TimeInterval? = nil,
        activeRMS: Float? = nil,
        target: TranscriptDeliveryTarget = .unavailable
    ) {
        let trace = trace
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recordTerminal(trace: trace, outcome: .noSpeech)
            feedback.notify(event: .error("No speech detected"))
            return
        }

        let hallucinationVerdict = hallucinationFilter.verdict(
            for: trimmed,
            activeDurationSeconds: activeDurationSeconds,
            activeRMS: activeRMS
        )
        if case .rejected(let reason) = hallucinationVerdict {
            logger.debug("Filtered transcript degeneration: \(String(describing: reason))")
            recordTerminal(trace: trace, outcome: .noSpeech)
            feedback.notify(event: .error("No speech detected"))
            return
        }

        let processedTranscript = transcriptPostProcessor.process(trimmed)
        let record = TranscriptRecord(
            id: trace.id,
            rawText: processedTranscript.rawText,
            finalText: processedTranscript.finalText,
            backend: trace.backend,
            outcome: .transcriptPersisted,
            timings: trace.timingSnapshot
        )

        guard let transcriptStore else {
            deliverPersistedTranscript(
                processedTranscript,
                trace: trace,
                recordID: nil,
                target: target
            )
            return
        }

        let persistence = MainActor.assumeIsolated {
            transcriptStore.append(record)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await persistence.value else {
                self.logger.error("Transcript could not be persisted; skipping paste")
                self.recordTerminal(
                    trace: trace,
                    outcome: .transcriptPersistenceFailed,
                    text: processedTranscript.finalText
                )
                self.feedback.notify(event: .error("Transcript could not be saved"))
                return
            }
            self.deliverPersistedTranscript(
                processedTranscript,
                trace: trace,
                recordID: record.id,
                target: target
            )
        }
    }

    @discardableResult
    private func deliverPersistedTranscript(
        _ transcript: ProcessedTranscript,
        trace: TranscriptionTrace,
        recordID: UUID?,
        target: TranscriptDeliveryTarget
    ) -> TranscriptDeliveryOutcome? {
        let text = transcript.finalText
        guard accessibilityChecker.hasAccessibilityAccess() else {
            recordTerminal(trace: trace, outcome: .accessibilityDenied, text: text)
            if let recordID {
                MainActor.assumeIsolated {
                    _ = transcriptStore?.update(
                        id: recordID,
                        outcome: .accessibilityDenied,
                        timings: trace.timingSnapshot
                    )
                }
            }
            logger.error("Accessibility permission missing")
            feedback.notify(event: .error("Accessibility permission required"))
            return nil
        }

        var trace = trace
        trace.markPasteRequested()
        let outcome = paster.paste(text, target: target)
        recordTerminal(trace: trace, outcome: outcome.traceOutcome, text: text)
        if let recordID {
            MainActor.assumeIsolated {
                _ = transcriptStore?.update(
                    id: recordID,
                    outcome: outcome.traceOutcome,
                    timings: trace.timingSnapshot
                )
            }
        }

        notifyDeliveryOutcome(outcome, operation: .paste, target: target)
        return outcome
    }

    /// Copy the newest retained transcript without invoking ASR.
    @MainActor
    @discardableResult
    func copyLastTranscript() -> TranscriptDeliveryOutcome? {
        guard let text = lastTranscript() else {
            feedback.notify(event: .error("No transcript available"))
            return nil
        }

        let outcome = paster.copy(text)
        notifyDeliveryOutcome(outcome, operation: .copy, target: nil)
        return outcome
    }

    /// Post a new paste request for the newest transcript without retranscribing it.
    @MainActor
    @discardableResult
    func pasteLastTranscript() -> TranscriptDeliveryOutcome? {
        guard let text = lastTranscript() else {
            feedback.notify(event: .error("No transcript available"))
            return nil
        }

        return pasteTranscript(
            text,
            operation: .pasteLast,
            target: deliveryTargetProvider.currentTarget()
        )
    }

    /// Paste a stored transcript without invoking ASR. Used for history rows
    /// and by the explicit last-transcript recovery action.
    @MainActor
    @discardableResult
    func pasteTranscript(_ text: String) -> TranscriptDeliveryOutcome? {
        pasteTranscript(
            text,
            operation: .pasteLast,
            target: deliveryTargetProvider.currentTarget()
        )
    }

    @discardableResult
    @MainActor
    private func pasteTranscript(
        _ text: String,
        operation: DeliveryOperation,
        target: TranscriptDeliveryTarget
    ) -> TranscriptDeliveryOutcome? {
        guard accessibilityChecker.hasAccessibilityAccess() else {
            logger.error("Accessibility permission missing for last transcript")
            feedback.notify(event: .error("Accessibility permission required"))
            return nil
        }

        let outcome = paster.paste(text, target: target)
        notifyDeliveryOutcome(outcome, operation: operation, target: target)
        return outcome
    }

    private enum DeliveryOperation {
        case copy
        case paste
        case pasteLast
    }

    @MainActor
    private func lastTranscript() -> String? {
        transcriptStore?.allEntries().last
    }

    private func notifyDeliveryOutcome(
        _ outcome: TranscriptDeliveryOutcome,
        operation: DeliveryOperation,
        target: TranscriptDeliveryTarget?
    ) {
        switch (operation, outcome) {
        case (.copy, .clipboardUpdated):
            feedback.notify(event: .status("Last transcript copied"))
        case (.pasteLast, .eventsPosted):
            feedback.notify(event: .status("Paste events posted"))
        case (_, .clipboardWriteFailed):
            feedback.notify(event: .error("Could not update clipboard"))
        case (.paste, .clipboardUpdated), (.pasteLast, .clipboardUpdated):
            if case .external = target {
                feedback.notify(event: .error("Clipboard updated, but paste could not be posted"))
            } else {
                feedback.notify(event: .status("Transcript copied; no external paste target"))
            }
        case (.copy, .eventsPosted):
            // Copy operations do not post events, but handle this defensively
            // if another Pasting implementation returns a broader outcome.
            feedback.notify(event: .status("Last transcript copied"))
        case (.paste, .eventsPosted):
            break
        }
    }

    /// Returns whether the completed result is still eligible for delivery.
    /// A timed-out native inference cannot be cancelled, so it keeps ownership
    /// of the serial worker until it returns; only then does the app become idle.
    @discardableResult
    private func finishTranscription(token: UUID) -> Bool {
        stateLock.withLock {
            guard case let .transcribing(current, didTimeOut) = state,
                  current == token else {
                return false
            }

            state = .idle
            return !didTimeOut
        }
    }

    private func handleTranscriptionTimeout(token: UUID, timeout: TimeInterval, trace: TranscriptionTrace) {
        let shouldNotify = stateLock.withLock { () -> Bool in
            guard case let .transcribing(current, didTimeOut) = state,
                  current == token,
                  !didTimeOut else {
                return false
            }

            state = .transcribing(current, didTimeOut: true)
            return true
        }

        guard shouldNotify else { return }

        recordTerminal(trace: trace, outcome: .timedOut)
        logger.error("Transcription timed out after \(timeout)s")
        feedback.notify(event: .error("Transcription timed out"))
    }

    private func recordTerminal(
        trace: TranscriptionTrace,
        outcome: TranscriptionTrace.Outcome,
        text: String? = nil
    ) {
        trace.log(logger: logger, outcome: outcome)
        MainActor.assumeIsolated {
            _ = diagnosticsStore?.record(trace: trace, outcome: outcome, text: text)
        }
    }

    private func completeASRModelSwitch(
        id switchID: UUID,
        to kind: ASRModelKind,
        restoring previousWarmupState: WarmupState,
        result: Result<(ASRModelConfiguration, Transcriber), Error>
    ) {
        switch result {
        case .success(let (model, newTranscriber)):
            let previousTranscriber = stateLock.withLock { () -> Transcriber? in
                guard activeModelSwitchID == switchID,
                      case .idle = state else {
                    return nil
                }

                let previousTranscriber = transcriber
                transcriber = newTranscriber
                currentASRModelKind = kind
                warmupState = .ready
                activeModelSwitchID = nil
                return previousTranscriber
            }

            guard let previousTranscriber else {
                logger.info("Ignoring stale ASR model switch to \(kind.displayName)")
                return
            }

            transcriptionQueue.async {
                withExtendedLifetime(previousTranscriber) {}
            }
            modelSelectionStore(kind)
            logger.info("Switched ASR model to \(kind.displayName) at \(model.url.path)")

        case .failure(let error):
            failASRModelSwitch(
                id: switchID,
                to: kind,
                restoring: previousWarmupState,
                error: error
            )
        }
    }

    private func failASRModelSwitch(
        id switchID: UUID,
        to kind: ASRModelKind,
        restoring previousWarmupState: WarmupState,
        error: Error
    ) {
        let didRestore = stateLock.withLock { () -> Bool in
            guard activeModelSwitchID == switchID else {
                return false
            }

            guard case .idle = state else {
                return false
            }
            activeModelSwitchID = nil
            warmupState = previousWarmupState
            return true
        }
        guard didRestore else {
            logger.info("Ignoring stale failed ASR model switch to \(kind.displayName)")
            return
        }

        logger.error("Failed to switch ASR model to \(kind.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
        feedback.notify(event: .error("Failed to switch audio model"))
    }

    private static func defaultTranscriptionTimeout(
        samples: ContiguousArray<Float>
    ) -> TimeInterval {
        let duration = Double(samples.count) / transcriptionSampleRate
        let scaled = max(duration * 2, minTranscriptionTimeout)
        return min(scaled, maxTranscriptionTimeout)
    }

    private static func rms(of samples: ContiguousArray<Float>, startingAt start: Int = 0) -> Float {
        let clampedStart = min(max(start, 0), samples.count)
        let sampleCount = samples.count - clampedStart
        guard sampleCount > 0 else { return 0 }
        var sumSquares: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer[clampedStart...] {
                sumSquares += sample * sample
            }
        }
        return (sumSquares / Float(sampleCount)).squareRoot()
    }
}
