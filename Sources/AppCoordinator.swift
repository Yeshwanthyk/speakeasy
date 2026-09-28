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
    /// Stop accumulating and discard the active recording without flushing audio.
    func discardRecording()
    /// Stop the engine entirely. Call at app termination.
    func shutdown()
    func availableInputDevices() -> [MicrophoneDevice]
    func selectedInputDeviceUID() -> String?
    func selectInputDevice(uid: String)
    func microphoneLevelSnapshot() -> MicrophoneLevelSnapshot
    /// Buffered audio for live-preview re-transcription; implementations
    /// without preview support return an empty buffer.
    func livePreviewSamples() -> ContiguousArray<Float>
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

protocol AccessibilityChecking {
    func hasAccessibilityAccess() -> Bool
}

typealias KeyMonitorFactory = (_ callback: @escaping (DictationIntent) -> Void) -> DictationKeyMonitoring?
typealias ASRModelResolver = (_ kind: ASRModelKind) async throws -> ASRModelConfiguration
typealias TranscriberFactory = (_ model: ASRModelConfiguration) throws -> Transcriber
typealias ASRModelArtifactVerifier = (_ model: ASRModelConfiguration) throws -> Void
typealias ASRModelSelectionStore = (_ kind: ASRModelKind) -> Void
typealias InputDeviceSelectionStore = (_ uid: String) -> Void
typealias DictationShortcutSelectionStore = (_ shortcut: DictationShortcut) -> Void

enum TranscriptCorrectionUpdateError: Error, Equatable {
    case storeUnavailable
}

extension AudioCapture: AudioCapturing {}

struct SystemAccessibilityChecker: AccessibilityChecking {
    func hasAccessibilityAccess() -> Bool {
        Permissions.hasAccessibilityAccess()
    }
}

final class AppCoordinator: @unchecked Sendable {
    private enum State {
        case idle
        case startingCapture(UUID)
        case recording
        case transcribing(UUID, runID: UInt64, didTimeOut: Bool, didCancel: Bool)
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
        case start(UUID, TranscriptionTrace, TranscriptDeliveryTarget)
        case stop(UUID, UInt64, TranscriptionTrace, TranscriptDeliveryTarget)
        case discardCapture(TranscriptionTrace?, notify: Bool)
        case cancelTranscription(UInt64, TranscriptionTrace)
        case blocked(TranscriptionTrace, String)
        case ignore(String?)
    }

    private enum TranscriptionSettlement: Equatable {
        case eligible
        case timedOut
        case cancelled
        case stale
    }

    private enum RecordingFeedbackTransition {
        case recording
        case processing
        case hidden
    }

    private enum ModelSwitchStart {
        case start(id: UUID, previousWarmupState: WarmupState)
        case alreadySelected
        case reject(String)
    }

    private static let transcriptionSampleRate: Double = 16_000
    private static let minTranscriptionTimeout: TimeInterval = 30
    private static let maxTranscriptionTimeout: TimeInterval = 600
    /// Minimum active (non-preroll) samples required. 4800 = 300ms at 16kHz.
    private static let minActiveSamples = 4_800

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private let audioCapture: AudioCapturing
    private var transcriber: Transcriber
    let paster: Pasting
    let transcriptStore: TranscriptStore?
    let diagnosticsStore: DiagnosticsStore?
    /// Persistent keyboard-to-insertion latency log; nil disables tracing.
    private let e2eTraceStore: E2ETraceStore?
    private let feedback: UserFeedback
    private let accessibilityChecker: AccessibilityChecking
    private let deliveryTargetProvider: DeliveryTargetProviding
    private let hallucinationFilter: HallucinationFilter
    private var transcriptPostProcessor: TranscriptPostProcessor
    /// Optional post-correction refinement stage; nil means no polish step.
    private let textPolisher: TextPolishing?
    private let transcriptCorrectionStore: TranscriptCorrectionStore?
    private var currentASRModelKind: ASRModelKind
    private let asrModelResolver: ASRModelResolver?
    private let transcriberFactory: TranscriberFactory?
    private let modelArtifactVerifier: ASRModelArtifactVerifier
    private let modelSelectionStore: ASRModelSelectionStore
    private let inputDeviceSelectionStore: InputDeviceSelectionStore
    private let shortcutSelectionStore: DictationShortcutSelectionStore
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    private static func continuousNanoseconds() -> UInt64 {
        let ticks = mach_continuous_time()
        let denominator = UInt64(timebase.denom)
        return ticks / denominator * UInt64(timebase.numer)
            + ticks % denominator * UInt64(timebase.numer) / denominator
    }

