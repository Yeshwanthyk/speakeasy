import AppKit
import SwiftUI

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcut = "Shortcut"
    case microphone = "Microphone"
    case model = "Model"
    case corrections = "Corrections"
    case history = "History"
    case meetings = "Meetings"
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcut: return "keyboard"
        case .microphone: return "mic"
        case .model: return "cpu"
        case .corrections: return "text.badge.checkmark"
        case .history: return "clock"
        case .meetings: return "person.2"
        case .advanced: return "chart.bar"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How dictation starts and what you see while you speak."
        case .shortcut: return "The key that starts and stops dictation."
        case .microphone: return "Choose an input and check that it hears you."
        case .model: return "Speech recognition runs entirely on this Mac."
        case .corrections: return "Fix words the model gets wrong, automatically."
        case .history: return "Everything you've dictated, kept on this Mac."
        case .meetings: return "Record calls and keep transcripts of you and the other side."
        case .advanced: return "Your dictation stats, measured locally."
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: SettingsPage
    @State private var confirmClear = false
    @State private var historyError = false

    init(model: SettingsModel, initialPage: SettingsPage = .general) {
        self.model = model
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: SettingsMetrics.sidebarWidth)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                    PageHeader(page: selection)
                    page
                }
                .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pageGutter)
                .padding(.top, SettingsMetrics.pageTop)
                .padding(.bottom, SettingsMetrics.pageBottom)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 780, minHeight: 540)
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
    private var page: some View {
        switch selection {
        case .general: GeneralPage(model: model)
        case .shortcut: ShortcutPage(model: model)
        case .microphone: MicrophonePage(model: model)
        case .model: ModelPage(model: model)
        case .corrections: CorrectionsPage(model: model)
        case .history: HistoryPage(model: model, confirmClear: $confirmClear)
        case .meetings:
            if let meetings = model.meetings {
                MeetingsPage(controller: meetings)
            } else {
                SettingsEmptyState(
                    symbol: "hourglass",
                    title: "Meetings aren’t ready yet",
                    detail: "Meetings are unavailable until Speakeasy finishes starting."
                )
            }
        case .advanced: AdvancedPage(summary: model.summary, insights: model.insights)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: SpeakeasyBrand.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Speakeasy").font(.system(size: 13, weight: .semibold))
                    Text(Self.version).font(SettingsType.rowDetail).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 44)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)

            ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element.id) { index, page in
                SidebarRow(page: page, shortcutNumber: index + 1, isSelected: page == selection) {
                    selection = page
                }
            }
            Spacer(minLength: 0)
            Label("Private · on-device", systemImage: "lock")
                .font(SettingsType.rowDetail)
                .foregroundColor(.secondary)
                .padding(8)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial().ignoresSafeArea())
    }

    private static let version: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short.map { "Version \($0)" } ?? "Local dictation"
    }()
}

