import AppKit
import Foundation
import SwiftUI

/// Persists whether the user finished first-run setup.
enum OnboardingStore {
    static let completedKey = "OnboardingCompleted"

    static func isComplete(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markComplete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    /// Setup runs until it has been completed once, and again whenever a
    /// permission it depends on has been revoked.
    static func needsOnboarding(
        isComplete: Bool,
        microphone: PermissionState,
        accessibility: PermissionState,
        inputMonitoring: PermissionState
    ) -> Bool {
        !isComplete || [microphone, accessibility, inputMonitoring].contains { $0 != .granted }
    }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case model
    case permissions
    case tryIt
    case done

    var id: Int { rawValue }

    /// Steps shown as page dots; Done is the destination, not a page.
    static let paged: [OnboardingStep] = [.welcome, .model, .permissions, .tryIt]

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .model: return "Model"
        case .permissions: return "Permissions"
        case .tryIt: return "Try It"
        case .done: return "Done"
        }
    }
}

enum OnboardingModelPhase: Equatable {
    case checking
    case downloading(received: Int64, expected: Int64)
    case verifying
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
}

enum OnboardingEnginePhase: Equatable {
    /// Waiting for the model and every permission.
    case waiting
    case starting
    case ready(warmedUp: Bool)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// A permission the setup flow asks for.
enum OnboardingPermission: CaseIterable, Hashable {
    case microphone
    case accessibility
    case inputMonitoring
}

/// What a permission row shows. `waiting` means Speakeasy asked and is
/// watching for the grant.
enum OnboardingPermissionStatus: Equatable {
    case needsRequest
    case waiting
    case allowed
}

/// Reads permission state. Injected so tests and snapshots can fake grants.
struct OnboardingPermissionClient {
    var microphone: @MainActor () -> PermissionState
    var accessibility: @MainActor () -> PermissionState
    var inputMonitoring: @MainActor () -> PermissionState
    /// Adds Speakeasy to the Input Monitoring list (and prompts once).
    var registerInputMonitoring: @MainActor () -> Void = {}

    static let live = OnboardingPermissionClient(
        microphone: { Permissions.microphoneState() },
        accessibility: { Permissions.accessibilityState() },
        inputMonitoring: { Permissions.inputMonitoringState() },
        registerInputMonitoring: { Permissions.requestInputMonitoring() }
    )
}

/// Owns first-run setup state. System APIs stay authoritative: permissions
/// are re-read on a timer and whenever Speakeasy becomes active.
@MainActor
final class OnboardingModel: ObservableObject {
    struct Actions {
        /// Builds the dictation engine and warms it; returns warmup success.
        var startEngine: @MainActor () async throws -> Bool
        var latestTranscript: @MainActor () -> TranscriptRecord?
        var currentShortcut: @MainActor () -> DictationShortcut
        var changeShortcut: @MainActor () -> Void
        var finish: @MainActor () -> Void
        var relaunch: @MainActor () -> Void
        /// How the latest dictation ended, so practice failures explain themselves.
        var latestAttempt: @MainActor () -> DictationAttempt? = { nil }
        var microphoneLevel: () -> MicrophoneLevelSnapshot = { MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0) }
        var microphoneName: @MainActor () -> String? = { nil }
        /// Opens System Settings for a permission and shows the drag guide.
        var openPermissionSettings: @MainActor (OnboardingPermission) -> Void = { _ in }
        var closePermissionGuide: @MainActor () -> Void = {}
        var playSuccessSound: @MainActor () -> Void = {}
    }

    /// Pause on the last green check before moving on, so the grant registers.
    static let advanceBeatNanoseconds: UInt64 = 700_000_000

