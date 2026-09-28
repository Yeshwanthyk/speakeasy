import AppKit
import CoreAudio
import SwiftUI

@MainActor
final class SettingsMicrophoneMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isLive = false
    private let snapshot: () -> MicrophoneLevelSnapshot
    private var sampler = LiveLevelSampler()
    private var timer: Timer?

    init(snapshot: @escaping () -> MicrophoneLevelSnapshot) { self.snapshot = snapshot }

    func start() {
        guard timer == nil else { return }
        sampler = LiveLevelSampler()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if level != 0 { level = 0 }
        if isLive { isLive = false }
    }

    private func tick() {
        let next = sampler.next(snapshot())
        // Quantise so an idle meter stops publishing once it has decayed.
        let rounded = (next * 100).rounded() / 100
        if level != rounded { level = rounded }
        if isLive != sampler.isLive { isLive = sampler.isLive }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var mode: DictationInvocationMode = .toggle
    @Published private(set) var overlayStyle = OverlayPreferences.style()
    @Published private(set) var showsLiveTranscript = OverlayPreferences.showsLiveText()

    func chooseOverlayStyle(_ style: OverlayStyle) {
        OverlayPreferences.setStyle(style)
        overlayStyle = style
    }

    func chooseLiveTranscript(_ enabled: Bool) {
        OverlayPreferences.setShowsLiveText(enabled)
        showsLiveTranscript = enabled
    }
    @Published private(set) var shortcut: DictationShortcut = .defaultShortcut
    @Published private(set) var canChangeShortcut = false
    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published private(set) var selectedDeviceUID: String?
    @Published private(set) var canChangeDevice = false
    @Published private(set) var modelKind: ASRModelKind = .parakeet110M
    @Published private(set) var requestedModel: ASRModelKind?
    @Published private(set) var modelError: String?
    private var failedModel: ASRModelKind?
    let microphoneMeter: SettingsMicrophoneMeter
    @Published private(set) var hasPasteTarget = false
    @Published private(set) var historyFeedback: String?
    @Published private(set) var records: [TranscriptRecord] = []
    @Published var fuzzyCorrectionsEnabled = FuzzyCorrectionPreference.isEnabled {
        didSet { UserDefaults.standard.set(fuzzyCorrectionsEnabled, forKey: FuzzyCorrectionPreference.key) }
    }
    @Published private(set) var summary: ProductivitySummary = DiagnosticsFormatter.summary(document: DiagnosticsDocument(), today: "")
    @Published private(set) var insights: SettingsInsights = .empty

    private let store: TranscriptStore
    private let diagnosticsStore: DiagnosticsStore?
    private let currentMode: () -> DictationInvocationMode
    private let setMode: (DictationInvocationMode) -> Void
    private let currentShortcut: () -> DictationShortcut
    private let changeShortcut: () -> Void
    private let resetShortcut: () -> Void
    private let shortcutEnabled: () -> Bool
    private let availableDevices: () -> [MicrophoneDevice]
    private let selectedDevice: () -> String?
    private let selectDevice: (String) -> Void
    private let deviceEnabled: () -> Bool
    private let currentModel: () -> ASRModelKind
    private let selectModel: (ASRModelKind) -> Void
    private var microphonePaneVisible = false
    private let frontmostApp: () -> NSRunningApplication?
    private let activateTarget: (NSRunningApplication) -> Bool
    private var pasteTarget: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private(set) var isVisible = false
    let openCorrections: () -> Void
    let pasteTranscript: (String) -> Void

    init(
        store: TranscriptStore,
        diagnosticsStore: DiagnosticsStore?,
        currentMode: @escaping () -> DictationInvocationMode,
        setMode: @escaping (DictationInvocationMode) -> Void,
        currentShortcut: @escaping () -> DictationShortcut,
        changeShortcut: @escaping () -> Void,
        resetShortcut: @escaping () -> Void,
        shortcutEnabled: @escaping () -> Bool,
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDevice: @escaping () -> String?,
        selectDevice: @escaping (String) -> Void,
        deviceEnabled: @escaping () -> Bool,
        currentModel: @escaping () -> ASRModelKind,
        selectModel: @escaping (ASRModelKind) -> Void,
        openCorrections: @escaping () -> Void,
        pasteTranscript: @escaping (String) -> Void,
        levelSnapshot: @escaping () -> MicrophoneLevelSnapshot = { MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0) },
        frontmostApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        activateTarget: @escaping (NSRunningApplication) -> Bool = { $0.activate(options: [.activateIgnoringOtherApps]) }
    ) {
        self.store = store
        self.diagnosticsStore = diagnosticsStore
        self.currentMode = currentMode
        self.setMode = setMode
        self.currentShortcut = currentShortcut
        self.changeShortcut = changeShortcut
        self.resetShortcut = resetShortcut
        self.shortcutEnabled = shortcutEnabled
        self.availableDevices = availableDevices
        self.selectedDevice = selectedDevice
        self.selectDevice = selectDevice
        self.deviceEnabled = deviceEnabled
        self.currentModel = currentModel
        self.selectModel = selectModel
        self.openCorrections = openCorrections
        self.pasteTranscript = pasteTranscript
        self.microphoneMeter = SettingsMicrophoneMeter(snapshot: levelSnapshot)
        self.frontmostApp = frontmostApp
        self.activateTarget = activateTarget
        refresh()
    }

    func refresh() {
        let newMode = currentMode()
        if mode != newMode { mode = newMode }
        let newShortcut = currentShortcut()
        if shortcut != newShortcut { shortcut = newShortcut }
        let shortcutAvailable = shortcutEnabled()
        if canChangeShortcut != shortcutAvailable { canChangeShortcut = shortcutAvailable }
        let uid = selectedDevice()
        if selectedDeviceUID != uid { selectedDeviceUID = uid }
        let deviceAvailable = deviceEnabled()
        if canChangeDevice != deviceAvailable { canChangeDevice = deviceAvailable }
        let kind = currentModel()
        if modelKind != kind { modelKind = kind }
        if requestedModel == modelKind { requestedModel = nil }
        let latest = Array(store.allRecords().reversed())
        if records.map(\.id) != latest.map(\.id) { records = latest }
        let metrics = diagnosticsStore?.productivitySummary()
            ?? DiagnosticsFormatter.summary(document: DiagnosticsDocument(), today: "")
        if summary != metrics { summary = metrics }
        let latestInsights = diagnosticsStore.map { SettingsInsights.make(document: $0.snapshot(), now: Date()) } ?? .empty
        if insights != latestInsights { insights = latestInsights }
    }

    var deviceEnumerator: () -> [MicrophoneDevice] { availableDevices }

    func updateDevices(_ latest: [MicrophoneDevice]) {
        guard isVisible else { return }
        if devices != latest { devices = latest }
        refresh()
    }

    func becameVisible() {
        isVisible = true
        refresh()
        if microphonePaneVisible { microphoneMeter.start() }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor [weak self] in self?.updatePasteTarget(app) }
            }
        }
    }

    func becameHidden() {
        isVisible = false
        microphoneMeter.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        pasteTarget = nil
        hasPasteTarget = false
    }

    func rememberPasteTarget() {
        guard let app = frontmostApp(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pasteTarget = app
        hasPasteTarget = !app.isTerminated
    }

    func updatePasteTarget(_ app: NSRunningApplication) {
        guard isVisible, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pasteTarget = app
        hasPasteTarget = !app.isTerminated
    }

    func setMicrophonePaneVisible(_ visible: Bool) {
        microphonePaneVisible = visible
        if visible && isVisible { microphoneMeter.start() } else { microphoneMeter.stop() }
    }

    func pasteHistory(_ text: String) {
        guard let target = pasteTarget, !target.isTerminated, activateTarget(target) else {
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(text, forType: .string)
            historyFeedback = copied ? "Transcript copied; no previous app available to paste into." : "Could not copy transcript."
            return
        }
        historyFeedback = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<20 {
                if self.frontmostApp()?.processIdentifier == target.processIdentifier {
                    self.pasteTranscript(text)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(text, forType: .string)
            self.historyFeedback = copied ? "Transcript copied; previous app did not become active." : "Could not copy transcript."
        }
    }

    func handleFeedback(_ event: UserFeedbackEvent) {
        if requestedModel != nil, case .modelSwitchFailed(let message) = event {
            failedModel = requestedModel
            modelError = message
            requestedModel = nil
        }
        if isVisible { refresh() }
    }

    func chooseMode(_ value: DictationInvocationMode) {
        guard value != mode else { return }
        setMode(value)
        refresh()
    }

    func changeShortcutNow() {
        guard canChangeShortcut else { return }
        changeShortcut()
        refresh()
    }

    func resetShortcutNow() {
        guard canChangeShortcut, shortcut != .defaultShortcut else { return }
        resetShortcut()
        refresh()
    }

    func chooseDevice(_ uid: String) {
        guard canChangeDevice, uid != (selectedDeviceUID ?? ""), uid.isEmpty || devices.contains(where: { $0.uid == uid }) else { return }
        selectDevice(uid)
        refresh()
    }

    func chooseModel(_ kind: ASRModelKind) {
        guard kind != modelKind else { return }
        modelError = nil
        failedModel = nil
        requestedModel = kind
        selectModel(kind)
        refresh()
    }

    func retryModel() {
        if let failedModel { chooseModel(failedModel) }
    }

    func clearHistory() async -> Bool {
        let persisted = await store.clear().value
        refresh()
        return persisted
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let deviceQueue = DispatchQueue(label: "speakeasy.settings.devices", qos: .utility)
    private var listening = false
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(model: SettingsModel, initialPage: SettingsPage = .general) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Speakeasy Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, initialPage: initialPage))
        window.setContentSize(NSSize(width: 880, height: 660))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func handleFeedback(_ event: UserFeedbackEvent) { model.handleFeedback(event) }

    func present() {
        model.rememberPasteTarget()
        installMainMenu()
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        model.becameVisible()
        refreshDevicesInBackground()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.rememberPasteTarget()
        model.becameVisible()
        refreshDevicesInBackground()
        guard !listening else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.isVisible else { return }
                self.refreshDevicesInBackground()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, deviceQueue, listener
        )
        listening = status == noErr
        if listening { deviceListener = listener }
    }

    private func refreshDevicesInBackground() {
        let enumerate = model.deviceEnumerator
        deviceQueue.async { [weak self] in
            let devices = enumerate()
            DispatchQueue.main.async { [weak self] in self?.model.updateDevices(devices) }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.becameHidden()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.becameVisible()
        refreshDevicesInBackground()
    }

    func windowWillClose(_ notification: Notification) {
        model.becameHidden()
        removeDeviceListener()
    }

    deinit {
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, deviceQueue, deviceListener)
        }
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, deviceQueue, deviceListener)
        self.deviceListener = nil
        listening = false
    }

    private func installMainMenu() {
        let main = NSApp.mainMenu ?? NSMenu()
        guard main.items.first(where: { $0.title == "Edit" }) == nil else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
