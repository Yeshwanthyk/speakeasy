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
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcut: return "keyboard.fill"
        case .microphone: return "mic.fill"
        case .model: return "cpu.fill"
        case .corrections: return "text.badge.checkmark"
        case .history: return "clock.fill"
        case .advanced: return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .shortcut: return .indigo
        case .microphone: return .red
        case .model: return .purple
        case .corrections: return .green
        case .history: return .blue
        case .advanced: return .orange
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
                .frame(width: 216)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(page: selection)
                    page
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
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
        case .advanced: AdvancedPage(summary: model.summary, insights: model.insights)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: SpeakeasyBrand.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speakeasy").font(.system(size: 14, weight: .semibold))
                    Text(Self.version).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 48)
            .padding(.bottom, 14)

            ForEach(SettingsPage.allCases) { page in
                SidebarRow(page: page, isSelected: page == selection) { selection = page }
            }
            Spacer(minLength: 0)
            Label("Private · on-device", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(10)
        }
        .padding(.horizontal, 10)
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 22)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        HStack(spacing: 14) {
            IconTile(symbol: page.symbol, tint: page.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.rawValue).font(.system(size: 22, weight: .bold))
                Text(page.subtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard(title: "Dictation mode") {
            HStack(spacing: 12) {
                ChoiceTile(
                    symbol: "hand.tap.fill",
                    title: "Hands-Free",
                    detail: "Press once to start, press again to stop.",
                    isSelected: model.mode == .toggle
                ) { model.chooseMode(.toggle) }
                ChoiceTile(
                    symbol: "hand.raised.fill",
                    title: "Push to Talk",
                    detail: "Hold the shortcut while you speak.",
                    isSelected: model.mode == .pushToTalk
                ) { model.chooseMode(.pushToTalk) }
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
        SettingsCard {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(Array(Self.keys(for: model.shortcut).enumerated()), id: \.offset) { _, key in
                        Keycap(label: key)
                    }
                }
                Text(model.mode == .pushToTalk
                     ? "Hold to dictate, release to insert text."
                     : "Press to start dictating, press again to insert text.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Change Shortcut…") { model.changeShortcutNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canChangeShortcut)
                    Button("Reset to fn") { model.resetShortcutNow() }
                        .disabled(!model.canChangeShortcut || model.shortcut == .defaultShortcut)
                }
                .controlSize(.large)
                if !model.canChangeShortcut {
                    Label("Finish the current dictation to change the shortcut.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }

        if model.shortcut == .functionKey {
            SettingsCard(title: "Tip") {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "globe", tint: .blue, size: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stop the emoji picker from opening")
                            .font(.system(size: 13, weight: .semibold))
                        Text("If pressing fn also opens emoji or macOS Dictation, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
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

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .frame(minWidth: 64, minHeight: 64)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}

// MARK: - Microphone

private struct MicrophonePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input device").font(.system(size: 13, weight: .semibold))
                    Text("Switch when dictation is idle.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
                .frame(maxWidth: 260)
                .disabled(!model.canChangeDevice)
            }
        }

        SettingsCard(title: "Input level") {
            SettingsMicrophoneLevelView(meter: model.microphoneMeter, shortcut: model.shortcut.displayName)
        }
    }
}

private struct SettingsMicrophoneLevelView: View {
    @ObservedObject var meter: SettingsMicrophoneMeter
    let shortcut: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: meter.isLive ? "Listening" : "Idle", tint: meter.isLive ? .green : .gray)
                Spacer()
                Text("\(Int(meter.level * 100))%")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            SegmentedLevelMeter(level: meter.level, isLive: meter.isLive)
                .frame(height: 44)
                .accessibilityElement()
                .accessibilityLabel("Microphone input level")
                .accessibilityValue("\(Int(meter.level * 100)) percent")
            Text(meter.isLive
                 ? "Speak normally — the bars should reach the yellow on louder words."
                 : "Waiting for audio. Press \(shortcut) and speak to test your microphone.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                        .fill(isLive && index < lit ? Self.color(fraction) : Color.primary.opacity(0.08))
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
        ForEach(ASRModelKind.allCases, id: \.preferenceValue) { kind in
            ModelCard(
                kind: kind,
                isActive: kind == model.modelKind,
                isRequested: model.requestedModel == kind,
                isBusy: model.requestedModel != nil,
                usage: model.insights.usage(of: kind)
            ) { model.chooseModel(kind) }
        }

        if let error = model.modelError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") { model.retryModel() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.12)))
        }

        Label(
            "Switching downloads and verifies the model if needed, then warms it up. Your current model keeps working until the new one is ready.",
            systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ModelCard: View {
    let kind: ASRModelKind
    let isActive: Bool
    let isRequested: Bool
    let isBusy: Bool
    let usage: Int
    let select: () -> Void

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: kind.settingsSymbol, tint: kind.settingsTint, size: 44)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(kind.settingsTitle).font(.system(size: 15, weight: .semibold))
                            if isActive { StatusPill(text: "Active", tint: .green) }
                        }
                        Text("\(kind.displayName) · \(kind.artifact.license)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(kind.settingsTagline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        RatingDots(title: "Speed", value: kind.settingsSpeed, tint: .teal)
                        RatingDots(title: "Accuracy", value: kind.settingsAccuracy, tint: .purple)
                    }
                    HStack(spacing: 6) {
                        Chip(text: SettingsFormat.bytes(kind.artifact.expectedByteCount), symbol: "arrow.down.circle")
                        Chip(text: kind.settingsParameters, symbol: "cpu")
                        if usage > 0 { Chip(text: "\(usage.formatted()) dictations", symbol: "waveform", tint: kind.settingsTint) }
                    }
                }
                Spacer(minLength: 8)
                Group {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                    } else if isRequested {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Use Model", action: select).disabled(isBusy)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(index < value ? tint : Color.primary.opacity(0.12))
                        .frame(width: 12, height: 5)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(title) \(value) of 5")
    }
}

// MARK: - Corrections

private struct CorrectionsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "character.book.closed.fill", tint: .green, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal corrections").font(.system(size: 13, weight: .semibold))
                    Text("Replace exact words or phrases after transcription — names, product terms, acronyms. Rules stay on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
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
                Text("Dictate a few times to see how often corrections kick in.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    RingGauge(fraction: Double(changed) / Double(max(records.count, 1)), tint: .green)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(changed) of \(records.count)").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("recent dictations were cleaned up").foregroundStyle(.secondary)
                    }
                }
                let top = stages.first?.count ?? 1
                ForEach(Array(stages.enumerated()), id: \.element.name) { index, stage in
                    BarRow(
                        title: stage.name.capitalized,
                        value: "\(stage.count)",
                        fraction: Double(stage.count) / Double(max(top, 1)),
                        tint: Palette.cycle[index % Palette.cycle.count]
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

    private var filtered: [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.records }
        return model.records.filter { $0.finalText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        if model.records.isEmpty {
            EmptyState(
                symbol: "text.bubble",
                title: "No transcripts yet",
                detail: "Dictate with \(model.shortcut.displayName) and your transcripts will appear here."
            )
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(model.records.count) transcripts", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            if let feedback = model.historyFeedback {
                Label(feedback, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if filtered.isEmpty {
                Text("No transcripts match “\(query)”.").foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 8) {
                ForEach(filtered) { record in
                    HistoryRow(record: record, actionTitle: model.hasPasteTarget ? "Paste" : "Copy") {
                        model.pasteHistory(record.finalText)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let actionTitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.finalText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(SettingsFormat.historyDate.string(from: record.createdAt), systemImage: "calendar")
                    Label("\(Self.wordCount(record.finalText)) words", systemImage: "text.alignleft")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .controlSize(.small)
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
        )
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

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                symbol: "hourglass", tint: .green,
                value: SettingsFormat.duration(summary.timeSavedMs), title: "Time saved",
                detail: "vs typing at \(Int(ProductivitySummary.typingWordsPerMinute)) wpm"
            )
            StatTile(
                symbol: "text.alignleft", tint: .blue,
                value: summary.lifetimeWords.formatted(), title: "Words dictated",
                detail: "\(summary.todayWords.formatted()) today"
            )
            StatTile(
                symbol: "waveform", tint: .purple,
                value: summary.lifetimeDictations.formatted(), title: "Dictations",
                detail: "\(summary.todayDictations) today · ~\(insights.averageWordsPerDictation) words each"
            )
            StatTile(
                symbol: "checkmark.seal.fill", tint: .orange,
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
    let tint: Color
    let value: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

private struct ActivityCard: View {
    let insights: SettingsInsights

    var body: some View {
        SettingsCard(title: "Last \(SettingsInsights.chartDayCount) days") {
            HStack(spacing: 8) {
                if insights.streakDays > 0 {
                    Chip(text: "\(insights.streakDays)-day streak", symbol: "flame.fill", tint: .orange)
                }
                Chip(text: "\(insights.chartWordsTotal.formatted()) words", symbol: "text.alignleft", tint: .blue)
                if let best = insights.bestDay {
                    Chip(text: "Best: \(best.words.formatted()) on \(SettingsFormat.weekday.string(from: best.date))", symbol: "star.fill", tint: .yellow)
                }
            }
            DayBars(days: insights.days).frame(height: 140)
        }
    }
}

private struct DayBars: View {
    let days: [SettingsInsights.Day]

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(day.words > 0
                              ? BarFill.gradient(highlight: day.isToday)
                              : BarFill.empty)
                        .frame(height: max(4, 100 * CGFloat(day.words) / CGFloat(peak)))
                    Text(SettingsFormat.weekdayInitial.string(from: day.date))
                        .font(.system(size: 10, weight: day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(SettingsFormat.dayTooltip.string(from: day.date)): \(day.words.formatted()) words, \(day.dictations) dictations")
            }
        }
    }
}

/// Concrete gradients for the day bars.
private enum BarFill {
    static func gradient(highlight: Bool) -> LinearGradient {
        LinearGradient(
            colors: highlight ? [.orange, .pink] : [.blue, .purple],
            startPoint: .bottom, endPoint: .top
        )
    }

    static let empty = LinearGradient(colors: [Color.primary.opacity(0.08)], startPoint: .bottom, endPoint: .top)
}

private struct SpeedCard: View {
    let summary: ProductivitySummary

    var body: some View {
        let typing = summary.estimatedTypingDurationMs
        let speaking = summary.speakingDurationMs
        let peak = max(typing, speaking, 1)
        SettingsCard(title: "Speaking vs typing") {
            BarRow(title: "Typing (estimated)", value: SettingsFormat.duration(typing), fraction: typing / peak, tint: .gray)
            BarRow(title: "Speaking", value: SettingsFormat.duration(speaking), fraction: speaking / peak, tint: .green)
            Text(summary.usesEstimatedSpeakingDuration
                 ? "Older dictations use an estimated \(Int(ProductivitySummary.estimatedSpeakingWordsPerMinute)) words/min speaking pace."
                 : "Speaking time is measured from your recordings.")
                .font(.caption).foregroundStyle(.secondary)
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
                Spacer()
            }
            if insights.latencySampleCount > 0 {
                let peak = max(insights.latency.map(\.count).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(insights.latency) { bucket in
                        VStack(spacing: 4) {
                            Text("\(bucket.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Palette.color(bucket.tone).opacity(bucket.count > 0 ? 0.85 : 0.15))
                                .frame(height: max(3, 60 * CGFloat(bucket.count) / CGFloat(peak)))
                            Text(bucket.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96, alignment: .bottom)
                Text("Last \(insights.latencySampleCount) dictations, from releasing the shortcut to text being ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LatencyFigure: View {
    let title: String
    let milliseconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(SettingsFormat.latency(milliseconds))
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
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
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(insights.outcomes) { share in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(share.tone)).frame(width: 8, height: 8)
                        Text(share.id)
                        Text(share.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Building blocks

private enum Palette {
    static let cycle: [Color] = [.green, .blue, .purple, .orange, .pink, .teal]

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

struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
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

struct ChoiceTile: View {
    let symbol: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SelectionMark(isSelected: isSelected)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectableTileBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}

struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct BarRow: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
            .frame(height: 8)
        }
    }
}

private struct RingGauge: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