    @Published var step: OnboardingStep = .welcome {
        didSet {
            guard step != oldValue else { return }
            movingForward = step.rawValue > oldValue.rawValue
            if step == .tryIt { armTranscriptTest() }
            if step == .tryIt, isLive { microphoneMeter.start() } else { microphoneMeter.stop() }
            if step == .done, isLive { actions.playSuccessSound() }
            if step != .permissions { actions.closePermissionGuide() }
        }
    }
    /// Direction of the last step change, for the page transition.
    @Published private(set) var movingForward = true
    /// Permissions asked for in this session that are not granted yet.
    @Published private(set) var requested: Set<OnboardingPermission> = []
    @Published private(set) var selectedModel: ASRModelKind
    @Published private(set) var modelPhase: OnboardingModelPhase = .checking
    @Published private(set) var enginePhase: OnboardingEnginePhase = .waiting
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .denied
    @Published private(set) var inputMonitoring: PermissionState = .denied
    @Published private(set) var shortcut: DictationShortcut = .defaultShortcut
    @Published private(set) var testTranscript: String?
    /// Why the last practice dictation produced no transcript.
    @Published private(set) var practiceHint: String?
    let microphoneMeter: SettingsMicrophoneMeter
    /// Set when a permission was requested in System Settings, so the UI can
    /// offer a relaunch if macOS does not report the grant to this process.
    @Published private(set) var visitedSystemSettings = false

    private let actions: Actions
    private let permissionClient: OnboardingPermissionClient
    /// False for snapshot previews: no downloads, polling, or sounds.
    private let isLive: Bool
    /// The permission whose System Settings guide is showing.
    private var guidedPermission: OnboardingPermission?
    private var installTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var testBaselineID: UUID?
    private var attemptBaseline: UInt64?
    private var testArmed = false

    init(
        actions: Actions,
        initialModel: ASRModelKind = (try? ModelPathResolver.configuredASRModelKind()) ?? .parakeet110M,
        permissionClient: OnboardingPermissionClient = .live,
        isLive: Bool = true
    ) {
        self.actions = actions
        self.selectedModel = initialModel
        self.permissionClient = permissionClient
        self.isLive = isLive
        self.microphoneMeter = SettingsMicrophoneMeter(snapshot: actions.microphoneLevel)
    }

    var permissionsGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    /// Dictation works once the model is loaded and every permission is on.
    /// The practice dictation is encouraged, not required.
    var canFinish: Bool {
        permissionsGranted && modelPhase.isInstalled && enginePhase.isReady
    }

