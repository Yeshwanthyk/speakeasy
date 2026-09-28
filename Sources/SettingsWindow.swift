import AppKit
import CoreAudio
import SwiftUI

@MainActor
final class SettingsMicrophoneMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    private let snapshot: () -> MicrophoneLevelSnapshot
    private var timer: Timer?

    init(snapshot: @escaping () -> MicrophoneLevelSnapshot) { self.snapshot = snapshot }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next = self.snapshot().normalizedLevel
                if self.level != next { self.level = next }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var mode: DictationInvocationMode = .toggle
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

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcut = "Shortcut"
    case microphone = "Microphone"
    case model = "Model"
    case corrections = "Corrections"
    case history = "History"
    case advanced = "Advanced"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcut: return "keyboard"
        case .microphone: return "mic"
        case .model: return "waveform"
        case .corrections: return "text.badge.checkmark"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "chart.bar.xaxis"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: SettingsPage? = .general
    @State private var confirmClear = false
    @State private var historyError = false

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((selection ?? .general).rawValue)
                        .font(.title2.weight(.semibold))
                    pageContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: selection) { page in model.setMicrophonePaneVisible(page == .microphone) }
        .alert("Clear transcript history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                Task { historyError = !(await model.clearHistory()) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all saved transcripts from this Mac.")
        }
        .alert("Couldn’t Clear History", isPresented: $historyError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The history could not be saved. Please try again.")
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selection ?? .general {
        case .general:
            Form {
                Section("Dictation") {
                    Picker("Mode", selection: Binding(
                        get: { model.mode },
                        set: { model.chooseMode($0) }
                    )) {
                        ForEach(DictationInvocationMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("Hands-Free starts and stops with a press. Push to Talk records while you hold the shortcut.")
                        .foregroundStyle(.secondary)
                }
            }
        case .shortcut:
            Form {
                Section("Dictation shortcut") {
                    SettingsRow("Current shortcut", value: model.shortcut.displayName)
                    HStack {
                        Button("Change Shortcut…") { model.changeShortcutNow() }
                            .disabled(!model.canChangeShortcut)
                        Button("Reset to fn") { model.resetShortcutNow() }
                            .disabled(!model.canChangeShortcut || model.shortcut == .defaultShortcut)
                    }
                    Text("The shortcut starts and stops dictation. You can’t change it during a recording.")
                        .foregroundStyle(.secondary)
                }
            }
        case .microphone:
            Form {
                Section("Input device") {
                    Picker("Microphone", selection: Binding(
                        get: { model.selectedDeviceUID ?? "" },
                        set: { model.chooseDevice($0) }
                    )) {
                        Text("System Default").tag("")
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .disabled(!model.canChangeDevice)
                    SettingsMicrophoneLevelView(meter: model.microphoneMeter)
                    Text("Switch microphones when dictation is idle. Changes take effect after the input is ready.")
                        .foregroundStyle(.secondary)
                }
            }
        case .model:
            Form {
                Section("Speech model") {
                    ForEach(ASRModelKind.allCases, id: \.preferenceValue) { kind in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(kind.displayName)
                                if kind == model.modelKind {
                                    Text("Active").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if kind == model.modelKind {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            } else {
                                Button(model.requestedModel == kind ? "Requested" : "Use Model") {
                                    model.chooseModel(kind)
                                }
                                .disabled(model.requestedModel != nil && model.requestedModel != kind)
                            }
                        }
                    }
                    Text("Switching may download and verify the model, then warm it locally. Your current model stays active until the new one is ready.")
                        .foregroundStyle(.secondary)
                    if model.requestedModel != nil {
                        ProgressView("Switching model…")
                    }
                    if let error = model.modelError {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { model.retryModel() }
                    }
                }
            }
        case .corrections:
            Form {
                Section("Personal corrections") {
                    Text("Replace exact words or phrases after transcription. Rules stay on this Mac.")
                        .foregroundStyle(.secondary)
                    Button("Open Corrections Editor…", action: model.openCorrections)
                }
                Section("Post-processing") {
                    Toggle("Fuzzy-match my correction terms (experimental)", isOn: $model.fuzzyCorrectionsEnabled)
                    Text("Takes effect after the next correction edit or app restart. May substitute similar-sounding words.")
                        .foregroundStyle(.secondary)
                    let changed = model.records.filter { !($0.stageChanges ?? []).isEmpty }.count
                    Text("Changed \(changed) of last \(model.records.count) dictations")
                    let counts = Dictionary(model.records.flatMap { $0.stageChanges ?? [] }
                        .map { ($0.stage, $0.count) }, uniquingKeysWith: +)
                    ForEach(counts.keys.sorted(), id: \.self) { stage in
                        Text("\(stage): \(counts[stage, default: 0])")
                    }
                }
            }
        case .history:
            VStack(alignment: .leading, spacing: 12) {
                if model.records.isEmpty {
                    Text("No transcripts yet. Dictate with \(model.shortcut.displayName) to see them here.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(model.records.count) saved transcripts")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear History…") { confirmClear = true }
                    }
                    if let feedback = model.historyFeedback {
                        Text(feedback).foregroundStyle(.secondary)
                    }
                    ForEach(model.records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.finalText).textSelection(.enabled)
                                Text(SettingsMetrics.historyDate.string(from: record.createdAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.hasPasteTarget ? "Paste" : "Copy") { model.pasteHistory(record.finalText) }
                        }
                        Divider()
                    }
                }
            }
        case .advanced:
            Form {
                Section("Dictation impact") {
                    SettingsRow("Estimated time saved", value: SettingsMetrics.duration(model.summary.timeSavedMs))
                    SettingsRow("Words dictated", value: model.summary.lifetimeWords.formatted())
                    SettingsRow("Dictations", value: model.summary.lifetimeDictations.formatted())
                    SettingsRow("Delivered", value: SettingsMetrics.percentage(model.summary.deliveryRate))
                    SettingsRow("Today", value: "\(model.summary.todayWords) words from \(model.summary.todayDictations) dictations")
                    Text("Compared with typing at \(Int(ProductivitySummary.typingWordsPerMinute)) words per minute.")
                        .foregroundStyle(.secondary)
                }
                Section("Technical details") {
                    SettingsRow("Typical release to text", value: SettingsMetrics.latency(model.summary.releaseToTextP50Ms))
                    SettingsRow("95% release to text", value: SettingsMetrics.latency(model.summary.releaseToTextP95Ms))
                    SettingsRow("Estimated typing time", value: SettingsMetrics.duration(model.summary.estimatedTypingDurationMs))
                    SettingsRow("Measured dictation time", value: SettingsMetrics.duration(model.summary.speakingDurationMs))
                    if model.summary.usesEstimatedSpeakingDuration {
                        SettingsRow("Older dictation pace estimate", value: "\(Int(ProductivitySummary.estimatedSpeakingWordsPerMinute)) words/min")
                    }
                }
            }
        }
    }
}

private struct SettingsMicrophoneLevelView: View {
    @ObservedObject var meter: SettingsMicrophoneMeter

    var body: some View {
        Text("Live input level")
        ProgressView(value: Double(meter.level), total: 1)
            .accessibilityLabel("Microphone input level")
        Text("\(Int(meter.level * 100))%")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private enum SettingsMetrics {
    static let historyDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    static func duration(_ milliseconds: Double) -> String {
        let seconds = max(milliseconds, 0) / 1_000
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        return String(format: "%.1f hr", minutes / 60)
    }

    static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1_000 { return "\(Int(milliseconds.rounded())) ms" }
        return String(format: "%.1f sec", milliseconds / 1_000)
    }

    static func percentage(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let deviceQueue = DispatchQueue(label: "speakeasy.settings.devices", qos: .utility)
    private var listening = false
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(model: SettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speakeasy Settings"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
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