private struct SidebarRow: View {
    let page: SettingsPage
    /// 1–9 selects the page with ⌘ and that digit.
    let shortcutNumber: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(width: SettingsMetrics.rowIconWidth)
                Text(page.rawValue)
                    .font(SettingsType.sidebarItem.weight(isSelected ? .medium : .regular))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .fill(isSelected ? SettingsColors.selectedFill : hovering ? SettingsColors.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarShortcut(number: shortcutNumber))
        .onHover { hovering = $0 }
        .accessibilityLabel(page.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Binds ⌘1–⌘9 to the first nine pages.
private struct SidebarShortcut: ViewModifier {
    let number: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if (1...9).contains(number), let digit = String(number).first {
            content
                .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                .help("⌘\(number)")
        } else {
            content
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(page.rawValue)
                .font(SettingsType.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text(page.subtitle)
                .font(SettingsType.pageSubtitle)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(title: "Dictation") {
            SettingsRow(
                "Mode",
                detail: model.mode == .pushToTalk
                    ? "Hold the shortcut while you speak."
                    : "Press once to start, press again to stop."
            ) {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.chooseMode($0) })) {
                    Text("Hands-Free").tag(DictationInvocationMode.toggle)
                    Text("Push to Talk").tag(DictationInvocationMode.pushToTalk)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if model.mode == .pushToTalk && model.shortcut == .functionKey {
                Divider()
                ToggleRow(
                    title: "Double-tap fn to lock",
                    detail: "Tap fn twice quickly to keep dictating without holding it. Press fn again to finish.",
                    isOn: $model.doubleTapLockEnabled
                )
            }
        }

        SettingsCard(title: "Recording overlay") {
            HStack(spacing: 12) {
                OverlayChoice(style: .bottomPill, isSelected: model.overlayStyle == .bottomPill) {
                    model.chooseOverlayStyle(.bottomPill)
                }
                OverlayChoice(style: .topIndicator, isSelected: model.overlayStyle == .topIndicator) {
                    model.chooseOverlayStyle(.topIndicator)
                }
            }
            Divider()
            ToggleRow(
                title: "Show live transcript",
                detail: model.overlayStyle == .topIndicator
                    ? "Available with the bottom pill overlay."
                    : "Words appear in the pill as you speak.",
                isOn: Binding(get: { model.showsLiveTranscript }, set: { model.chooseLiveTranscript($0) })
            )
            .disabled(model.overlayStyle == .topIndicator)
        }
    }
}

private struct OverlayChoice: View {
    let style: OverlayStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: style == .bottomPill ? .bottom : .top) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    if style == .bottomPill {
                        HStack(spacing: 6) {
                            MiniWave(color: .white)
                            Capsule().fill(Color.white.opacity(0.7)).frame(width: 46, height: 3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 10)
                    } else {
                        MiniWave(color: .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.85))
                            )
                    }
                }
                .frame(height: 84)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(style == .bottomPill ? "Bottom pill" : "Top indicator").font(.system(size: 13, weight: .semibold))
                        Text(style == .bottomPill ? "Waveform with live text" : "Minimal, near the notch")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    SelectionMark(isSelected: isSelected)
                }
            }
            .padding(10)
            .selectableTileBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct MiniWave: View {
    let color: Color
    private static let heights: [CGFloat] = [4, 8, 12, 7, 10, 5, 9, 4]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.heights.indices, id: \.self) { index in
                Capsule().fill(color).frame(width: 2, height: Self.heights[index])
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Shortcut

private struct ShortcutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelGap) {
            SettingsCard {
                SettingsRow(
                    "Dictation shortcut",
                    detail: model.mode == .pushToTalk
                        ? "Hold to dictate, release to insert text."
                        : "Press to start dictating, press again to insert text."
                ) {
                    KeycapGroup(keys: Self.keys(for: model.shortcut), compact: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current shortcut: \(model.shortcut.displayName)")
                }
                Divider()
                SettingsRow("Change shortcut") {
                    HStack(spacing: 8) {
                        Button("Reset to fn") { model.resetShortcutNow() }
                            .disabled(!model.canChangeShortcut || model.shortcut == .defaultShortcut)
                        Button("Change Shortcut…") { model.changeShortcutNow() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canChangeShortcut)
                    }
                }
            }
            if !model.canChangeShortcut {
                SettingsNote(
                    text: "Finish the current dictation to change the shortcut.",
                    symbol: "exclamationmark.circle",
                    color: .orange
                )
            }
        }

        if model.shortcut == .functionKey {
            SettingsCard(title: "Tip") {
                SettingsRow(
                    "Stop the emoji picker from opening",
                    detail: "If pressing fn also opens emoji or macOS Dictation, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.",
                    symbol: "globe"
                ) {
                    Button("Open Keyboard Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    static func keys(for shortcut: DictationShortcut) -> [String] {
        shortcut.keycapLabels
    }
}

extension DictationShortcut {
    /// One label per physical key, for keycap-style displays.
    var keycapLabels: [String] {
        switch self {
        case .functionKey:
            return ["fn"]
        case .keyCombination(_, let modifiers, let keyLabel):
            return modifiers.displaySymbols.map(String.init) + [keyLabel.uppercased()]
        }
    }
}

/// A shortcut's keys side by side.
struct KeycapGroup: View {
    let keys: [String]
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(label: key, compact: compact)
            }
        }
    }
}