    func state(of permission: OnboardingPermission) -> PermissionState {
        switch permission {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        if state(of: permission) == .granted { return .allowed }
        return requested.contains(permission) ? .waiting : .needsRequest
    }

    /// The first permission still missing; its button gets the primary style.
    var nextPermission: OnboardingPermission? {
        OnboardingPermission.allCases.first { state(of: $0) != .granted }
    }

    /// Moves one page; refuses to leave Permissions until everything is on.
    func advance() {
        advanceTask?.cancel()
        if step == .permissions, !permissionsGranted { return }
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func goBack() {
        advanceTask?.cancel()
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Plain-language list of what still blocks the test dictation.
    var engineBlockers: [String] {
        var blockers: [String] = []
        if !modelPhase.isInstalled { blockers.append("the speech model") }
        if microphone != .granted { blockers.append("Microphone access") }
        if accessibility != .granted { blockers.append("Accessibility access") }
        if inputMonitoring != .granted { blockers.append("Input Monitoring access") }
        return blockers
    }

    /// Best-effort read of the “Press 🌐 key to” setting. 0 means “Do Nothing”;
    /// the key is undocumented, so unknown values still show the tip.
    var functionKeyMayConflict: Bool {
        guard shortcut == .functionKey else { return false }
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value != 0
    }

    func start() {
        guard isLive else { return }
        refresh()
        beginInstall()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refresh()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        microphoneMeter.stop()
        pollTask?.cancel()
        pollTask = nil
        advanceTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        installTask?.cancel()
        actions.closePermissionGuide()
    }

    // MARK: Model

    var canChangeModel: Bool { enginePhase == .waiting }

    func selectModel(_ kind: ASRModelKind) {
        guard canChangeModel, kind != selectedModel else { return }
        selectedModel = kind
        ModelPathResolver.persistSelectedModelKind(kind)
        beginInstall()
    }

    func retryInstall() {
        beginInstall()
    }

    private func beginInstall() {
        installTask?.cancel()
        let kind = selectedModel
        modelPhase = .checking
        let downloader = ProgressReportingModelFileDownloader { [weak self] received, expected in
            Task { @MainActor in
                self?.reportProgress(kind: kind, received: received, expected: expected)
            }
        }
        installTask = Task { [weak self] in
            let result: Result<ASRModelConfiguration, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await ASRModelInstaller(downloader: downloader).resolveOrInstall(kind: kind))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled, let self, self.selectedModel == kind else { return }
            switch result {
            case .success:
                self.modelPhase = .installed
                self.startEngineIfPossible()
            case .failure(let error):
                self.modelPhase = .failed(Self.describe(error))
            }
        }
    }

    private func reportProgress(kind: ASRModelKind, received: Int64, expected: Int64?) {
        guard kind == selectedModel else { return }
        let total = expected ?? kind.artifact.expectedByteCount
        if received >= total {
            modelPhase = .verifying
            return
        }
        // Publish in 0.5% steps to keep SwiftUI updates cheap.
        if case .downloading(let previous, _) = modelPhase, total > 0,
           (received - previous) * 200 < total {
            return
        }
        modelPhase = .downloading(received: received, expected: total)
    }

    // MARK: Permissions

    func request(_ permission: OnboardingPermission) {
        guard state(of: permission) != .granted else { return }
        requested.insert(permission)
        switch permission {
        case .microphone where microphone == .notDetermined:
            // The system prompt answers either way; a refusal falls back to
            // System Settings on the next click.
            Task { [weak self] in
                do {
                    try await Permissions.requestMicrophoneAccess()
                } catch {
                    self?.requested.remove(.microphone)
                }
                self?.refresh()
            }
        case .inputMonitoring where !visitedSystemSettings:
            // Registers Speakeasy in the list so there is a switch to turn on.
            permissionClient.registerInputMonitoring()
            openSettings(for: permission)
        default:
            openSettings(for: permission)
        }
        refresh()
    }

    private func openSettings(for permission: OnboardingPermission) {
        visitedSystemSettings = true
        guidedPermission = permission
        actions.openPermissionSettings(permission)
    }

    /// Recovers from a stale grant: reset this app's entry, then ask again.
    func resetInputMonitoring() {
        Task { [weak self] in
            _ = await Permissions.resetInputMonitoring()
            Permissions.requestInputMonitoring()
            self?.refresh()
        }
    }

    func openKeyboardSettings() {
        Permissions.openKeyboardSettings()
    }

    func changeShortcut() {
        actions.changeShortcut()
        refresh()
    }

    func relaunch() {
        actions.relaunch()
    }

    func finish() {
        guard canFinish, isLive else { return }
        OnboardingStore.markComplete()
        stop()
        actions.finish()
    }

    // MARK: Engine and test dictation

    func retryEngine() {
        if case .failed = enginePhase { enginePhase = .waiting }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        guard enginePhase == .waiting, modelPhase.isInstalled, permissionsGranted else { return }
        enginePhase = .starting
        Task { [weak self] in
            guard let self else { return }
            do {
                let warmedUp = try await self.actions.startEngine()
                self.enginePhase = .ready(warmedUp: warmedUp)
                if self.step == .tryIt { self.armTranscriptTest() }
            } catch {
                self.enginePhase = .failed(Self.describe(error))
            }
        }
    }

    private func armTranscriptTest() {
        guard enginePhase.isReady, testTranscript == nil else { return }
        testBaselineID = actions.latestTranscript()?.id
        attemptBaseline = actions.latestAttempt()?.sequence
        practiceHint = nil
        testArmed = true
    }

    func refresh() {
        let wasGranted = permissionsGranted
        microphone = permissionClient.microphone()
        accessibility = permissionClient.accessibility()
        inputMonitoring = permissionClient.inputMonitoring()
        shortcut = actions.currentShortcut()
        requested = requested.filter { state(of: $0) != .granted }
        if let guided = guidedPermission, state(of: guided) == .granted {
            guidedPermission = nil
            actions.closePermissionGuide()
        }
        if !wasGranted, permissionsGranted, step == .permissions { scheduleAdvance() }
        startEngineIfPossible()

        if testArmed, testTranscript == nil,
           let latest = actions.latestTranscript(), latest.id != testBaselineID {
            let text = latest.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                testTranscript = text
                practiceHint = nil
            }
        }
        if testArmed, testTranscript == nil,
           let attempt = actions.latestAttempt(), attempt.sequence != attemptBaseline {
            let hint = PracticeHint.message(for: attempt.result, microphoneName: actions.microphoneName())
            if practiceHint != hint { practiceHint = hint }
        }
    }

    /// Lets the last check finish drawing, then moves on by itself.
    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.advanceBeatNanoseconds)
            guard !Task.isCancelled, let self, self.step == .permissions, self.permissionsGranted else { return }
            self.step = .tryIt
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as URLError where error.code == .notConnectedToInternet:
            return "You're offline. Connect to the internet and try again."
        case let error as URLError:
            return "Download failed (\(error.localizedDescription))."
        case ASRModelInstallError.checksumMismatch, ASRModelInstallError.unexpectedFileSize:
            return "The download was corrupted and has been discarded. Try again."
        case ASRModelInstallError.invalidHTTPStatus(_, let status):
            return "The model server returned HTTP \(status). Try again later."
        case PermissionError.microphoneDenied:
            return "Microphone access is required."
        default:
            return String(describing: error)
        }
    }
}

