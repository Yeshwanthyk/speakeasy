import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            OnboardingFooter(model: model)
                .frame(width: OnboardingMetrics.columnWidth)
                .padding(.bottom, OnboardingMetrics.footerBottom)
        }
        .frame(
            width: OnboardingWindowController.contentSize.width,
            height: OnboardingWindowController.contentSize.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topBar: some View {
        OnboardingModelPill(phase: model.modelPhase, retry: model.retryInstall)
            .opacity(model.step == .model ? 0 : 1)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: OnboardingMetrics.topBarHeight)
    }

    private var page: some View {
        ZStack {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .model: ModelStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .tryIt: TryItStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(width: OnboardingMetrics.columnWidth)
            .id(model.step)
            .transition(pageTransition)
        }
        .animation(OnboardingMotion.response, value: model.step)
    }

    /// Pages slide a few points in the direction of travel; opacity only
    /// under Reduce Motion.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = model.movingForward ? 10 : -10
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset)),
            removal: .opacity.combined(with: .offset(x: -offset / 2))
        )
    }
}

// MARK: - Footer

private struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            if model.step == .done {
                primary
            } else {
                OnboardingPageDots(current: model.step)
                HStack(spacing: 0) {
                    slot(alignment: .leading) { back }
                    Color.clear
                    slot(alignment: .trailing) { primary }
                }
            }
        }
        .frame(height: 32)
    }

    /// Fixed-width slot so an empty Back still holds its space.
    private func slot<Content: View>(alignment: Alignment, @ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .frame(width: OnboardingMetrics.footerSlot)
            .overlay(content(), alignment: alignment)
    }

    @ViewBuilder private var back: some View {
        if model.step != .welcome, model.step != .done {
            Button("Back", action: model.goBack)
                .buttonStyle(OnboardingButtonStyle(kind: .secondary))
        }
    }

    @ViewBuilder private var primary: some View {
        switch model.step {
        case .welcome:
            forward("Get started")
        case .model:
            forward("Continue")
        case .permissions:
            forward("Continue").disabled(!model.permissionsGranted)
        case .tryIt:
            if model.testTranscript == nil {
                Button("Skip", action: model.advance)
                    .buttonStyle(OnboardingButtonStyle(kind: .secondary))
            } else {
                forward("Continue")
            }
        case .done:
            Button("Start dictating", action: model.finish)
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFinish)
        }
    }

    private func forward(_ title: String) -> some View {
        Button(title, action: model.advance)
            .buttonStyle(OnboardingButtonStyle(showsArrow: true))
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 36) {
            OnboardingHero()
            OnboardingHeading(
                title: "Welcome to Speakeasy",
                lead: "Press a key, say what you mean, and Speakeasy types it wherever your cursor is. Your voice is transcribed on this Mac."
            )
        }
        .padding(.bottom, 24)
    }
}

// MARK: - Model

private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: OnboardingMetrics.sectionGap) {
            OnboardingHeading(
                title: "Pick a speech model",
                lead: "Both run entirely on this Mac. You can switch any time in Settings."
            )
            VStack(spacing: 10) {
                ForEach(ASRModelKind.allCases, id: \.self) { kind in
                    ModelChoice(
                        kind: kind,
                        isSelected: kind == model.selectedModel,
                        isRecommended: kind == .parakeet110M,
                        isEnabled: model.canChangeModel
                    ) { model.selectModel(kind) }
                }
                ModelDownloadStatus(model: model)
                    .frame(minHeight: 34)
            }
        }
    }
}

private struct ModelChoice: View {
    let kind: ASRModelKind
    let isSelected: Bool
    let isRecommended: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.settingsSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kind.settingsTitle).font(.system(size: 14, weight: .semibold))
                        if isRecommended { Tag(text: "Recommended") }
                    }
                    Text(kind.settingsTagline)
                        .font(OnboardingType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Fact(label: "Size", value: SettingsFormat.bytes(kind.artifact.expectedByteCount))
                        Fact(label: "Model", value: kind.settingsParameters)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SelectionMark(isSelected: isSelected)
            }
            .padding(14)
            .background(tileBackground)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
        .disabled(!isEnabled && !isSelected)
        .opacity(!isEnabled && !isSelected ? 0.5 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(OnboardingMotion.response, value: isSelected)
    }

    private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape.fill(SettingsColors.cardFill)
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : SettingsColors.cardStroke,
                                        lineWidth: isSelected ? 1.5 : 1))
            .shadow(color: .black.opacity(isSelected ? 0.07 : 0.03), radius: 6, y: 2)
    }
}

/// Scales a whole tile down slightly while pressed.
private struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(OnboardingMotion.press, value: configuration.isPressed)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SettingsColors.subtleFill))
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 11))
    }
}