struct Keycap: View {
    let label: String
    /// Row-sized keys for settings rows; the large size is for onboarding.
    var compact = false

    private var radius: CGFloat { compact ? 5 : 12 }

    var body: some View {
        Text(label)
            .font(compact
                  ? .system(size: 12, weight: .medium, design: .rounded)
                  : .system(size: 26, weight: .semibold, design: .rounded))
            .frame(minWidth: compact ? 24 : 64, minHeight: compact ? 22 : 64)
            .padding(.horizontal, compact ? 5 : 8)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: compact ? 1 : 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}

// MARK: - Microphone

private struct MicrophonePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard {
            SettingsRow("Input device", detail: "Switch when dictation is idle.") {
                Picker("Input device", selection: Binding(
                    get: { model.selectedDeviceUID ?? "" },
                    set: { model.chooseDevice($0) }
                )) {
                    Text("System Default").tag("")
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(!model.canChangeDevice)
            }
            Divider()
            ToggleRow(
                title: "Keep AirPods out of call mode",
                detail: "When the system input is a Bluetooth headset, record from the Mac's built-in microphone so your headphones keep full audio quality. Only applies to System Default.",
                isOn: $model.avoidsBluetoothMicrophone
            )
        }

        SettingsCard(title: "Input level") {
            SettingsMicrophoneLevelView(meter: model.microphoneMeter, shortcut: model.shortcut.displayName)
        }
    }
}

struct SettingsMicrophoneLevelView: View {
    @ObservedObject var meter: SettingsMicrophoneMeter
    let shortcut: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: meter.isLive ? "Listening" : "Idle", tint: meter.isLive ? .green : .gray)
                Spacer()
                Text("\(Int(meter.level * 100))%")
                    .font(SettingsType.meta)
                    .foregroundStyle(.secondary)
            }
            SegmentedLevelMeter(level: meter.level, isLive: meter.isLive)
                .frame(height: 36)
                .accessibilityElement()
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(Int(meter.level * 100)) percent")
            Text(meter.isLive
                 ? "Speak normally — the bars should reach the yellow on louder words."
                 : "Waiting for audio. Press \(shortcut) and speak to test your microphone.")
                .font(SettingsType.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SegmentedLevelMeter: View {
    let level: Float
    let isLive: Bool
    private static let count = 40

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let width = (proxy.size.width - gap * CGFloat(Self.count - 1)) / CGFloat(Self.count)
            let lit = Int((CGFloat(level) * CGFloat(Self.count)).rounded(.up))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<Self.count, id: \.self) { index in
                    let fraction = CGFloat(index) / CGFloat(Self.count - 1)
                    Capsule()
                        .fill(isLive && index < lit ? Self.color(fraction) : SettingsColors.subtleFill)
                        .frame(width: width, height: proxy.size.height * (0.4 + 0.6 * sin(fraction * .pi)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: lit)
        }
    }

    static func color(_ fraction: CGFloat) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.82: return .yellow
        default: return .orange
        }
    }
}

// MARK: - Model

private struct ModelPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let error = model.modelError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
                Text(error)
                    .font(SettingsType.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { model.retryModel() }
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, SettingsMetrics.cardPaddingY)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.25))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Model error")
        }

        VStack(alignment: .leading, spacing: SettingsMetrics.labelGap) {
            SettingsCard {
                ForEach(Array(ASRModelKind.allCases.enumerated()), id: \.element.preferenceValue) { index, kind in
                    if index > 0 { Divider() }
                    ModelRow(
                        kind: kind,
                        isActive: kind == model.modelKind,
                        isRequested: model.requestedModel == kind,
                        isBusy: model.requestedModel != nil,
                        usage: model.insights.usage(of: kind)
                    ) { model.chooseModel(kind) }
                }
            }
            SettingsNote(
                text: "Switching downloads and verifies the model if needed, then warms it up. Your current model keeps working until the new one is ready.",
                symbol: "info.circle"
            )
        }
    }
}

