import Carbon
import CoreGraphics
import Foundation
import os

protocol AudioCapturing {
    /// Arm the engine at startup. Must be called before `beginRecording()`.
    func prepare() throws
    /// Begin accumulating audio into buffers.
    func beginRecording()
    /// Stop accumulating; flush and return all captured samples plus capture metadata.
    func endRecording() -> AudioCaptureResult
    /// Stop the engine entirely. Call at app termination.
    func shutdown()
}

protocol Pasting {
    func paste(_ text: String)
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
        case start
        case stop(UUID, TranscriptionTrace)
        case ignore
    }

    private enum ModelSwitchStart {
        case start(previousWarmupState: WarmupState)
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
    private let feedback: UserFeedback
    private let accessibilityChecker: AccessibilityChecking
    private let hallucinationFilter: HallucinationFilter
    private var currentASRModelKind: ASRModelKind
    private let asrModelResolver: ASRModelResolver?
    private let transcriberFactory: TranscriberFactory?
    private let modelSelectionStore: ASRModelSelectionStore
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private var warmupState: WarmupState = .pending
    /// Partial trace built during a recording session; nil when idle or transcribing.
    private var activeTrace: TranscriptionTrace?
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

    #if DEBUG
    private let debugSummary = TranscriptionDebugSummary()
    #endif

    init(
        audioCapture: AudioCapturing,
        transcriber: Transcriber,
        paster: Pasting,
        flash: Flashing,
        feedback: UserFeedback,
        accessibilityChecker: AccessibilityChecking,
        hallucinationFilter: HallucinationFilter = HallucinationFilter(),
        asrModelKind: ASRModelKind = .parakeetTDT,
        asrModelResolver: ASRModelResolver? = nil,
        transcriberFactory: TranscriberFactory? = nil,
        modelSelectionStore: @escaping ASRModelSelectionStore = { _ in },
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?,
        transcriptStore: TranscriptStore? = nil,
        transcriptionQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInteractive)
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.paster = paster
        self.flash = flash
        self.feedback = feedback
        self.accessibilityChecker = accessibilityChecker
        self.hallucinationFilter = hallucinationFilter
        self.currentASRModelKind = asrModelKind
        self.asrModelResolver = asrModelResolver
        self.transcriberFactory = transcriberFactory
        self.modelSelectionStore = modelSelectionStore
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider
        self.transcriptStore = transcriptStore
        self.transcriptionQueue = transcriptionQueue

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

            guard warmupState.isReady else {
                return .reject("Model warming up, please wait")
            }

            switch state {
            case .idle:
                let previousWarmupState = warmupState
                warmupState = .warming
                return .start(previousWarmupState: previousWarmupState)
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

        case .start(let previousWarmupState):
            Task(priority: .userInitiated) { [weak self] in
                let result: Result<(ASRModelConfiguration, Transcriber), Error>
                do {
                    let model = try await asrModelResolver(kind)
                    let transcriber = try transcriberFactory(model)
                    result = .success((model, transcriber))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async { [weak self] in
                    self?.completeASRModelSwitch(
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
    convenience init() async throws {
        let (model, transcriber) = try await Task.detached(priority: .userInitiated) {
            let model = try ModelPathResolver.configuredASRModel()
            let transcriber = try ParakeetTranscriber(model: model)
            return (model, transcriber)
        }.value

        let feedback = SystemFeedback()
        let audioCapture = try AudioCapture(
            onLimitReached: { [feedback] in
                feedback.notify(event: .error("Recording limit reached (6 minutes)"))
            }
        )
        let paster = PasteboardPaster(feedback: feedback)
        let flash = ScreenEdgeFlash()

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
            transcriberFactory: { try ParakeetTranscriber(model: $0) },
            modelSelectionStore: { ModelPathResolver.persistSelectedModelKind($0) },
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory,
            transcriptStore: TranscriptStore()
        )
    }
    #endif

    // MARK: - State Machine
    //
    // Hotkey input advances the coordinator through a single linear recording
    // session: idle -> recording -> transcribing(token) -> idle. The token
    // prevents timeout and transcription callbacks from completing stale work
    // after a later session has already moved the state forward.

    func toggleRecording() {
        let now = TranscriptionTrace.timestamp()

        let transition = stateLock.withLock { () -> Transition in
            // Block hotkey until model warmup finishes
            guard warmupState.isReady else {
                return .ignore
            }

            switch state {
            case .idle:
                state = .recording
                activeTrace = TranscriptionTrace(hotkeyPressedAt: now)
                return .start
            case .recording:
                let token = UUID()
                state = .transcribing(token, didTimeOut: false)
                var trace = activeTrace ?? TranscriptionTrace(hotkeyPressedAt: now)
                trace.markHotkeyReleased(at: now)
                activeTrace = nil
                return .stop(token, trace)
            case .transcribing:
                return .ignore
            }
        }

        switch transition {
        case .start:
            Task { @MainActor [flash] in
                flash.show(lineWidth: Self.flashLineWidth)
            }
            audioCapture.beginRecording()
            // Record actual beginRecording return time
            let captureStarted = TranscriptionTrace.timestamp()
            stateLock.withLock { activeTrace?.markCaptureStarted(at: captureStarted) }

        case .stop(let token, let trace):
            Task { @MainActor [flash] in
                flash.hide(completion: nil)
            }
            stopAndTranscribe(token: token, trace: trace)

        case .ignore:
            let ws = stateLock.withLock { warmupState }
            switch ws {
            case .pending, .warming:
                logger.info("Ignoring hotkey: model warmup in progress")
                DispatchQueue.main.async { [feedback] in
                    feedback.notify(event: .error("Model warming up, please wait"))
                }
            default:
                logger.debug("Ignoring hotkey while transcribing")
            }
        }
    }

    private func stopAndTranscribe(token: UUID, trace: TranscriptionTrace) {
        // `endRecording` blocks on a grace-window semaphore (up to ~220ms)
        // waiting for the trailing audio frame. Run it off-main so the UI
        // stays responsive during the wait.
        transcriptionQueue.async { [weak self] in
            guard let self else { return }
            let captureResult = self.audioCapture.endRecording()
            let rms = Self.rms(of: captureResult.samples)
            DispatchQueue.main.async { [weak self] in
                self?.processCaptureResult(
                    token: token,
                    trace: trace,
                    captureResult: captureResult,
                    rms: rms
                )
            }
        }
    }

    private func processCaptureResult(
        token: UUID,
        trace: TranscriptionTrace,
        captureResult: AudioCaptureResult,
        rms: Float
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let samples = captureResult.samples

        var trace = trace
        trace.markStopReturned(
            sampleCount: samples.count,
            prependedSampleCount: captureResult.prependedSampleCount,
            graceDurationMs: captureResult.graceDurationMs
        )

        guard !samples.isEmpty else {
            trace.log(logger: logger, outcome: .emptyAudio)
            _ = finishTranscription(token: token)
            return
        }

        let activeSampleCount = samples.count - captureResult.prependedSampleCount
        logger.info(
            "Audio stats: \(samples.count) samples (\(activeSampleCount) active, \(captureResult.prependedSampleCount) preroll), RMS=\(rms, format: .fixed(precision: 4))"
        )

        guard activeSampleCount >= Self.minActiveSamples else {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Recording too short: \(activeSampleCount) active samples < \(Self.minActiveSamples) minimum")
            feedback.notify(event: .error("Recording too short"))
            _ = finishTranscription(token: token)
            return
        }

        guard rms > Self.silenceRmsThreshold else {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Audio below silence threshold: RMS \(rms) < \(Self.silenceRmsThreshold)")
            feedback.notify(event: .error("No speech detected"))
            _ = finishTranscription(token: token)
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
                    self.handleTranscriptionResult(text, trace: trace)
                case .failure(let error):
                    trace.log(logger: self.logger, outcome: .transcriptionFailed)
                    self.logger.error("Transcription failed: \(String(describing: error))")
                    self.feedback.notify(event: .error("Transcription failed"))
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String, trace: TranscriptionTrace) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trace.log(logger: logger, outcome: .noSpeech)
            feedback.notify(event: .error("No speech detected"))
            return
        }

        if hallucinationFilter.isLikelyHallucination(trimmed) {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Filtered likely hallucination: '\(trimmed)'")
            feedback.notify(event: .error("No speech detected"))
            return
        }

        guard accessibilityChecker.hasAccessibilityAccess() else {
            trace.log(logger: logger, outcome: .accessibilityDenied)
            logger.error("Accessibility permission missing")
            feedback.notify(event: .error("Accessibility permission required"))
            return
        }

        var trace = trace
        trace.markPasteRequested()
        trace.log(logger: logger, outcome: .pasted, textLength: trimmed.count)

        #if DEBUG
        if let summary = debugSummary.record(trace: trace) {
            logger.debug("\(summary)")
        }
        #endif

        MainActor.assumeIsolated {
            transcriptStore?.append(trimmed)
        }
        paster.paste(trimmed)
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

        trace.log(logger: logger, outcome: .timedOut)
        logger.error("Transcription timed out after \(timeout)s")
        feedback.notify(event: .error("Transcription timed out"))
    }

    private func completeASRModelSwitch(
        to kind: ASRModelKind,
        restoring previousWarmupState: WarmupState,
        result: Result<(ASRModelConfiguration, Transcriber), Error>
    ) {
        switch result {
        case .success(let (model, newTranscriber)):
            let previousTranscriber = stateLock.withLock {
                let previousTranscriber = transcriber
                transcriber = newTranscriber
                currentASRModelKind = kind
                return previousTranscriber
            }
            transcriptionQueue.async {
                withExtendedLifetime(previousTranscriber) {}
            }
            modelSelectionStore(kind)
            logger.info("Switched ASR model to \(kind.displayName) at \(model.url.path)")
            Task { [weak self] in
                await self?.warmUpModel()
            }

        case .failure(let error):
            failASRModelSwitch(to: kind, restoring: previousWarmupState, error: error)
        }
    }

    private func failASRModelSwitch(
        to kind: ASRModelKind,
        restoring previousWarmupState: WarmupState,
        error: Error
    ) {
        stateLock.withLock { warmupState = previousWarmupState }
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

    private static func rms(of samples: ContiguousArray<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer {
                sumSquares += sample * sample
            }
        }
        return (sumSquares / Float(samples.count)).squareRoot()
    }
}