private struct ModelDownloadStatus: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        Group {
            switch model.modelPhase {
            case .checking:
                progress("Checking for a saved copy…", detail: nil, fraction: nil)
            case .downloading(let received, let expected):
                progress(
                    "Downloading \(model.selectedModel.settingsTitle)",
                    detail: "\(SettingsFormat.bytes(received)) of \(SettingsFormat.bytes(expected))",
                    fraction: expected > 0 ? Double(received) / Double(expected) : nil
                )
            case .verifying:
                progress("Verifying the download…", detail: nil, fraction: 1)
            case .installed:
                Label("\(model.selectedModel.settingsTitle) is ready", systemImage: "checkmark")
                    .font(OnboardingType.caption)
                    .foregroundStyle(OnboardingColors.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                HStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(OnboardingType.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try again", action: model.retryInstall)
                        .buttonStyle(OnboardingButtonStyle(kind: .secondary))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private func progress(_ title: String, detail: String?, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail { Text(detail).monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(OnboardingType.caption)
            OnboardingProgressBar(fraction: fraction).frame(height: 4)
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: OnboardingMetrics.sectionGap) {
            OnboardingHeading(title: "Let Speakeasy hear you and type for you")
            OnboardingCard {
                ForEach(Array(OnboardingPermission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 { OnboardingRowDivider() }
                    PermissionRow(
                        permission: permission,
                        copy: PermissionCopy(permission, state: model.state(of: permission),
                                             status: model.status(of: permission)),
                        status: model.status(of: permission),
                        isNext: model.nextPermission == permission
                    ) { model.request(permission) }
                }
            }
            recovery.frame(minHeight: 56, alignment: .top)
        }
        .padding(.top, 24)
    }

    /// Shown only after a trip to System Settings that did not stick.
    @ViewBuilder private var recovery: some View {
        if model.visitedSystemSettings, !model.permissionsGranted {
            VStack(spacing: 8) {
                Text("Switched it on but it still shows as off? The entry may belong to an older copy of Speakeasy.")
                    .font(OnboardingType.rowDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if model.inputMonitoring != .granted {
                        Button("Reset Input Monitoring", action: model.resetInputMonitoring)
                    }
                    Button("Restart Speakeasy", action: model.relaunch)
                }
                .buttonStyle(.link)
                .font(OnboardingType.rowDetail)
            }
            .frame(maxWidth: OnboardingMetrics.leadWidth)
            .transition(.opacity)
        }
    }
}

/// Row wording, which shifts once Speakeasy has asked.
private struct PermissionCopy {
    let symbol: String
    let title: String
    let detail: String
    let buttonTitle: String

    init(_ permission: OnboardingPermission, state: PermissionState, status: OnboardingPermissionStatus) {
        switch permission {
        case .microphone:
            symbol = "mic"
            title = "Microphone"
            detail = state == .denied
                ? "Turned off earlier. Switch Speakeasy on in System Settings."
                : "Hears you only while you dictate"
            buttonTitle = state == .denied ? "Open Settings" : "Allow"
        case .accessibility:
            symbol = "character.cursor.ibeam"
            title = "Accessibility"
            detail = status == .waiting
                ? "Drag Speakeasy into the list, or switch it on if it is there"
                : "Pastes your words into the app you're using"
            buttonTitle = "Allow"
        case .inputMonitoring:
            symbol = "keyboard"
            title = "Input Monitoring"
            detail = status == .waiting
                ? "Switch Speakeasy on in the list"
                : "Notices your shortcut while other apps are in front"
            buttonTitle = "Allow"
        }
    }
}

private struct PermissionRow: View {
    let permission: OnboardingPermission
    let copy: PermissionCopy
    let status: OnboardingPermissionStatus
    let isNext: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: copy.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title).font(OnboardingType.rowTitle)
                Text(copy.detail)
                    .font(OnboardingType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(nil, value: copy.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PermissionControl(title: copy.buttonTitle, status: status, isNext: isNext, action: action)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: OnboardingMetrics.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

/// Allow → (pulsing dot) → ✓ Allowed, in one slot so nothing shifts.
private struct PermissionControl: View {
    let title: String
    let status: OnboardingPermissionStatus
    let isNext: Bool
    let action: () -> Void
    @Environment(\.onboardingIsStatic) private var isStatic
    @State private var checkProgress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            if status == .allowed {
                allowed
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                HStack(spacing: 12) {
                    if status == .waiting { OnboardingPulseDot().transition(.opacity) }
                    Button(title, action: action)
                        .buttonStyle(OnboardingButtonStyle(kind: isNext ? .primary : .secondary))
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 96, alignment: .trailing)
        .animation(OnboardingMotion.settle, value: status)
        .animation(OnboardingMotion.response, value: isNext)
    }

    private var allowed: some View {
        HStack(spacing: 5) {
            CheckmarkShape(progress: checkProgress)
                .stroke(OnboardingColors.success, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
            Text("Allowed")
                .font(OnboardingType.button)
                .foregroundStyle(OnboardingColors.success)
        }
        .onAppear {
            guard !isStatic else {
                checkProgress = 1
                return
            }
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.42).delay(0.08)) { checkProgress = 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Allowed")
    }
}

// MARK: - Try it

private struct TryItStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            OnboardingHeading(title: model.enginePhase.isReady ? "Try it out" : "Almost ready", lead: lead)
            TranscriptWell(model: model)
            status.frame(minHeight: 40, alignment: .top)
        }
    }

    private var lead: String {
        let name = model.shortcut.displayName
        return "Press \(name), say something, then press \(name) again."
    }

    @ViewBuilder private var status: some View {
        VStack(spacing: 10) {
            switch model.enginePhase {
            case .waiting:
                Text("Waiting for \(ListFormatter.localizedString(byJoining: model.engineBlockers))…")
                    .foregroundStyle(.secondary)
            case .starting:
                Text("Loading the model…").foregroundStyle(.secondary)
            case .ready(let warmedUp):
                if model.testTranscript != nil {
                    Text("In other apps, the text lands where your cursor is.").foregroundStyle(.secondary)
                } else if let hint = model.practiceHint {
                    Label(hint, systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
                } else if !warmedUp {
                    Text("The model's warm-up check failed. The first dictation may be slow.").foregroundStyle(.orange)
                }
            case .failed(let message):
                HStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again", action: model.retryEngine).buttonStyle(.link)
                }
            }
            if model.functionKeyMayConflict, model.testTranscript == nil {
                HStack(spacing: 4) {
                    Text("fn opens emoji instead?").foregroundStyle(.secondary)
                    Button("Set “Press 🌐 key to” to Do Nothing", action: model.openKeyboardSettings)
                        .buttonStyle(.link)
                }
            }
        }
        .font(OnboardingType.rowDetail)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The practice surface: keycaps and level while waiting, then the words.
private struct TranscriptWell: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingCard {
            VStack(spacing: 18) {
                if let transcript = model.testTranscript {
                    VStack(spacing: 10) {
                        Label("It works", systemImage: "checkmark.circle.fill")
                            .font(OnboardingType.rowTitle)
                            .foregroundStyle(OnboardingColors.success)
                        Text(transcript)
                            .font(.system(size: 17))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    KeycapGroup(keys: model.shortcut.keycapLabels)
                        .opacity(model.enginePhase.isReady ? 1 : 0.4)
                    ListeningLevel(meter: model.microphoneMeter, isReady: model.enginePhase.isReady)
                        .frame(width: 220)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .padding(.horizontal, 28)
        }
        .animation(OnboardingMotion.response, value: model.testTranscript)
        .overlay(alignment: .topTrailing) {
            if model.testTranscript == nil, model.enginePhase.isReady {
                Button("Change shortcut…", action: model.changeShortcut)
                    .buttonStyle(.link)
                    .font(OnboardingType.caption)
                    .padding(12)
            }
        }
    }
}

/// A compact live level line under the keycaps.
private struct ListeningLevel: View {
    @ObservedObject var meter: SettingsMicrophoneMeter
    let isReady: Bool

    var body: some View {
        VStack(spacing: 8) {
            OnboardingProgressBar(fraction: isReady ? Double(meter.level) : 0)
                .frame(height: 4)
                .animation(.linear(duration: 0.08), value: meter.level)
            HStack(spacing: 6) {
                if meter.isLive { Circle().fill(Color.red).frame(width: 6, height: 6) }
                Text(caption)
            }
            .font(OnboardingType.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        guard isReady else { return "Microphone level" }
        return meter.isLive ? "Listening" : "Your words will appear here"
    }
}

// MARK: - Done

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            DoneBadge()
            VStack(spacing: OnboardingMetrics.titleGap) {
                OnboardingHeading(title: model.canFinish ? "You're all set" : "Finishing setup")
                HStack(spacing: 6) {
                    Text("Speakeasy waits in the menu bar. Press")
                    KeycapGroup(keys: model.shortcut.keycapLabels, compact: true)
                    Text("in any app to dictate.")
                }
                .font(OnboardingType.lead)
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("When you want more")
                    .font(OnboardingType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                OnboardingCard {
                    MoreRow(title: "Paste your last transcript",
                            detail: "Missed the text field? Paste it again from the menu bar.") {
                        MenuBarGlyph()
                    }
                    OnboardingRowDivider()
                    MoreRow(title: "Models, shortcut, and paste style",
                            detail: "Tune everything in Settings.") {
                        KeycapGroup(keys: ["⌘", ","], compact: true)
                    }
                }
            }
            .frame(maxWidth: 440)
        }
    }
}

private struct MoreRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OnboardingType.rowTitle)
                Text(detail).font(OnboardingType.rowDetail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct MenuBarGlyph: View {
    var body: some View {
        Image(nsImage: SpeakeasyBrand.statusBarImage)
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .frame(width: 30, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SettingsColors.subtleFill))
            .accessibilityLabel("Menu bar icon")
    }
}

/// Green check in a soft ring; the check draws itself in on arrival.
private struct DoneBadge: View {
    @Environment(\.onboardingIsStatic) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.12))
                .frame(width: 104, height: 104)
            Circle().fill(OnboardingColors.success.opacity(0.12))
                .frame(width: 72, height: 72)
            CheckmarkShape(progress: progress)
                .stroke(OnboardingColors.success, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 32)
        }
        .scaleEffect(shown ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            guard !isStatic, !reduceMotion else {
                shown = true
                progress = 1
                return
            }
            withAnimation(OnboardingMotion.settle) { shown = true }
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.5).delay(0.15)) { progress = 1 }
        }
    }
}