private struct ModelRow: View {
    let kind: ASRModelKind
    let isActive: Bool
    let isRequested: Bool
    let isBusy: Bool
    let usage: Int
    let select: () -> Void

    private var facts: String {
        var parts = [
            kind.displayName,
            kind.artifact.license,
            SettingsFormat.bytes(kind.artifact.expectedByteCount),
            kind.settingsParameters,
        ]
        if usage > 0 { parts.append("\(usage.formatted()) dictations") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowControlGap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind.settingsSymbol)
                    .font(.system(size: 13))
                    .foregroundColor(isActive ? .accentColor : .secondary)
                    .frame(width: SettingsMetrics.rowIconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.settingsTitle).font(SettingsType.rowTitleEmphasis)
                    Text(kind.settingsTagline)
                        .font(SettingsType.rowDetail)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        RatingDots(title: "Speed", value: kind.settingsSpeed, tint: .accentColor)
                        RatingDots(title: "Accuracy", value: kind.settingsAccuracy, tint: .accentColor)
                    }
                    .padding(.top, 2)
                    Text(facts)
                        .font(SettingsType.meta)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(SettingsType.rowTitle)
                        .foregroundColor(.green)
                } else if isRequested {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").font(SettingsType.rowDetail).foregroundColor(.secondary)
                    }
                } else {
                    Button("Use Model", action: select).disabled(isBusy)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension ASRModelKind {
    var settingsTitle: String {
        switch self {
        case .parakeet110M: return "Parakeet Fast"
        case .parakeetUnified: return "Parakeet Accurate"
        }
    }

    var settingsTagline: String {
        switch self {
        case .parakeet110M: return "Small and quick. Great for everyday dictation and short messages."
        case .parakeetUnified: return "Larger and more precise with names, jargon, and long passages."
        }
    }

    var settingsParameters: String {
        switch self {
        case .parakeet110M: return "110M params"
        case .parakeetUnified: return "600M params"
        }
    }

    var settingsSymbol: String {
        switch self {
        case .parakeet110M: return "bolt.fill"
        case .parakeetUnified: return "sparkles"
        }
    }

    var settingsTint: Color {
        switch self {
        case .parakeet110M: return .teal
        case .parakeetUnified: return .purple
        }
    }

    var settingsSpeed: Int { self == .parakeet110M ? 5 : 3 }
    var settingsAccuracy: Int { self == .parakeet110M ? 3 : 5 }
}

struct RatingDots: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(SettingsType.rowDetail).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(index < value ? tint : SettingsColors.subtleFill)
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(title) \(value) of 5")
    }
}

// MARK: - Corrections

/// Offers a correction rule for fixes the user has made by hand twice.
private struct CorrectionSuggestionsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if !model.correctionSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelGap) {
                SettingsCard(title: "Suggested corrections") {
                    ForEach(Array(model.correctionSuggestions.enumerated()), id: \.element) { index, suggestion in
                        if index > 0 { Divider() }
                        SettingsRow("“\(suggestion.heard)” → “\(suggestion.written)”") {
                            HStack(spacing: 8) {
                                Button("Dismiss") { model.dismissSuggestion(suggestion) }
                                Button("Always Replace") { model.acceptSuggestion(suggestion) }
                            }
                        }
                    }
                }
                SettingsNote(text: "You fixed these by hand at least twice.")
            }
        }
    }
}

private struct FixTranscriptSheet: View {
    let original: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(original: String, save: @escaping (String) -> Void) {
        self.original = original
        self.save = save
        _text = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix transcript").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 420, minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == original)
            }
        }
        .padding(20)
    }
}