    private let nativeClock: @Sendable () -> UInt64
    private let rewarmThresholdNs: UInt64
    private var lastNativeInferenceAt: UInt64?
    private var rewarmRunID: UInt64?
    private var rewarmIsRunning = false
    private let rewarmQueue = DispatchQueue(label: "com.speakeasy.app.rewarm", qos: .userInteractive)
    private let failedCaptureReplayBuffer: FailedCaptureReplayBuffer
    private let stateLock = UnfairLock()
    private let intentLock = UnfairLock()
    private var state: State = .idle
    private var nextTranscriptionID: UInt64 = 0
    private var warmupState: WarmupState = .pending
    private var activeModelSwitchID: UUID?
    private var activeInputDeviceSwitchUID: String?
    private var suppressRecoverySuccessStatus = false
    /// Partial trace built during a recording session; nil when idle or transcribing.
    private var activeTrace: TranscriptionTrace?
    /// Trace retained while native work is settling so user cancellation can
    /// record the terminal outcome before the completion callback arrives.
    private var activeTranscriptionTrace: TranscriptionTrace?
    /// Owns a replay lease while a retry's native call is settling.
    private var activeReplayLease: FailedCaptureReplayBuffer.Lease?
    private var isShuttingDown = false
    /// Target captured before automatic recording starts. Recovery actions do
    /// not use this value; they resolve a fresh external target.
    private var activeDeliveryTarget: TranscriptDeliveryTarget?
    private var invocationMode: DictationInvocationMode = .toggle
    private var dictationShortcut: DictationShortcut
    private let transcriptionQueue: DispatchQueue
    /// Live preview scheduling/state for the active recording; nil disables.
    private let livePreviewController: LivePreviewController?
    /// Serial queue for preview inference; separate from transcriptionQueue
    /// so a settling preview never blocks finalization bookkeeping.
    private let previewQueue = DispatchQueue(label: "com.speakeasy.app.live-preview", qos: .utility)
    private var previewTimer: DispatchSourceTimer?
    /// Latest adopted preview text, published for UI/tests.
    private(set) var livePreviewText: String?
    /// Callback fired on main when an adopted preview replaces the previous.
    var onLivePreviewTextChange: ((String) -> Void)?
    private let recordingFeedback: RecordingFeedbackPresenting
    private var recordingFeedbackGeneration: UInt64 = 0
    private var keyMonitor: DictationKeyMonitoring?

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
        recordingFeedback: RecordingFeedbackPresenting,
        feedback: UserFeedback,
        accessibilityChecker: AccessibilityChecking,
        hallucinationFilter: HallucinationFilter = HallucinationFilter(),
        asrModelKind: ASRModelKind = .parakeet110M,
        asrModelResolver: ASRModelResolver? = nil,
        transcriberFactory: TranscriberFactory? = nil,
        modelArtifactVerifier: @escaping ASRModelArtifactVerifier = { model in
            try ModelPathResolver.verifyModelArtifact(kind: model.kind, at: model.url)
        },
        modelSelectionStore: @escaping ASRModelSelectionStore = { _ in },
        inputDeviceSelectionStore: @escaping InputDeviceSelectionStore = { _ in },
        dictationShortcut: DictationShortcut = .defaultShortcut,
        shortcutSelectionStore: @escaping DictationShortcutSelectionStore = { _ in },
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?,
        transcriptStore: TranscriptStore? = nil,
        diagnosticsStore: DiagnosticsStore? = nil,
        e2eTraceStore: E2ETraceStore? = nil,
        transcriptPostProcessor: TranscriptPostProcessor = TranscriptPostProcessor(),
        textPolisher: TextPolishing? = nil,
        livePreviewController: LivePreviewController? = nil,
        transcriptCorrectionStore: TranscriptCorrectionStore? = nil,
        transcriptionQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInteractive),
        deliveryTargetProvider: DeliveryTargetProviding = SystemDeliveryTargetProvider(),
        failedCaptureReplayBuffer: FailedCaptureReplayBuffer = FailedCaptureReplayBuffer(),
        nativeClock: @escaping @Sendable () -> UInt64 = { AppCoordinator.continuousNanoseconds() },
        rewarmThreshold: TimeInterval = 90
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.paster = paster
        self.recordingFeedback = recordingFeedback
        self.feedback = feedback
        self.accessibilityChecker = accessibilityChecker
        self.deliveryTargetProvider = deliveryTargetProvider
        self.hallucinationFilter = hallucinationFilter
        self.transcriptPostProcessor = transcriptPostProcessor
        self.textPolisher = textPolisher
        self.e2eTraceStore = e2eTraceStore
        self.livePreviewController = livePreviewController
        self.transcriptCorrectionStore = transcriptCorrectionStore
        self.currentASRModelKind = asrModelKind
        self.asrModelResolver = asrModelResolver
        self.transcriberFactory = transcriberFactory
        self.modelArtifactVerifier = modelArtifactVerifier
        self.modelSelectionStore = modelSelectionStore
        self.inputDeviceSelectionStore = inputDeviceSelectionStore
        self.dictationShortcut = dictationShortcut
        self.shortcutSelectionStore = shortcutSelectionStore
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider
        self.failedCaptureReplayBuffer = failedCaptureReplayBuffer
        self.transcriptStore = transcriptStore
        self.diagnosticsStore = diagnosticsStore
        self.transcriptionQueue = transcriptionQueue
        self.nativeClock = nativeClock
        self.rewarmThresholdNs = UInt64(max(0, rewarmThreshold) * 1_000_000_000)

        audioCapture.setEventHandler { [weak self] event in
            self?.handleAudioCaptureEvent(event)
        }

        keyMonitor = keyMonitorFactory? { [weak self] intent in
            self?.handle(intent)
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
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Speakeasy model warmup")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            try await model.warmUp()
            stateLock.withLock {
                lastNativeInferenceAt = nativeClock()
                warmupState = .ready
            }
            logger.info("Model warmup completed successfully")
        } catch {
            stateLock.withLock { warmupState = .failed(error) }
            // Distinct failure log — model may still handle real transcriptions
            logger.error("Model warmup failed (will still attempt transcription): \(error)")
        }
    }

    /// Shut down the audio engine. Call from `applicationWillTerminate`.
    func shutdown() {
        stateLock.withLock {
            isShuttingDown = true
            state = .idle
            activeTrace = nil
            activeTranscriptionTrace = nil
            activeReplayLease = nil
            activeDeliveryTarget = nil
        }
        failedCaptureReplayBuffer.clear()
        transitionRecordingFeedback(to: .hidden)
        audioCapture.shutdown()
    }

    /// Mark the model ready without running warmup. Used in tests and SWIFT_PACKAGE builds
    /// where warmup is not needed or not available.
    func skipWarmup() {
        stateLock.withLock { warmupState = .ready }
    }

    /// Wake and key-down share the same non-periodic idle check.
    func rewarmIfIdle() {
        let request = stateLock.withLock { () -> (Transcriber, UInt64)? in
            let now = nativeClock()
            guard !isShuttingDown, warmupState.isReady, activeModelSwitchID == nil,
                  rewarmRunID == nil, let last = lastNativeInferenceAt,
                  now >= last, now - last > rewarmThresholdNs else { return nil }
            if case .transcribing = state { return nil }
            let runID = nextRunID()
            rewarmRunID = runID
            return (transcriber, runID)
        }
        guard let (model, runID) = request else { return }
        rewarmQueue.async { [weak self] in
            guard let self else { return }
            // Check and mark running under one lock so a concurrent stop either
            // skips this rewarm or observes it as in flight and cancels it.
            let shouldRun = self.stateLock.withLock { () -> Bool in
                let blocked: Bool
                if case .transcribing = self.state {
                    blocked = true
                } else {
                    blocked = self.isShuttingDown || self.activeModelSwitchID != nil
                }
                guard !blocked else {
                    self.rewarmRunID = nil
                    return false
                }
                self.rewarmIsRunning = true
                self.activeTrace?.rewarmStarted = true
                return true
            }
            guard shouldRun else { return }
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Speakeasy idle model rewarm")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try model.warmUp(runID: runID)
                self.stateLock.withLock { self.lastNativeInferenceAt = self.nativeClock() }
            } catch {
                self.logger.error("Idle model rewarm failed: \(String(describing: error))")
            }
            self.stateLock.withLock {
                self.rewarmIsRunning = false
                self.rewarmRunID = nil
            }
        }
    }

    func selectedASRModelKind() -> ASRModelKind {
        stateLock.withLock { currentASRModelKind }
    }

    func selectedInvocationMode() -> DictationInvocationMode {
        stateLock.withLock { invocationMode }
    }

    func selectedDictationShortcut() -> DictationShortcut {
        stateLock.withLock { dictationShortcut }
    }

    @MainActor
    func transcriptCorrections() -> [TranscriptCorrection] {
        transcriptCorrectionStore?.allCorrections() ?? []
    }

    /// Persists and compiles settings work before atomically publishing the
    /// immutable matcher used by future accepted transcripts.
    @MainActor
    func replaceTranscriptCorrections(
        _ corrections: [TranscriptCorrection]
    ) throws -> Task<Bool, Never> {
        guard let transcriptCorrectionStore else {
            throw TranscriptCorrectionUpdateError.storeUnavailable
        }
        let nextProcessor = try TranscriptPostProcessor(corrections: corrections)
        let persistence = try transcriptCorrectionStore.replace(corrections)

        return Task { @MainActor [weak self] in
            guard await persistence.value else { return false }
            if let self {
                self.stateLock.withLock {
                    self.transcriptPostProcessor = nextProcessor
                }
            }
            return true
        }
    }

    func availableInputDevices() -> [MicrophoneDevice] {
        audioCapture.availableInputDevices()
    }

    func selectedInputDeviceUID() -> String? {
        audioCapture.selectedInputDeviceUID()
    }

    func selectInputDevice(uid: String) {
        let rejection = stateLock.withLock { () -> String? in
            guard !isShuttingDown else { return "Microphone selection unavailable" }
            guard activeInputDeviceSwitchUID == nil else { return "Microphone change already in progress" }
            guard activeModelSwitchID == nil else { return "Wait for model switching to finish" }
            guard case .idle = state else { return "Finish dictation before changing microphones" }
            guard audioCapture.selectedInputDeviceUID() != uid else { return nil }
            activeInputDeviceSwitchUID = uid
            return nil
        }
        if let rejection {
            feedback.notify(event: .error(rejection))
            return
        }
        guard stateLock.withLock({ activeInputDeviceSwitchUID == uid }) else {
            return
        }
        audioCapture.selectInputDevice(uid: uid)
    }

    func canSelectInputDevice() -> Bool {
        stateLock.withLock {
            guard !isShuttingDown,
                  activeInputDeviceSwitchUID == nil,
                  activeModelSwitchID == nil,
                  case .idle = state else {
                return false
            }
            return true
        }
    }

    func microphoneLevelSnapshot() -> MicrophoneLevelSnapshot {
        audioCapture.microphoneLevelSnapshot()
    }

    func setInvocationMode(_ mode: DictationInvocationMode) {
        guard stateLock.withLock({ invocationMode != mode }) else { return }
        do {
            try keyMonitor?.setInvocationMode(mode)
            stateLock.withLock { invocationMode = mode }
        } catch let error as KeyComboMonitorError {
            feedback.notify(event: .error(error.userMessage))
        } catch {
            feedback.notify(event: .error("Could not change dictation mode"))
        }
    }

    func canChangeDictationShortcut() -> Bool {
        stateLock.withLock {
            guard !isShuttingDown,
                  activeInputDeviceSwitchUID == nil,
                  activeModelSwitchID == nil,
                  case .idle = state else {
                return false
            }
            return keyMonitor != nil
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        keyMonitor?.setSuspended(isActive)
    }

    func setDictationShortcut(_ shortcut: DictationShortcut) -> DictationShortcutUpdateResult {
        guard shortcut.isValid else {
            return .failure("Choose a key with Command, Control, or Option")
        }
        guard canChangeDictationShortcut(), let keyMonitor else {
            return .failure("Finish dictation before changing the shortcut")
        }
        guard stateLock.withLock({ dictationShortcut != shortcut }) else {
            return .success
        }

        do {
            try keyMonitor.updateShortcut(shortcut)
            stateLock.withLock { dictationShortcut = shortcut }
            shortcutSelectionStore(shortcut)
            feedback.notify(event: .status("Shortcut changed to \(shortcut.displayName)"))
            return .success
        } catch let error as KeyComboMonitorError {
            return .failure(error.userMessage)
        } catch {
            return .failure("Could not register that shortcut")
        }
    }

    func canCancelDictation() -> Bool {
        stateLock.withLock {
            guard !isShuttingDown else { return false }
            switch state {
            case .idle:
                return false
            case .startingCapture, .recording, .transcribing:
                return true
            }
        }
    }

    func canRetryFailedCapture() -> Bool {
        stateLock.withLock {
            guard !isShuttingDown, warmupState.isReady, case .idle = state else {
                return false
            }
            return failedCaptureReplayBuffer.hasCapture
        }
    }

    func canDiscardFailedCapture() -> Bool {
        stateLock.withLock {
            guard !isShuttingDown, case .idle = state else { return false }
            return failedCaptureReplayBuffer.hasCapture
        }
    }

    /// Retry the one retained failed capture without touching AudioCapture.
    func retryLastFailedCapture() {
        let retry = stateLock.withLock { () -> (
            lease: FailedCaptureReplayBuffer.Lease,
            token: UUID,
            runID: UInt64,
            trace: TranscriptionTrace,
            target: TranscriptDeliveryTarget
        )? in
            guard !isShuttingDown, warmupState.isReady, case .idle = state,
                  let lease = failedCaptureReplayBuffer.acquireLease() else {
                return nil
            }

            let token = UUID()
            let runID = nextRunID()
            var trace = TranscriptionTrace(
                hotkeyPressedAt: TranscriptionTrace.timestamp(),
                backend: currentASRModelKind.preferenceValue
            )
            trace.markStopReturned(sampleCount: lease.samples.count)
            let target = deliveryTargetProvider.currentTarget()
            state = .transcribing(token, runID: runID, didTimeOut: false, didCancel: false)
            activeTranscriptionTrace = trace
            activeReplayLease = lease
            return (lease, token, runID, trace, target)
        }

        guard let retry else {
            feedback.notify(event: .error("No failed capture available"))
            return
        }

        transitionRecordingFeedback(to: .processing)
        beginNativeTranscription(
            samples: retry.lease.samples,
            activeSampleCount: retry.lease.samples.count,
            rms: Self.rms(of: retry.lease.samples),
            token: retry.token,
            runID: retry.runID,
            trace: retry.trace,
            target: retry.target
        )
    }

    func discardFailedCapture() {
        let didDiscard = stateLock.withLock { () -> Bool in
            guard !isShuttingDown, case .idle = state else { return false }
            activeReplayLease = nil
            return failedCaptureReplayBuffer.hasCapture
        }
        guard didDiscard else { return }
        failedCaptureReplayBuffer.clear()
        feedback.notify(event: .status("Failed capture discarded"))
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

            guard activeInputDeviceSwitchUID == nil else {
                return .reject("Wait for microphone change to finish")
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
                    if !model.artifactVerified {
                        try modelArtifactVerifier(model)
                    }
                    let transcriber = try transcriberFactory(model)
                    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Speakeasy replacement model warmup")
                    defer { ProcessInfo.processInfo.endActivity(activity) }
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
            },
            initialInputDeviceUID: MicrophoneSelectionStore.selectedUID()
        )
        let paster = PasteboardPaster()
        let recordingFeedback = RecordingIndicator {
            audioCapture.microphoneLevelSnapshot()
        }
        let correctionStore = TranscriptCorrectionStore()
        let postProcessor = (try? TranscriptPostProcessor(corrections: correctionStore.allCorrections()))
            ?? TranscriptPostProcessor()

        let dictationShortcut = DictationShortcutStore.selected()
        let keyMonitorFactory: KeyMonitorFactory = { callback in
            KeyComboMonitor(
                shortcut: dictationShortcut,
                callback: callback
            )
        }

        self.init(
            audioCapture: audioCapture,
            transcriber: transcriber,
            paster: paster,
            recordingFeedback: recordingFeedback,
            feedback: feedback,
            accessibilityChecker: SystemAccessibilityChecker(),
            asrModelKind: model.kind,
            asrModelResolver: {
                try await ASRModelInstaller().resolveOrInstall(kind: $0)
            },
            transcriberFactory: { try TranscribeCppTranscriber(model: $0) },
            modelSelectionStore: { ModelPathResolver.persistSelectedModelKind($0) },
            inputDeviceSelectionStore: { MicrophoneSelectionStore.persist(uid: $0) },
            dictationShortcut: dictationShortcut,
            shortcutSelectionStore: { DictationShortcutStore.persist($0) },
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory,
            transcriptStore: TranscriptStore(),
            diagnosticsStore: DiagnosticsStore(),
            e2eTraceStore: Self.defaultE2ETraceStore(),
            transcriptPostProcessor: postProcessor,
            transcriptCorrectionStore: correctionStore
        )
    }

    /// Production e2e latency log under Application Support, beside the
    /// other stores. Returns nil on path failure; tracing never blocks
    /// dictation startup.
    private static func defaultE2ETraceStore() -> E2ETraceStore? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        let url = base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("dictation-e2e.jsonl")
        return E2ETraceStore(fileURL: url)
    }
    #endif

    // MARK: - State Machine
    //
    // Hotkey input advances the coordinator through a single linear recording
    // session: idle -> startingCapture -> recording -> transcribing(token) -> idle. The token
    // prevents timeout and transcription callbacks from completing stale work
    // after a later session has already moved the state forward.

    func toggleRecording() {
        handle(.toggle)
    }

    /// Accepts all external dictation input. Input monitors translate device
    /// events into this intent surface; this coordinator remains the only
    /// owner of recording and transcription state.
    func handle(_ intent: DictationIntent) {
        intentLock.withLock {
            handleIntent(intent)
        }
    }

    private func handleIntent(_ intent: DictationIntent) {
        let now = TranscriptionTrace.timestamp()

        let transition = stateLock.withLock { () -> Transition in
            guard !isShuttingDown else { return .ignore(nil) }
            if activeInputDeviceSwitchUID != nil, intent != .cancel {
                return .ignore("Microphone changing, please wait")
            }

            func start() -> Transition {
                failedCaptureReplayBuffer.clear()
                activeReplayLease = nil
                let captureID = UUID()
                var trace = TranscriptionTrace(
                    hotkeyPressedAt: now,
                    backend: currentASRModelKind.preferenceValue
                )
                if let last = lastNativeInferenceAt, nativeClock() >= last {
                    trace.idleGapSinceLastNativeInferenceMs = Double(nativeClock() - last) / 1_000_000
                }
                state = .startingCapture(captureID)
                activeTrace = trace
                activeDeliveryTarget = deliveryTargetProvider.currentTarget()
                return .start(captureID, trace, activeDeliveryTarget ?? .unavailable)
            }

            guard warmupState.isReady || intent == .cancel else {
                return .blocked(
                    TranscriptionTrace(
                        hotkeyPressedAt: now,
                        backend: currentASRModelKind.preferenceValue
                    ),
                    "Model warming up, please wait"
                )
            }

            func stop() -> Transition {
                let token = UUID()
                let runID = nextRunID()
                state = .transcribing(token, runID: runID, didTimeOut: false, didCancel: false)
                var trace = activeTrace ?? TranscriptionTrace(hotkeyPressedAt: now)
                trace.markHotkeyReleased(at: now)
                trace.rewarmInFlightAtFinalStart = rewarmIsRunning
                let target = activeDeliveryTarget ?? .unavailable
                activeTrace = nil
                activeDeliveryTarget = nil
                activeTranscriptionTrace = trace
                return .stop(token, runID, trace, target)
            }

            switch intent {
            case .toggle:
                switch state {
                case .idle:
                    return start()
                case .startingCapture:
                    return .ignore("Microphone reconnecting, please wait")
                case .recording:
                    return stop()
                case .transcribing:
                    return .ignore(nil)
                }

            case .pushToTalkBegan:
                guard invocationMode == .pushToTalk else { return .ignore(nil) }
                switch state {
                case .idle:
                    return start()
                case .startingCapture, .recording, .transcribing:
                    return .ignore(nil)
                }

            case .pushToTalkEnded:
                guard invocationMode == .pushToTalk else { return .ignore(nil) }
                switch state {
                case .recording:
                    return stop()
                case .idle, .startingCapture, .transcribing:
                    return .ignore(nil)
                }

            case .cancel:
                failedCaptureReplayBuffer.clear()
                activeReplayLease = nil
                switch state {
                case .idle:
                    return .ignore(nil)
                case .startingCapture:
                    let trace = activeTrace
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return .discardCapture(trace, notify: true)
                case .recording:
                    let trace = activeTrace
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return .discardCapture(trace, notify: true)
                case .transcribing(let token, let runID, let didTimeOut, let didCancel):
                    guard !didTimeOut, !didCancel, let trace = activeTranscriptionTrace else {
                        return .ignore(nil)
                    }
                    state = .transcribing(token, runID: runID, didTimeOut: false, didCancel: true)
                    return .cancelTranscription(runID, trace)
                }
            }
        }

        switch transition {
        case .start(let captureID, var trace, let target):
            rewarmIfIdle()
            do {
                try audioCapture.beginRecording()
                trace.markCaptureStarted()
                let didStart = stateLock.withLock { () -> Bool in
                    guard case .startingCapture(let currentID) = state, currentID == captureID else {
                        return false
                    }
                    state = .recording
                    trace.rewarmStarted = activeTrace?.rewarmStarted ?? trace.rewarmStarted
                    activeTrace = trace
                    activeDeliveryTarget = target
                    return true
                }
                guard didStart else {
                    audioCapture.discardRecording()
                    return
                }

                startLivePreviewLoop()
                transitionRecordingFeedback(to: .recording)
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

        case .stop(let token, let runID, let trace, let target):
            // transcribe.cpp's cancel token is checked by its abort callback.
            // If the native backend cannot abort immediately, the final run
            // still waits for the session; queued final cancels are retained.
            if let rewarm = stateLock.withLock({ rewarmIsRunning ? rewarmRunID : nil }) {
                stateLock.withLock { transcriber }.cancel(runID: rewarm)
            }
            stopLivePreviewLoop()
            transitionRecordingFeedback(to: .processing)
            stopAndTranscribe(token: token, runID: runID, trace: trace, target: target)

        case .discardCapture(let trace, let notify):
            stopLivePreviewLoop()
            audioCapture.discardRecording()
            transitionRecordingFeedback(to: .hidden)
            if let trace {
                recordTerminal(trace: trace, outcome: .cancelled)
            }
            if notify {
                feedback.notify(event: .error("Recording cancelled"))
            }

        case .cancelTranscription(let runID, let trace):
            transitionRecordingFeedback(to: .hidden)
            let transcriber = stateLock.withLock { self.transcriber }
            transcriber.cancel(runID: runID)
            recordTerminal(trace: trace, outcome: .cancelled)
            feedback.notify(event: .error("Transcription cancelled"))

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

    /// Request cancellation of the active native transcription. The
    /// coordinator remains transcribing until the native call settles, so a
    /// late completion cannot overlap a later session.
    func cancelTranscription() {
        handle(.cancel)
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

            let interruption = stateLock.withLock { () -> (shouldNotify: Bool, shouldHideFeedback: Bool) in
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
            if interruption.shouldHideFeedback {
                transitionRecordingFeedback(to: .hidden)
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
            let shouldHideFeedback = stateLock.withLock { () -> Bool in
                suppressRecoverySuccessStatus = false
                switch state {
                case .startingCapture:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return false
                case .recording:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    return true
                case .idle, .transcribing:
                    return false
                }
            }
            if shouldHideFeedback {
                transitionRecordingFeedback(to: .hidden)
            }
            logger.error("Microphone reconnection failed")
            feedback.notify(event: .error("Microphone reconnection failed"))

        case .inputDeviceSelectionSucceeded(let uid):
            let isCurrent = stateLock.withLock { () -> Bool in
                guard activeInputDeviceSwitchUID == uid else { return false }
                activeInputDeviceSwitchUID = nil
                return true
            }
            guard isCurrent else { return }
            inputDeviceSelectionStore(uid)
            feedback.notify(event: .status("Microphone changed"))

        case .inputDeviceSelectionFailed(let uid, let rollback):
            let isCurrent = stateLock.withLock { () -> Bool in
                guard activeInputDeviceSwitchUID == uid else { return false }
                activeInputDeviceSwitchUID = nil
                return true
            }
            guard isCurrent else { return }
            switch rollback {
            case .restored:
                feedback.notify(event: .error("Microphone selection failed; previous microphone kept"))
            case .unavailable:
                feedback.notify(event: .error("Microphone selection failed; audio capture unavailable"))
            }
        }
    }

    private func stopAndTranscribe(
        token: UUID,
        runID: UInt64,
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
            // Speech gating scans every sample; keep it off the main queue.
            let speech = SpeechGate.analyze(
                captureResult.samples,
                startingAt: captureResult.prependedSampleCount
            )
            DispatchQueue.main.async { [weak self] in
                self?.processCaptureResult(
                    token: token,
                    runID: runID,
                    trace: trace,
                    captureResult: captureResult,
                    rms: rms,
                    speech: speech,
                    target: target
                )
            }
        }
    }

    private func processCaptureResult(
        token: UUID,
        runID: UInt64,
        trace: TranscriptionTrace,
        captureResult: AudioCaptureResult,
        rms: Float,
        speech: SpeechGateResult,
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
        stateLock.withLock { activeTranscriptionTrace = trace }

        guard stateLock.withLock({
            guard case let .transcribing(current, currentRunID, didTimeOut, didCancel) = state,
                  current == token,
                  currentRunID == runID else {
                return false
            }
            if didCancel || didTimeOut {
                return false
            }
            return true
        }) else {
            _ = finishTranscription(token: token)
            return
        }

        guard !captureResult.wasInterrupted else {
            if case .eligible = finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .captureInterrupted)
                feedback.notify(event: .error("Recording interrupted by microphone change"))
            }
            return
        }

        guard !samples.isEmpty else {
            if case .eligible = finishTranscription(token: token) {
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
            if case .eligible = finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .noSpeech)
            }
            return
        }

        guard speech.hasSpeech else {
            logger.debug(
                "Speech gate rejected audio: rms=\(rms, format: .fixed(precision: 4)) floor=\(speech.noiseFloorRMS, format: .fixed(precision: 4)) voiced=\(speech.voicedFrameCount)/\(speech.analyzedFrameCount) longestRun=\(speech.longestVoicedRun)"
            )
            feedback.notify(event: .error("No speech detected"))
            if case .eligible = finishTranscription(token: token) {
                recordTerminal(trace: trace, outcome: .noSpeech)
            }
            return
        }

        beginNativeTranscription(
            samples: samples,
            activeSampleCount: activeSampleCount,
            rms: rms,
            token: token,
            runID: runID,
            trace: trace,
            target: target
        )
    }

    private func beginNativeTranscription(
        samples: ContiguousArray<Float>,
        activeSampleCount: Int,
        rms: Float,
        token: UUID,
        runID: UInt64,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
        let timeoutTrace = trace
        var trace = trace
        let timeout = transcriptionTimeoutProvider(samples)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTranscriptionTimeout(token: token, timeout: timeout, trace: timeoutTrace)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        transcriptionQueue.async { [weak self] in
            guard let self else { return }

            let canStart = self.stateLock.withLock {
                guard case let .transcribing(current, currentRunID, didTimeOut, didCancel) = self.state,
                      current == token,
                      currentRunID == runID,
                      !didTimeOut,
                      !didCancel,
                      !self.isShuttingDown else {
                    return false
                }
                return true
            }
            guard canStart else {
                DispatchQueue.main.async {
                    timeoutWorkItem.cancel()
                    if case .timedOut = self.finishTranscription(token: token) {
                        self.retainFailedCapture(samples: samples, reason: .timedOut)
                    }
                }
                return
            }

            trace.markTranscriptionStarted()
            let result: Result<String, Error>
            do {
                let transcriber = self.stateLock.withLock { self.transcriber }
                let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Speakeasy native transcription")
                defer { ProcessInfo.processInfo.endActivity(activity) }
                let (text, timings) = try transcriber.transcribeWithTimings(samples: samples, runID: runID)
                trace.nativeTimings = timings
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            if case .success = result {
                self.stateLock.withLock { self.lastNativeInferenceAt = self.nativeClock() }
            }
            trace.markTranscriptionEnded()
            // Immutable snapshot for the async hop below.
            let settledTrace = trace

            // One main-actor task keeps settlement and delivery in the same
            // sequential order the previous main-queue hop provided.
            Task { @MainActor [weak self] in
                guard let self else { return }
                timeoutWorkItem.cancel()
                let settlement = self.finishTranscription(token: token)

                switch settlement {
                case .eligible:
                    switch result {
                    case .success(let text):
                        self.failedCaptureReplayBuffer.clear()
                        await self.handleTranscriptionResult(
                            text,
                            trace: settledTrace,
                            activeDurationSeconds: Double(activeSampleCount) / Self.transcriptionSampleRate,
                            activeRMS: rms,
                            target: target
                        )
                    case .failure(let error):
                        self.retainFailedCapture(samples: samples, reason: .transcriptionFailed)
                        self.recordTerminal(trace: settledTrace, outcome: .transcriptionFailed)
                        self.logger.error("Transcription failed: \(String(describing: error))")
                        self.feedback.notify(event: .error("Transcription failed"))
                    }
                case .timedOut:
                    self.retainFailedCapture(samples: samples, reason: .timedOut)
                case .cancelled, .stale:
                    break
                }
            }
        }
    }

    @MainActor
    private func handleTranscriptionResult(
        _ text: String,
        trace: TranscriptionTrace,
        activeDurationSeconds: TimeInterval? = nil,
        activeRMS: Float? = nil,
        target: TranscriptDeliveryTarget = .unavailable
    ) async {
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

        let postProcessor = stateLock.withLock { transcriptPostProcessor }
        let processedTranscript = postProcessor.process(trimmed)
        var finalText = processedTranscript.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let polisher = stateLock.withLock({ textPolisher }) {
            // Polish refines corrected text; structural guards fall back to
            // the corrected text when output loses meaning or runs away.
            let polished = await polisher.polish(finalText)
            finalText = PolishGuard.sanitized(source: finalText, output: polished) { reason in
                self.logger.debug("Polish rejected (\(String(describing: reason))); keeping corrected text")
            }.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !finalText.isEmpty else {
            recordTerminal(trace: trace, outcome: .noSpeech)
            feedback.notify(event: .error("No speech detected"))
            return
        }
        let polishedTranscript = ProcessedTranscript(
            rawText: processedTranscript.rawText,
            finalText: finalText
        )
        let settledTranscript = polishedTranscript
        let record = TranscriptRecord(
            id: trace.id,
            rawText: settledTranscript.rawText,
            finalText: settledTranscript.finalText,
            backend: trace.backend,
            outcome: .transcriptPersisted,
            timings: trace.timingSnapshot
        )

        guard let transcriptStore else {
            deliverPersistedTranscript(
                settledTranscript,
                trace: trace,
                recordID: nil,
                target: target
            )
            return
        }

        let persistence = transcriptStore.append(record)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await persistence.value else {
                self.logger.error("Transcript could not be persisted; skipping paste")
                self.recordTerminal(
                    trace: trace,
                    outcome: .transcriptPersistenceFailed,
                    text: settledTranscript.finalText
                )
                self.feedback.notify(event: .error("Transcript could not be saved"))
                return
            }
            self.deliverPersistedTranscript(
                settledTranscript,
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
    /// A cancelled native inference keeps ownership of the serial worker until
    /// it settles; only then does the app become idle.
    @discardableResult
    private func finishTranscription(token: UUID) -> TranscriptionSettlement {
        let settlement = stateLock.withLock { () -> TranscriptionSettlement in
            guard case let .transcribing(current, _, didTimeOut, didCancel) = state,
                  current == token else {
                return .stale
            }

            state = .idle
            activeTranscriptionTrace = nil
            activeReplayLease = nil
            if didTimeOut { return .timedOut }
            if didCancel { return .cancelled }
            return .eligible
        }

        if settlement != .stale {
            transitionRecordingFeedback(to: .hidden)
        }
        return settlement
    }

    private func transitionRecordingFeedback(to transition: RecordingFeedbackTransition) {
        let generation = stateLock.withLock { () -> UInt64 in
            recordingFeedbackGeneration &+= 1
            return recordingFeedbackGeneration
        }

        Task { @MainActor [self, recordingFeedback] in
            let isCurrent = stateLock.withLock {
                recordingFeedbackGeneration == generation
            }
            guard isCurrent else { return }

            switch transition {
            case .recording:
                recordingFeedback.showRecording()
            case .processing:
                recordingFeedback.showProcessing()
            case .hidden:
                recordingFeedback.hide()
            }
        }
    }

    private func retainFailedCapture(
        samples: ContiguousArray<Float>,
        reason: FailedCaptureReplayReason
    ) {
        guard !stateLock.withLock({ isShuttingDown }) else { return }
        guard failedCaptureReplayBuffer.install(samples: samples, reason: reason) else {
            logger.error("Failed capture exceeded the in-memory replay bound")
            return
        }
    }

    private func nextRunID() -> UInt64 {
        nextTranscriptionID &+= 1
        if nextTranscriptionID == 0 {
            nextTranscriptionID = 1
        }
        return nextTranscriptionID
    }

    private func handleTranscriptionTimeout(token: UUID, timeout: TimeInterval, trace: TranscriptionTrace) {
        let cancellation = stateLock.withLock { () -> (runID: UInt64, shouldNotify: Bool)? in
            guard case let .transcribing(current, runID, didTimeOut, didCancel) = state,
                  current == token,
                  !didTimeOut,
                  !didCancel else {
                return nil
            }

            state = .transcribing(current, runID: runID, didTimeOut: true, didCancel: false)
            return (runID, true)
        }

        guard let cancellation, cancellation.shouldNotify else { return }

        transitionRecordingFeedback(to: .hidden)
        let transcriber = stateLock.withLock { self.transcriber }
        transcriber.cancel(runID: cancellation.runID)
        recordTerminal(trace: trace, outcome: .timedOut)
        logger.error("Transcription timed out after \(timeout)s")
        feedback.notify(event: .error("Transcription timed out"))
    }

    // MARK: - Live preview

    /// Distinct run-ID space for preview passes so a stale final-run cancel
    /// can never hit an in-flight preview or vice versa.
    private static let previewRunIDFlag: UInt64 = 1 << 63
    private var previewRunSequence: UInt64 = 0

    private func startLivePreviewLoop() {
        guard let controller = livePreviewController else { return }
        controller.reset()
        stateLock.withLock { livePreviewText = nil }

        let timer = DispatchSource.makeTimerSource(queue: previewQueue)
        timer.schedule(deadline: .now() + LivePreviewController.defaultMinimumIntervalMs / 1000,
                       repeating: 0.35)
        timer.setEventHandler { [weak self] in
            self?.pollLivePreview(nowMs: Self.millisSinceLaunch())
        }
        timer.resume()
        stateLock.withLock { previewTimer = timer }
    }

    private func stopLivePreviewLoop() {
        let timer = stateLock.withLock { () -> DispatchSourceTimer? in
            let timer = previewTimer
            previewTimer = nil
            return timer
        }
        timer?.cancel()
        if let controller = livePreviewController {
            _ = controller.finishPass(candidate: nil) // clear in-flight flag only
            controller.reset()
        }
        stateLock.withLock { livePreviewText = nil }
    }

    func pollLivePreview(nowMs: Double) {
        guard let controller = livePreviewController else { return }
        let samples = audioCapture.livePreviewSamples()
        guard controller.shouldTranscribe(nowMs: nowMs, bufferedSampleCount: samples.count) else {
            return
        }
        controller.beginPass(nowMs: nowMs, bufferedSampleCount: samples.count)

        // Recording carries no run ID; previews get their own sequence in a
        // dedicated high-bit space so they never collide with final runs.
        let sequence = stateLock.withLock { () -> UInt64 in
            previewRunSequence &+= 1
            return previewRunSequence
        }
        let previewRunID = Self.previewRunIDFlag | sequence

        previewQueue.async { [weak self] in
            guard let self else { return }
            let transcriber = self.stateLock.withLock { self.transcriber }
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Speakeasy live preview inference")
            let text = try? transcriber.transcribe(samples: samples, runID: previewRunID)
            ProcessInfo.processInfo.endActivity(activity)
            if text != nil {
                self.stateLock.withLock { self.lastNativeInferenceAt = self.nativeClock() }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let adopted = self.livePreviewController?.finishPass(candidate: text)
                if let adopted, !adopted.isEmpty {
                    let changed = self.stateLock.withLock { () -> Bool in
                        let previous = self.livePreviewText
                        self.livePreviewText = adopted
                        return previous != adopted
                    }
                    if changed {
                        self.onLivePreviewTextChange?(adopted)
                        self.logger.debug("Live preview adopted (\(adopted.count) chars)")
                    }
                }
            }
        }
    }

    fileprivate static func millisSinceLaunch() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
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
        if let e2eTraceStore = stateLock.withLock({ self.e2eTraceStore }) {
            if let record = E2ETraceRecordFactory.record(
                from: trace,
                outcome: outcome,
                deliveredText: text
            ) {
                e2eTraceStore.append(record)
            }
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
                lastNativeInferenceAt = nativeClock()
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
