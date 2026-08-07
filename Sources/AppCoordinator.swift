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
typealias SmartCleanupModeSelectionStore = (_ mode: SmartCleanupMode) -> Void

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
        case start(UUID, TranscriptionTrace, TranscriptDeliveryTarget, SmartCleanupMode)
        case stop(UUID, UInt64, TranscriptionTrace, TranscriptDeliveryTarget, SmartCleanupMode)
        case discardCapture(TranscriptionTrace?, notify: Bool)
        case cancelTranscription(UUID, UInt64, TranscriptionTrace, cleanupHasStarted: Bool)
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

    private enum SmartCleanupLogOutcome: String {
        case success
        case unavailable
        case invalidRequest
        case cancelled
        case timedOut
        case generationFailed
        case rejectedOutput
    }

    private struct SmartCleanupSession {
        let id: UUID
        let application: TranscriptDeliveryApplication
        var contextTask: Task<AppContext, Never>?
        var prewarmTask: Task<Void, Never>?
        var cleanupTask: Task<SmartCleanupResult, Never>?
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
    private var transcriptPostProcessor: TranscriptPostProcessor
    private let transcriptCorrectionStore: TranscriptCorrectionStore?
    private var currentASRModelKind: ASRModelKind
    private let asrModelResolver: ASRModelResolver?
    private let transcriberFactory: TranscriberFactory?
    private let modelArtifactVerifier: ASRModelArtifactVerifier
    private let modelSelectionStore: ASRModelSelectionStore
    private let inputDeviceSelectionStore: InputDeviceSelectionStore
    private let shortcutSelectionStore: DictationShortcutSelectionStore
    private let smartCleanupProvider: any SmartCleanupProviding
    private let appContextCollector: any AppContextCollecting
    private let smartCleanupModeSelectionStore: SmartCleanupModeSelectionStore
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
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
    private var smartCleanupMode: SmartCleanupMode
    private var activeRecordingSmartCleanupMode: SmartCleanupMode?
    private var activeSmartCleanupSession: SmartCleanupSession?
    private let transcriptionQueue: DispatchQueue
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
        smartCleanupProvider: any SmartCleanupProviding = UnavailableSmartCleanupProvider(
            reason: .frameworkUnavailable
        ),
        appContextCollector: any AppContextCollecting = AppContextService(),
        smartCleanupMode: SmartCleanupMode = .basic,
        smartCleanupModeSelectionStore: @escaping SmartCleanupModeSelectionStore = { _ in },
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?,
        transcriptStore: TranscriptStore? = nil,
        diagnosticsStore: DiagnosticsStore? = nil,
        transcriptPostProcessor: TranscriptPostProcessor = TranscriptPostProcessor(),
        transcriptCorrectionStore: TranscriptCorrectionStore? = nil,
        transcriptionQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInteractive),
        deliveryTargetProvider: DeliveryTargetProviding = SystemDeliveryTargetProvider(),
        failedCaptureReplayBuffer: FailedCaptureReplayBuffer = FailedCaptureReplayBuffer()
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
        self.transcriptCorrectionStore = transcriptCorrectionStore
        self.currentASRModelKind = asrModelKind
        self.asrModelResolver = asrModelResolver
        self.transcriberFactory = transcriberFactory
        self.modelArtifactVerifier = modelArtifactVerifier
        self.modelSelectionStore = modelSelectionStore
        self.inputDeviceSelectionStore = inputDeviceSelectionStore
        self.dictationShortcut = dictationShortcut
        self.shortcutSelectionStore = shortcutSelectionStore
        self.smartCleanupProvider = smartCleanupProvider
        self.appContextCollector = appContextCollector
        self.smartCleanupMode = smartCleanupMode
        self.smartCleanupModeSelectionStore = smartCleanupModeSelectionStore
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider
        self.failedCaptureReplayBuffer = failedCaptureReplayBuffer
        self.transcriptStore = transcriptStore
        self.diagnosticsStore = diagnosticsStore
        self.transcriptionQueue = transcriptionQueue

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
        let cleanupSession = stateLock.withLock { () -> SmartCleanupSession? in
            isShuttingDown = true
            state = .idle
            activeTrace = nil
            activeTranscriptionTrace = nil
            activeReplayLease = nil
            activeDeliveryTarget = nil
            activeRecordingSmartCleanupMode = nil
            defer { activeSmartCleanupSession = nil }
            return activeSmartCleanupSession
        }
        cancelSmartCleanupSession(cleanupSession)
        failedCaptureReplayBuffer.clear()
        transitionRecordingFeedback(to: .hidden)
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

    func selectedInvocationMode() -> DictationInvocationMode {
        stateLock.withLock { invocationMode }
    }

    func selectedDictationShortcut() -> DictationShortcut {
        stateLock.withLock { dictationShortcut }
    }

    func selectedSmartCleanupMode() -> SmartCleanupMode {
        stateLock.withLock { smartCleanupMode }
    }

    func setSmartCleanupMode(_ mode: SmartCleanupMode) {
        let didChange = stateLock.withLock { () -> Bool in
            guard smartCleanupMode != mode else { return false }
            smartCleanupMode = mode
            return true
        }
        guard didChange else { return }
        smartCleanupModeSelectionStore(mode)
    }

    func smartCleanupAvailability() async -> SmartCleanupAvailability {
        await smartCleanupProvider.availability()
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
            target: TranscriptDeliveryTarget,
            cleanupMode: SmartCleanupMode
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
            let cleanupMode = smartCleanupMode
            state = .transcribing(token, runID: runID, didTimeOut: false, didCancel: false)
            activeTranscriptionTrace = trace
            activeReplayLease = lease
            activeSmartCleanupSession = Self.makeSmartCleanupSession(
                mode: cleanupMode,
                target: target
            )
            return (lease, token, runID, trace, target, cleanupMode)
        }

        guard let retry else {
            feedback.notify(event: .error("No failed capture available"))
            return
        }

        transitionRecordingFeedback(to: .processing)
        startSmartCleanupPreparationIfNeeded()
        beginNativeTranscription(
            samples: retry.lease.samples,
            activeSampleCount: retry.lease.samples.count,
            rms: Self.rms(of: retry.lease.samples),
            token: retry.token,
            runID: retry.runID,
            trace: retry.trace,
            target: retry.target,
            cleanupMode: retry.cleanupMode
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
        let smartCleanupModeStore = SmartCleanupModeStore()

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
            smartCleanupProvider: SmartCleanupProviderFactory.make(),
            appContextCollector: AppContextService(),
            smartCleanupMode: smartCleanupModeStore.load(),
            smartCleanupModeSelectionStore: { smartCleanupModeStore.save($0) },
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory,
            transcriptStore: TranscriptStore(),
            diagnosticsStore: DiagnosticsStore(),
            transcriptPostProcessor: postProcessor,
            transcriptCorrectionStore: correctionStore
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
                let trace = TranscriptionTrace(
                    hotkeyPressedAt: now,
                    backend: currentASRModelKind.preferenceValue
                )
                state = .startingCapture(captureID)
                activeTrace = trace
                activeDeliveryTarget = deliveryTargetProvider.currentTarget()
                let target = activeDeliveryTarget ?? .unavailable
                let mode = smartCleanupMode
                activeRecordingSmartCleanupMode = mode
                activeSmartCleanupSession = Self.makeSmartCleanupSession(
                    mode: mode,
                    target: target
                )
                return .start(captureID, trace, target, mode)
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
                let target = activeDeliveryTarget ?? .unavailable
                let cleanupMode = activeRecordingSmartCleanupMode ?? .basic
                activeTrace = nil
                activeDeliveryTarget = nil
                activeRecordingSmartCleanupMode = nil
                activeTranscriptionTrace = trace
                return .stop(token, runID, trace, target, cleanupMode)
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
                    activeRecordingSmartCleanupMode = nil
                    return .discardCapture(trace, notify: true)
                case .recording:
                    let trace = activeTrace
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    activeRecordingSmartCleanupMode = nil
                    return .discardCapture(trace, notify: true)
                case .transcribing(let token, let runID, let didTimeOut, let didCancel):
                    guard !didTimeOut, !didCancel, let trace = activeTranscriptionTrace else {
                        return .ignore(nil)
                    }
                    state = .transcribing(token, runID: runID, didTimeOut: false, didCancel: true)
                    return .cancelTranscription(
                        token,
                        runID,
                        trace,
                        cleanupHasStarted: activeSmartCleanupSession?.cleanupTask != nil
                    )
                }
            }
        }

        switch transition {
        case .start(let captureID, var trace, let target, _):
            do {
                try audioCapture.beginRecording()
                trace.markCaptureStarted()
                let didStart = stateLock.withLock { () -> Bool in
                    guard case .startingCapture(let currentID) = state, currentID == captureID else {
                        return false
                    }
                    state = .recording
                    activeTrace = trace
                    activeDeliveryTarget = target
                    return true
                }
                guard didStart else {
                    audioCapture.discardRecording()
                    return
                }

                transitionRecordingFeedback(to: .recording)
                startSmartCleanupPreparationIfNeeded()
            } catch {
                stateLock.withLock {
                    if case .startingCapture = state {
                        state = .idle
                    }
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    activeRecordingSmartCleanupMode = nil
                }
                cancelActiveSmartCleanupSession()
                logger.error("Recording start rejected: audio capture unavailable")
                feedback.notify(event: .error("Microphone reconnecting, try again shortly"))
            }

        case .stop(let token, let runID, let trace, let target, let cleanupMode):
            transitionRecordingFeedback(to: .processing)
            stopAndTranscribe(
                token: token,
                runID: runID,
                trace: trace,
                target: target,
                cleanupMode: cleanupMode
            )

        case .discardCapture(let trace, let notify):
            cancelActiveSmartCleanupSession()
            audioCapture.discardRecording()
            transitionRecordingFeedback(to: .hidden)
            if let trace {
                recordTerminal(trace: trace, outcome: .cancelled)
            }
            if notify {
                feedback.notify(event: .error("Recording cancelled"))
            }

        case .cancelTranscription(_, let runID, let trace, let cleanupHasStarted):
            if cleanupHasStarted {
                let session = stateLock.withLock { activeSmartCleanupSession }
                cancelSmartCleanupSession(session)
            } else {
                cancelActiveSmartCleanupSession()
                transitionRecordingFeedback(to: .hidden)
                let transcriber = stateLock.withLock { self.transcriber }
                transcriber.cancel(runID: runID)
            }
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
                    activeRecordingSmartCleanupMode = nil
                    return (true, false)
                case .recording:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    activeRecordingSmartCleanupMode = nil
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
            cancelActiveSmartCleanupSession()
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
                    activeRecordingSmartCleanupMode = nil
                    return false
                case .recording:
                    state = .idle
                    activeTrace = nil
                    activeDeliveryTarget = nil
                    activeRecordingSmartCleanupMode = nil
                    return true
                case .idle, .transcribing:
                    return false
                }
            }
            if shouldHideFeedback {
                transitionRecordingFeedback(to: .hidden)
            }
            cancelActiveSmartCleanupSession()
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

    private static func makeSmartCleanupSession(
        mode: SmartCleanupMode,
        target: TranscriptDeliveryTarget
    ) -> SmartCleanupSession? {
        guard mode == .smart, case .external(let application) = target else {
            return nil
        }
        return SmartCleanupSession(
            id: UUID(),
            application: application,
            contextTask: nil,
            prewarmTask: nil,
            cleanupTask: nil
        )
    }

    private func startSmartCleanupPreparationIfNeeded() {
        let pending = stateLock.withLock { () -> (UUID, TranscriptDeliveryApplication)? in
            guard !isShuttingDown,
                  let session = activeSmartCleanupSession,
                  session.contextTask == nil,
                  session.prewarmTask == nil else {
                return nil
            }
            switch state {
            case .recording, .transcribing:
                break
            case .idle, .startingCapture:
                return nil
            }
            return (session.id, session.application)
        }
        guard let (sessionID, application) = pending else { return }

        let collector = appContextCollector
        let provider = smartCleanupProvider
        let contextTask = Task { await collector.collect(for: application) }
        let prewarmTask = Task { await provider.prepare(sessionID: sessionID) }

        let didInstall = stateLock.withLock { () -> Bool in
            guard !isShuttingDown,
                  var session = activeSmartCleanupSession,
                  session.id == sessionID else {
                return false
            }
            switch state {
            case .recording, .transcribing:
                session.contextTask = contextTask
                session.prewarmTask = prewarmTask
                activeSmartCleanupSession = session
                return true
            case .idle, .startingCapture:
                return false
            }
        }

        guard didInstall else {
            contextTask.cancel()
            prewarmTask.cancel()
            Task { await provider.cancel(sessionID: sessionID) }
            return
        }
    }

    private func cancelActiveSmartCleanupSession() {
        let session = stateLock.withLock { () -> SmartCleanupSession? in
            defer { activeSmartCleanupSession = nil }
            return activeSmartCleanupSession
        }
        cancelSmartCleanupSession(session)
    }

    private func cancelSmartCleanupSession(_ session: SmartCleanupSession?) {
        guard let session else { return }
        session.contextTask?.cancel()
        session.prewarmTask?.cancel()
        session.cleanupTask?.cancel()
        let provider = smartCleanupProvider
        Task { await provider.cancel(sessionID: session.id) }
    }

    private func stopAndTranscribe(
        token: UUID,
        runID: UInt64,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget,
        cleanupMode: SmartCleanupMode
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
                    runID: runID,
                    trace: trace,
                    captureResult: captureResult,
                    rms: rms,
                    target: target,
                    cleanupMode: cleanupMode
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
        target: TranscriptDeliveryTarget,
        cleanupMode: SmartCleanupMode
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

        guard rms > Self.silenceRmsThreshold else {
            logger.debug("Audio below silence threshold: RMS \(rms) < \(Self.silenceRmsThreshold)")
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
            target: target,
            cleanupMode: cleanupMode
        )
    }

    private func beginNativeTranscription(
        samples: ContiguousArray<Float>,
        activeSampleCount: Int,
        rms: Float,
        token: UUID,
        runID: UInt64,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget,
        cleanupMode: SmartCleanupMode
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
                let text = try transcriber.transcribe(samples: samples, runID: runID)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            trace.markTranscriptionEnded()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                timeoutWorkItem.cancel()
                switch result {
                case .success(let text):
                    let isEligible = self.stateLock.withLock {
                        guard case let .transcribing(current, _, didTimeOut, didCancel) = self.state,
                              current == token else {
                            return false
                        }
                        return !didTimeOut && !didCancel && !self.isShuttingDown
                    }
                    guard isEligible else {
                        if case .timedOut = self.finishTranscription(token: token) {
                            self.retainFailedCapture(samples: samples, reason: .timedOut)
                        }
                        return
                    }
                    self.failedCaptureReplayBuffer.clear()
                    self.handleTranscriptionResult(
                        text,
                        token: token,
                        trace: trace,
                        activeDurationSeconds: Double(activeSampleCount) / Self.transcriptionSampleRate,
                        activeRMS: rms,
                        target: target,
                        cleanupMode: cleanupMode
                    )
                case .failure(let error):
                    switch self.finishTranscription(token: token) {
                    case .eligible:
                        self.retainFailedCapture(samples: samples, reason: .transcriptionFailed)
                        self.recordTerminal(trace: trace, outcome: .transcriptionFailed)
                        self.logger.error("Transcription failed: \(String(describing: error))")
                        self.feedback.notify(event: .error("Transcription failed"))
                    case .timedOut:
                        self.retainFailedCapture(samples: samples, reason: .timedOut)
                    case .cancelled, .stale:
                        break
                    }
                }
            }
        }
    }

    private func handleTranscriptionResult(
        _ text: String,
        token: UUID,
        trace: TranscriptionTrace,
        activeDurationSeconds: TimeInterval? = nil,
        activeRMS: Float? = nil,
        target: TranscriptDeliveryTarget = .unavailable,
        cleanupMode: SmartCleanupMode
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            settleNoSpeech(token: token, trace: trace)
            return
        }

        if cleanupMode == .exact {
            settleAcceptedTranscript(
                ProcessedTranscript(rawText: trimmed, finalText: trimmed),
                token: token,
                trace: trace,
                target: target
            )
            return
        }

        let hallucinationVerdict = hallucinationFilter.verdict(
            for: trimmed,
            activeDurationSeconds: activeDurationSeconds,
            activeRMS: activeRMS
        )
        if case .rejected(let reason) = hallucinationVerdict {
            logger.debug("Filtered transcript degeneration: \(String(describing: reason))")
            settleNoSpeech(token: token, trace: trace)
            return
        }

        let postProcessor = stateLock.withLock { transcriptPostProcessor }
        switch cleanupMode {
        case .exact:
            return
        case .basic:
            guard let transcript = processedTranscript(trimmed, using: postProcessor) else {
                settleNoSpeech(token: token, trace: trace)
                return
            }
            settleAcceptedTranscript(
                transcript,
                token: token,
                trace: trace,
                target: target
            )
        case .smart:
            guard let fallback = processedTranscript(trimmed, using: postProcessor) else {
                settleNoSpeech(token: token, trace: trace)
                return
            }
            beginSmartCleanup(
                rawTranscript: trimmed,
                fallback: fallback,
                postProcessor: postProcessor,
                token: token,
                trace: trace,
                target: target
            )
        }
    }

    private func beginSmartCleanup(
        rawTranscript: String,
        fallback: ProcessedTranscript,
        postProcessor: TranscriptPostProcessor,
        token: UUID,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
        let preparation = stateLock.withLock { () -> (
            sessionID: UUID,
            application: TranscriptDeliveryApplication,
            contextTask: Task<AppContext, Never>?,
            prewarmTask: Task<Void, Never>?
        )? in
            guard case let .transcribing(current, _, didTimeOut, didCancel) = state,
                  current == token,
                  !didTimeOut,
                  !didCancel,
                  !isShuttingDown,
                  let session = activeSmartCleanupSession else {
                return nil
            }
            return (
                session.id,
                session.application,
                session.contextTask,
                session.prewarmTask
            )
        }

        guard let preparation else {
            settleAcceptedTranscript(fallback, token: token, trace: trace, target: target)
            return
        }

        let corrections = MainActor.assumeIsolated {
            transcriptCorrectionStore?.allCorrections() ?? []
        }
        let provider = smartCleanupProvider
        let cleanupTask = Task<SmartCleanupResult, Never> {
            if let prewarmTask = preparation.prewarmTask {
                await prewarmTask.value
            }
            guard !Task.isCancelled else {
                return .failure(SmartCleanupFailure(reason: .cancelled, elapsed: 0))
            }

            let context: AppContext
            if let contextTask = preparation.contextTask {
                context = await contextTask.value
            } else {
                context = AppContext(
                    processIdentifier: preparation.application.processIdentifier,
                    appName: nil,
                    bundleIdentifier: preparation.application.bundleIdentifier,
                    windowTitle: nil,
                    selectedText: nil,
                    textBeforeCaret: nil
                )
            }
            guard !Task.isCancelled else {
                return .failure(SmartCleanupFailure(reason: .cancelled, elapsed: 0))
            }

            return await provider.clean(
                SmartCleanupRequest(
                    transcript: rawTranscript,
                    appContext: context,
                    corrections: corrections
                ),
                sessionID: preparation.sessionID
            )
        }

        let didInstall = stateLock.withLock { () -> Bool in
            guard case let .transcribing(current, _, didTimeOut, didCancel) = state,
                  current == token,
                  !didTimeOut,
                  !didCancel,
                  !isShuttingDown,
                  var session = activeSmartCleanupSession,
                  session.id == preparation.sessionID else {
                return false
            }
            session.cleanupTask = cleanupTask
            activeSmartCleanupSession = session
            return true
        }

        guard didInstall else {
            cleanupTask.cancel()
            Task { await provider.cancel(sessionID: preparation.sessionID) }
            return
        }

        Task { [weak self] in
            let result = await cleanupTask.value
            DispatchQueue.main.async { [weak self] in
                self?.completeSmartCleanup(
                    result,
                    rawTranscript: rawTranscript,
                    fallback: fallback,
                    postProcessor: postProcessor,
                    token: token,
                    sessionID: preparation.sessionID,
                    trace: trace,
                    target: target
                )
            }
        }
    }

    private func completeSmartCleanup(
        _ result: SmartCleanupResult,
        rawTranscript: String,
        fallback: ProcessedTranscript,
        postProcessor: TranscriptPostProcessor,
        token: UUID,
        sessionID: UUID,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        logSmartCleanupResult(result)

        let isCurrent = stateLock.withLock {
            guard case let .transcribing(current, _, _, _) = state,
                  current == token,
                  !isShuttingDown,
                  activeSmartCleanupSession?.id == sessionID else {
                return false
            }
            return true
        }
        guard isCurrent else { return }

        let transcript: ProcessedTranscript
        switch result {
        case .success(let response):
            if let processed = processedTranscript(response.text, using: postProcessor) {
                transcript = ProcessedTranscript(
                    rawText: rawTranscript,
                    finalText: processed.finalText
                )
            } else {
                transcript = fallback
            }
        case .failure:
            transcript = fallback
        }

        settleAcceptedTranscript(transcript, token: token, trace: trace, target: target)
    }

    private func logSmartCleanupResult(_ result: SmartCleanupResult) {
        let outcome: SmartCleanupLogOutcome
        switch result {
        case .success:
            outcome = .success
        case .failure(let failure):
            switch failure.reason {
            case .unavailable:
                outcome = .unavailable
            case .invalidRequest:
                outcome = .invalidRequest
            case .cancelled:
                outcome = .cancelled
            case .timedOut:
                outcome = .timedOut
            case .generationFailed:
                outcome = .generationFailed
            case .rejectedOutput:
                outcome = .rejectedOutput
            }
        }
        let elapsedMilliseconds = Int((result.elapsed * 1_000).rounded())
        logger.info(
            "Smart cleanup outcome=\(outcome.rawValue, privacy: .public) elapsed_ms=\(elapsedMilliseconds)"
        )
    }

    private func processedTranscript(
        _ text: String,
        using postProcessor: TranscriptPostProcessor
    ) -> ProcessedTranscript? {
        let processedTranscript = postProcessor.process(text)
        let finalText = processedTranscript.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return nil }
        return ProcessedTranscript(rawText: processedTranscript.rawText, finalText: finalText)
    }

    private func settleNoSpeech(token: UUID, trace: TranscriptionTrace) {
        guard case .eligible = finishTranscription(token: token) else { return }
        recordTerminal(trace: trace, outcome: .noSpeech)
        feedback.notify(event: .error("No speech detected"))
    }

    private func settleAcceptedTranscript(
        _ transcript: ProcessedTranscript,
        token: UUID,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
        guard case .eligible = finishTranscription(token: token) else { return }
        persistAndDeliverTranscript(transcript, trace: trace, target: target)
    }

    private func persistAndDeliverTranscript(
        _ settledTranscript: ProcessedTranscript,
        trace: TranscriptionTrace,
        target: TranscriptDeliveryTarget
    ) {
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
        let completion = stateLock.withLock { () -> (
            settlement: TranscriptionSettlement,
            cleanupSession: SmartCleanupSession?
        ) in
            guard case let .transcribing(current, _, didTimeOut, didCancel) = state,
                  current == token else {
                return (.stale, nil)
            }

            state = .idle
            activeTranscriptionTrace = nil
            activeReplayLease = nil
            activeRecordingSmartCleanupMode = nil
            let cleanupSession = activeSmartCleanupSession
            activeSmartCleanupSession = nil
            if didTimeOut { return (.timedOut, cleanupSession) }
            if didCancel { return (.cancelled, cleanupSession) }
            return (.eligible, cleanupSession)
        }

        if completion.settlement != .stale {
            cancelSmartCleanupSession(completion.cleanupSession)
            transitionRecordingFeedback(to: .hidden)
        }
        return completion.settlement
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

        cancelActiveSmartCleanupSession()
        transitionRecordingFeedback(to: .hidden)
        let transcriber = stateLock.withLock { self.transcriber }
        transcriber.cancel(runID: cancellation.runID)
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