private struct CorrectionsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        CorrectionSuggestionsCard(model: model)

        SettingsCard {
            SettingsRow(
                "Personal corrections",
                detail: "Replace exact words or phrases after transcription — names, product terms, acronyms. Rules stay on this Mac."
            ) {
                Button("Edit Corrections…", action: model.openCorrections)
            }
            Divider()
            ToggleRow(
                title: "Fuzzy-match my correction terms",
                detail: "Experimental. Catches similar-sounding words; may occasionally substitute the wrong one. Applies after the next edit or restart.",
                isOn: $model.fuzzyCorrectionsEnabled
            )
        }

        CorrectionsImpact(records: model.records)
    }
}

private struct CorrectionsImpact: View {
    let records: [TranscriptRecord]

    private var changed: Int { records.filter { !($0.stageChanges ?? []).isEmpty }.count }

    private var stages: [(name: String, count: Int)] {
        let counts = Dictionary(records.flatMap { $0.stageChanges ?? [] }.map { ($0.stage, $0.count) }, uniquingKeysWith: +)
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        SettingsCard(title: "Recent impact") {
            if records.isEmpty {
                Text("Dictate a few times to see how often corrections kick in.")
                    .font(SettingsType.rowDetail)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 14) {
                    RingGauge(fraction: Double(changed) / Double(max(records.count, 1)), tint: .accentColor)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(changed) of \(records.count)")
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("recent dictations were cleaned up")
                            .font(SettingsType.rowDetail)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                let ranked = stages
                let top = ranked.first?.count ?? 1
                ForEach(ranked, id: \.name) { stage in
                    BarRow(
                        title: stage.name.capitalized,
                        value: "\(stage.count)",
                        fraction: Double(stage.count) / Double(max(top, 1)),
                        tint: .accentColor
                    )
                }
            }
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var model: SettingsModel
    @Binding var confirmClear: Bool
    @State private var query = ""
    @State private var editing: TranscriptRecord?

    private var filtered: [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.records }
        return model.records.filter { $0.finalText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        if model.records.isEmpty {
            SettingsEmptyState(
                symbol: "text.bubble",
                title: "No transcripts yet",
                detail: "Dictate with \(model.shortcut.displayName) and your transcripts will appear here."
            )
        } else {
            HStack(spacing: 8) {
                SearchField(prompt: "Search \(model.records.count) transcripts", query: $query)
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear All…", systemImage: "trash")
                }
            }
            .sheet(item: $editing) { record in
                FixTranscriptSheet(original: record.finalText) { fixed in
                    model.fixTranscript(record, text: fixed)
                }
            }
            if let feedback = model.historyFeedback {
                SettingsNote(text: feedback, symbol: "info.circle")
            }
            CorrectionSuggestionsCard(model: model)
            let records = filtered
            if records.isEmpty {
                SettingsEmptyState(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    detail: "No transcripts match “\(query)”."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { record in
                        if record.id != records.first?.id { Divider() }
                        HistoryRow(
                            record: record,
                            actionTitle: model.hasPasteTarget ? "Paste" : "Copy",
                            action: { model.pasteHistory(record.finalText) },
                            fix: { editing = record }
                        )
                    }
                }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.vertical, 2)
                .settingsCardBackground()
            }
        }
    }
}

/// A search well; Escape clears it.
private struct SearchField: View {
    let prompt: String
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .font(SettingsType.rowTitle)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(SettingsColors.subtleFill)
        )
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let actionTitle: String
    let action: () -> Void
    let fix: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.finalText)
                    .font(SettingsType.rowTitle)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(SettingsFormat.historyDate.string(from: record.createdAt)) · \(Self.wordCount(record.finalText)) words")
                    .font(SettingsType.meta)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Fix…", action: fix)
                    .help("Correct this transcript. Fix the same words twice and Speakeasy offers a correction rule.")
                Button(actionTitle, action: action)
            }
            .controlSize(.small)
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

// MARK: - Advanced