// MARK: - Preview states

/// A fixed onboarding state for snapshots and visual review.
struct OnboardingPreviewScenario {
    let name: String
    var step: OnboardingStep
    var modelPhase: OnboardingModelPhase = .installed
    var enginePhase: OnboardingEnginePhase = .ready(warmedUp: true)
    var microphone: PermissionState = .granted
    var accessibility: PermissionState = .granted
    var inputMonitoring: PermissionState = .granted
    var requested: Set<OnboardingPermission> = []
    var visitedSystemSettings = false
    var testTranscript: String?
    var practiceHint: String?

    static let all: [OnboardingPreviewScenario] = {
        let downloading = OnboardingModelPhase.downloading(received: 58_000_000, expected: 135_000_000)
        return [
            .init(name: "01-welcome", step: .welcome, modelPhase: downloading, enginePhase: .waiting,
                  microphone: .notDetermined, accessibility: .denied, inputMonitoring: .denied),
            .init(name: "02-model-downloading", step: .model, modelPhase: downloading, enginePhase: .waiting,
                  microphone: .notDetermined, accessibility: .denied, inputMonitoring: .denied),
            .init(name: "03-model-failed", step: .model,
                  modelPhase: .failed("You're offline. Connect to the internet and try again."), enginePhase: .waiting,
                  microphone: .notDetermined, accessibility: .denied, inputMonitoring: .denied),
            .init(name: "04-permissions-none", step: .permissions, modelPhase: downloading, enginePhase: .waiting,
                  microphone: .notDetermined, accessibility: .denied, inputMonitoring: .denied),
            .init(name: "05-permissions-waiting", step: .permissions, enginePhase: .waiting,
                  microphone: .granted, accessibility: .denied, inputMonitoring: .denied,
                  requested: [.accessibility], visitedSystemSettings: true),
            .init(name: "06-permissions-all", step: .permissions),
            .init(name: "07-try-loading", step: .tryIt, modelPhase: downloading, enginePhase: .waiting),
            .init(name: "08-try-ready", step: .tryIt),
            .init(name: "09-try-hint", step: .tryIt,
                  practiceHint: "Nothing was heard. Check that MacBook Pro Microphone is the right input."),
            .init(name: "10-try-success", step: .tryIt, testTranscript: "Hello from Speakeasy, this is my first dictation."),
            .init(name: "11-done", step: .done, testTranscript: "Hello from Speakeasy."),
        ]
    }()
}

extension OnboardingModel {
    /// A model frozen in `scenario`: nothing downloads, polls, or plays.
    static func preview(_ scenario: OnboardingPreviewScenario) -> OnboardingModel {
        let client = OnboardingPermissionClient(
            microphone: { scenario.microphone },
            accessibility: { scenario.accessibility },
            inputMonitoring: { scenario.inputMonitoring }
        )
        let model = OnboardingModel(
            actions: .init(
                startEngine: { true },
                latestTranscript: { nil },
                currentShortcut: { .functionKey },
                changeShortcut: {},
                finish: {},
                relaunch: {}
            ),
            initialModel: .parakeet110M,
            permissionClient: client,
            isLive: false
        )
        model.refresh()
        model.step = scenario.step
        model.modelPhase = scenario.modelPhase
        model.enginePhase = scenario.enginePhase
        model.requested = scenario.requested
        model.visitedSystemSettings = scenario.visitedSystemSettings
        model.testTranscript = scenario.testTranscript
        model.practiceHint = scenario.practiceHint
        return model
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    /// Called when the user closes the window before finishing.
    var onClose: (() -> Void)?

    static let contentSize = NSSize(width: 820, height: 640)

    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Speakeasy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
