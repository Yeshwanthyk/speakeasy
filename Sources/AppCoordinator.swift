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
    func flash(duration: TimeInterval, lineWidth: CGFloat)
}

protocol AccessibilityChecking {
    func ensureAccessibilityPrompted() -> Bool
}

typealias KeyMonitorFactory = (_ callback: @escaping () -> Void) -> KeyComboMonitor?

extension AudioCapture: AudioCapturing {}
extension ScreenEdgeFlash: Flashing {}

struct SystemAccessibilityChecker: AccessibilityChecking {
    func ensureAccessibilityPrompted() -> Bool {
        Permissions.ensureAccessibilityPrompted()
    }
}

final class AppCoordinator {
    private enum State {
        case idle
        case recording
        case transcribing(UUID)
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

    private static let flashLineWidth: CGFloat = 3
    private static let transcriptionSampleRate: Double = 16_000
    private static let minTranscriptionTimeout: TimeInterval = 30
    private static let maxTranscriptionTimeout: TimeInterval = 600
    /// Minimum active (non-preroll) samples required. 4800 = 300ms at 16kHz.
    private static let minActiveSamples = 4_800
    /// RMS below this threshold is treated as silence.
    private static let silenceRmsThreshold: Float = 0.005
    /// Known Parakeet TDT hallucinations on silent/near-silent audio.
    private static let hallucinationPatterns: Set<String> = [
        "yeah", "yeah.", "yes", "yes.", "okay", "okay.", "ok", "ok.",
        "uh-huh", "uh-huh.", "mhm", "mhm.", "hmm", "hmm.", "huh", "huh.",
        "oh", "oh.", "ah", "ah.", "uh", "uh.", "um", "um.",
        "bye", "bye.", "no", "no.", "so", "so.", "right", "right.",
    ]

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private let audioCapture: AudioCapturing
    private let transcriber: Transcriber
    let paster: Pasting
    let transcriptStore: TranscriptStore?
    private let feedback: UserFeedback
    private let accessibilityChecker: AccessibilityChecking
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private var warmupState: WarmupState = .pending
    /// Partial trace built during a recording session; nil when idle or transcribing.
    private var activeTrace: TranscriptionTrace?
    private let transcriptionQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInteractive)
    private let flash: Flashing
    private var keyMonitor: KeyComboMonitor?

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
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?,
        transcriptStore: TranscriptStore? = nil
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.paster = paster
        self.flash = flash
        self.feedback = feedback
        self.accessibilityChecker = accessibilityChecker
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider
        self.transcriptStore = transcriptStore

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

        do {
            try await transcriber.warmUp()
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

    #if !SWIFT_PACKAGE
    @MainActor
    convenience init() throws {
        let modelPath = try ModelPathResolver.parakeetV3Path()
        let feedback = SystemFeedback()
        let audioCapture = try AudioCapture(
            onLimitReached: { [feedback] in
                feedback.error("Recording limit reached (6 minutes)")
            }
        )
        let transcriber = try ParakeetTranscriber(modelPath: modelPath)
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
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory,
            transcriptStore: TranscriptStore()
        )
    }
    #endif

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
                state = .transcribing(token)
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
                    feedback.error("Model warming up, please wait")
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
            DispatchQueue.main.async { [weak self] in
                self?.processCaptureResult(
                    token: token,
                    trace: trace,
                    captureResult: captureResult
                )
            }
        }
    }

    private func processCaptureResult(
        token: UUID,
        trace: TranscriptionTrace,
        captureResult: AudioCaptureResult
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
            finishTranscription(token: token)
            return
        }

        let activeSampleCount = samples.count - captureResult.prependedSampleCount
        let rms = Self.rms(of: samples)
        logger.info(
            "Audio stats: \(samples.count) samples (\(activeSampleCount) active, \(captureResult.prependedSampleCount) preroll), RMS=\(rms, format: .fixed(precision: 4))"
        )

        guard activeSampleCount >= Self.minActiveSamples else {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Recording too short: \(activeSampleCount) active samples < \(Self.minActiveSamples) minimum")
            feedback.error("Recording too short")
            finishTranscription(token: token)
            return
        }

        guard rms > Self.silenceRmsThreshold else {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Audio below silence threshold: RMS \(rms) < \(Self.silenceRmsThreshold)")
            feedback.error("No speech detected")
            finishTranscription(token: token)
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
                let text = try self.transcriber.transcribe(samples: samples)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            trace.markTranscriptionEnded()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isCurrentTranscription(token: token) else { return }

                timeoutWorkItem.cancel()
                self.finishTranscription(token: token)

                switch result {
                case .success(let text):
                    self.handleTranscriptionResult(text, trace: trace)
                case .failure(let error):
                    trace.log(logger: self.logger, outcome: .transcriptionFailed)
                    self.logger.error("Transcription failed: \(String(describing: error))")
                    self.feedback.error("Transcription failed")
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String, trace: TranscriptionTrace) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trace.log(logger: logger, outcome: .noSpeech)
            feedback.error("No speech detected")
            return
        }

        if Self.hallucinationPatterns.contains(trimmed.lowercased()) {
            trace.log(logger: logger, outcome: .noSpeech)
            logger.debug("Filtered likely hallucination: '\(trimmed)'")
            feedback.error("No speech detected")
            return
        }

        guard accessibilityChecker.ensureAccessibilityPrompted() else {
            trace.log(logger: logger, outcome: .accessibilityDenied)
            logger.error("Accessibility permission missing")
            feedback.error("Accessibility permission required")
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

    private func isCurrentTranscription(token: UUID) -> Bool {
        stateLock.withLock {
            if case let .transcribing(current) = state {
                return current == token
            }
            return false
        }
    }

    private func finishTranscription(token: UUID) {
        stateLock.withLock {
            if case let .transcribing(current) = state, current == token {
                state = .idle
            }
        }
    }

    private func handleTranscriptionTimeout(token: UUID, timeout: TimeInterval, trace: TranscriptionTrace) {
        let shouldNotify = stateLock.withLock { () -> Bool in
            if case let .transcribing(current) = state, current == token {
                state = .idle
                return true
            }
            return false
        }

        guard shouldNotify else { return }

        trace.log(logger: logger, outcome: .timedOut)
        logger.error("Transcription timed out after \(timeout)s")
        feedback.error("Transcription timed out")
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
