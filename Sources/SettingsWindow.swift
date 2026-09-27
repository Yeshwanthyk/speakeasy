import AppKit
import SwiftUI

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
    @Published private(set) var records: [TranscriptRecord] = []
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
        pasteTranscript: @escaping (String) -> Void
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
        refresh()
    }

    func refresh() {
        mode = currentMode()
        shortcut = currentShortcut()
        canChangeShortcut = shortcutEnabled()
        devices = availableDevices()
        selectedDeviceUID = selectedDevice()
        canChangeDevice = deviceEnabled()
        modelKind = currentModel()
        if requestedModel == modelKind { requestedModel = nil }
        records = store.allRecords().reversed()
        summary = diagnosticsStore?.productivitySummary()
            ?? DiagnosticsFormatter.summary(document: DiagnosticsDocument(), today: "")
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
        guard canChangeDevice, uid != selectedDeviceUID, devices.contains(where: { $0.uid == uid }) else { return }
        selectDevice(uid)
        refresh()
    }

    func chooseModel(_ kind: ASRModelKind) {
        guard kind != modelKind else { return }
        requestedModel = kind
        selectModel(kind)
        refresh()
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
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
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
                    if model.devices.isEmpty {
                        Text("No microphones available")
                            .foregroundStyle(.secondary)
                    } else {
                        if model.selectedDeviceUID == nil {
                            Text("System Default is currently selected")
                                .foregroundStyle(.secondary)
                        }
                        Picker("Microphone", selection: Binding(
                            get: { model.selectedDeviceUID ?? "" },
                            set: { model.chooseDevice($0) }
                        )) {
                            ForEach(model.devices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .disabled(!model.canChangeDevice)
                    }
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
                        Text("Switch requested. Check the menu bar for errors if the active model does not change.")
                            .foregroundStyle(.secondary)
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
                    ForEach(model.records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.finalText).textSelection(.enabled)
                                Text(record.createdAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Paste") { model.pasteTranscript(record.finalText) }
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
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

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
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        model.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
