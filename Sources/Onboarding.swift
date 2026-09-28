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
    }

    @Published var step: OnboardingStep = .welcome {
        didSet { if step == .tryIt, oldValue != .tryIt { armTranscriptTest() } }
    }
    @Published private(set) var selectedModel: ASRModelKind
    @Published private(set) var modelPhase: OnboardingModelPhase = .checking
    @Published private(set) var enginePhase: OnboardingEnginePhase = .waiting
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .denied
    @Published private(set) var inputMonitoring: PermissionState = .denied
    @Published private(set) var shortcut: DictationShortcut = .defaultShortcut
    @Published private(set) var testTranscript: String?
    /// Set when a permission was requested in System Settings, so the UI can
    /// offer a relaunch if macOS does not report the grant to this process.
    @Published private(set) var visitedSystemSettings = false

    private let actions: Actions
    private var installTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var testBaselineID: UUID?
    private var testArmed = false

    init(actions: Actions, initialModel: ASRModelKind = (try? ModelPathResolver.configuredASRModelKind()) ?? .parakeet110M) {
        self.actions = actions
        self.selectedModel = initialModel
    }

    var permissionsGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    var canFinish: Bool {
        permissionsGranted && modelPhase.isInstalled && enginePhase.isReady && testTranscript != nil
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
        refresh()
        beginInstall()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        installTask?.cancel()
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

    func requestMicrophone() {
        switch microphone {
        case .notDetermined:
            Task { [weak self] in
                _ = try? await Permissions.requestMicrophoneAccess()
                self?.refresh()
            }
        case .denied:
            visitedSystemSettings = true
            Permissions.openMicrophoneSettings()
        case .granted:
            break
        }
    }

    func requestAccessibility() {
        visitedSystemSettings = true
        if !Permissions.ensureAccessibilityPrompted() {
            Permissions.openAccessibilitySettings()
        }
        refresh()
    }

    func requestInputMonitoring() {
        visitedSystemSettings = true
        if !Permissions.requestInputMonitoring() {
            Permissions.openInputMonitoringSettings()
        }
        refresh()
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
        guard canFinish else { return }
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
        testArmed = true
    }

    private func refresh() {
        microphone = Permissions.microphoneState()
        accessibility = Permissions.accessibilityState()
        inputMonitoring = Permissions.inputMonitoringState()
        shortcut = actions.currentShortcut()
        startEngineIfPossible()

        if testArmed, testTranscript == nil,
           let latest = actions.latestTranscript(), latest.id != testBaselineID {
            let text = latest.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { testTranscript = text }
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

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    /// Called when the user closes the window before finishing.
    var onClose: (() -> Void)?

    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
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
        window.setContentSize(NSSize(width: 680, height: 580))
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