private struct AdvancedPage: View {
    let summary: ProductivitySummary
    let insights: SettingsInsights

    private static let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 10) {
            StatTile(
                symbol: "hourglass",
                value: SettingsFormat.duration(summary.timeSavedMs), title: "Time saved",
                detail: "vs typing at \(Int(ProductivitySummary.typingWordsPerMinute)) wpm"
            )
            StatTile(
                symbol: "text.alignleft",
                value: summary.lifetimeWords.formatted(), title: "Words dictated",
                detail: "\(summary.todayWords.formatted()) today"
            )
            StatTile(
                symbol: "waveform",
                value: summary.lifetimeDictations.formatted(), title: "Dictations",
                detail: "\(summary.todayDictations) today · ~\(insights.averageWordsPerDictation) words each"
            )
            StatTile(
                symbol: "checkmark.seal",
                value: SettingsFormat.percentage(summary.deliveryRate), title: "Delivered",
                detail: "Inserted or copied successfully"
            )
        }

        ActivityCard(insights: insights)
        SpeedCard(summary: summary)
        LatencyCard(summary: summary, insights: insights)
        if !insights.outcomes.isEmpty { OutcomesCard(insights: insights) }
    }
}

private struct StatTile: View {
    let symbol: String
    let value: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(SettingsType.rowDetail.weight(.medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(SettingsType.rowDetail)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, SettingsMetrics.cardPaddingY)
        .settingsCardBackground()
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityCard: View {
    let insights: SettingsInsights

    var body: some View {
        SettingsCard(title: "Last \(SettingsInsights.chartDayCount) days") {
            HStack(spacing: 6) {
                if insights.streakDays > 0 {
                    Chip(text: "\(insights.streakDays)-day streak", symbol: "flame")
                }
                Chip(text: "\(insights.chartWordsTotal.formatted()) words", symbol: "text.alignleft")
                if let best = insights.bestDay {
                    Chip(text: "Best: \(best.words.formatted()) on \(SettingsFormat.weekday.string(from: best.date))", symbol: "star")
                }
            }
            DayBars(days: insights.days).frame(height: 120)
        }
    }
}

private struct DayBars: View {
    let days: [SettingsInsights.Day]

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                let summary = "\(SettingsFormat.dayTooltip.string(from: day.date)): \(day.words.formatted()) words, \(day.dictations) dictations"
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Self.fill(for: day))
                        .frame(height: max(3, 84 * CGFloat(day.words) / CGFloat(peak)))
                    Text(SettingsFormat.weekdayInitial.string(from: day.date))
                        .font(.system(size: 10, weight: day.isToday ? .semibold : .regular))
                        .foregroundColor(day.isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help(summary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
            }
        }
    }

    /// One accent: today at full strength, other days softer, empty days a well.
    private static func fill(for day: SettingsInsights.Day) -> Color {
        guard day.words > 0 else { return SettingsColors.subtleFill }
        return day.isToday ? Color.accentColor : Color.accentColor.opacity(0.55)
    }
}

private struct SpeedCard: View {
    let summary: ProductivitySummary

    var body: some View {
        let typing = summary.estimatedTypingDurationMs
        let speaking = summary.speakingDurationMs
        let peak = max(typing, speaking, 1)
        SettingsCard(title: "Speaking vs typing") {
            BarRow(
                title: "Typing (estimated)",
                value: SettingsFormat.duration(typing),
                fraction: typing / peak,
                tint: Color.secondary.opacity(0.6)
            )
            BarRow(title: "Speaking", value: SettingsFormat.duration(speaking), fraction: speaking / peak, tint: .accentColor)
            Text(summary.usesEstimatedSpeakingDuration
                 ? "Older dictations use an estimated \(Int(ProductivitySummary.estimatedSpeakingWordsPerMinute)) words/min speaking pace."
                 : "Speaking time is measured from your recordings.")
                .font(SettingsType.rowDetail)
                .foregroundColor(.secondary)
        }
    }
}

private struct LatencyCard: View {
    let summary: ProductivitySummary
    let insights: SettingsInsights

    var body: some View {
        SettingsCard(title: "Release to text") {
            HStack(spacing: 24) {
                LatencyFigure(title: "Typical", milliseconds: summary.releaseToTextP50Ms)
                LatencyFigure(title: "Slowest 5%", milliseconds: summary.releaseToTextP95Ms)
            }
            if insights.latencySampleCount > 0 {
                let peak = max(insights.latency.map(\.count).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(insights.latency) { bucket in
                        VStack(spacing: 4) {
                            Text("\(bucket.count)").font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(bucket.count > 0 ? Palette.color(bucket.tone).opacity(0.85) : SettingsColors.subtleFill)
                                .frame(height: max(3, 56 * CGFloat(bucket.count) / CGFloat(peak)))
                            Text(bucket.id).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(bucket.id): \(bucket.count) dictations")
                    }
                }
                .frame(height: 88, alignment: .bottom)
                Text("Last \(insights.latencySampleCount) dictations, from releasing the shortcut to text being ready.")
                    .font(SettingsType.rowDetail)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct LatencyFigure: View {
    let title: String
    let milliseconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(SettingsType.rowDetail).foregroundColor(.secondary)
            Text(SettingsFormat.latency(milliseconds))
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let milliseconds else { return .secondary }
        if milliseconds < 700 { return .green }
        if milliseconds < 2_000 { return .yellow }
        return .orange
    }
}

private struct OutcomesCard: View {
    let insights: SettingsInsights
    private static let legendColumns = [GridItem(.adaptive(minimum: 170), alignment: .leading)]

    var body: some View {
        let total = max(insights.outcomeTotal, 1)
        SettingsCard(title: "What happened to each dictation") {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(insights.outcomes) { share in
                        Rectangle()
                            .fill(Palette.color(share.tone))
                            .frame(width: max(2, (proxy.size.width - 2 * CGFloat(insights.outcomes.count - 1)) * CGFloat(share.count) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            LazyVGrid(columns: Self.legendColumns, alignment: .leading, spacing: 6) {
                ForEach(insights.outcomes) { share in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(share.tone)).frame(width: 7, height: 7)
                        Text(share.id)
                        Text(share.count.formatted()).foregroundColor(.secondary).monospacedDigit()
                    }
                    .font(SettingsType.rowDetail)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Building blocks

/// Semantic colours for insight tones (good, slow, failed, …).
private enum Palette {
    static func color(_ tone: SettingsInsights.Tone) -> Color {
        switch tone {
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .gray: return .gray
        }
    }
}

/// A settings section: an optional sentence-case label on the row text edge,
/// above a raised card. Rows inside are separated with `Divider()`, which the
/// card's padding insets to the row text edge.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.labelGap) {
            if let title {
                Text(title)
                    .font(SettingsType.sectionLabel)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, SettingsMetrics.rowInset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.vertical, SettingsMetrics.cardPaddingY)
                .settingsCardBackground()
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            )
            .accessibilityHidden(true)
    }
}

struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
    }
}

extension View {
    func selectableTileBackground(isSelected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : SettingsColors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : SettingsColors.cardStroke, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
    }
}

/// A switch row: title and detail on the left, a small switch on the right.
struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint(detail)
        }
    }
}

/// A status tag: a dot and a word, never clickable.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(SettingsColors.subtleFill))
    }
}

private struct BarRow: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundColor(.secondary).monospacedDigit()
            }
            .font(SettingsType.rowDetail)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsColors.subtleFill)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct RingGauge: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(SettingsColors.subtleFill, lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }
}

// MARK: - Formatting

enum SettingsFormat {
    static let historyDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let weekdayInitial: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static let dayTooltip: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ count: Int64) -> String { byteFormatter.string(fromByteCount: count) }

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
        return String(format: "%.1f s", milliseconds / 1_000)
    }

    static func percentage(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }
}
