import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgress(current: model.step)
                .padding(.top, 38)
                .padding(.bottom, 8)
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .model: ModelStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .tryIt: TryItStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            .padding(.top, 16)
            Divider()
            OnboardingFooter(model: model)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 640, minHeight: 540)
    }
}

// MARK: - Chrome

private struct OnboardingProgress: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: step == current ? 26 : 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)")
    }
}

private struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            if model.step == .done {
                Button("Start Dictating") { model.finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFinish)
            } else {
                Button(model.step == .welcome ? "Get Started" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var hint: String? {
        switch model.step {
        case .model where !model.modelPhase.isInstalled:
            return "The download keeps going while you continue."
        case .done where !model.canFinish:
            return "Finish the remaining steps to continue."
        default:
            return nil
        }
    }

    private func move(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: model.step.rawValue + delta) else { return }
        model.step = next
    }
}

private struct StepHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: SpeakeasyBrand.appIcon)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 12)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Speakeasy").font(.system(size: 28, weight: .bold))
                Text("Talk instead of type, in any app. Setup takes about a minute.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "keyboard", tint: .indigo, title: "Press a key, speak, press again",
                           detail: "Your words appear wherever the cursor is.")
                FeatureRow(symbol: "lock.fill", tint: .green, title: "Private by design",
                           detail: "Speech is transcribed on this Mac. Audio never leaves it.")
                FeatureRow(symbol: "arrow.down.circle.fill", tint: .teal, title: "One-time model download",
                           detail: "About 135 MB, verified before use. Works offline afterwards.")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Model

private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "cpu", tint: .purple, title: "Speech model",
                       subtitle: "Runs entirely on this Mac. You can switch later in Settings.")
            ForEach(ASRModelKind.allCases, id: \.preferenceValue) { kind in
                ModelChoice(
                    kind: kind,
                    isSelected: kind == model.selectedModel,
                    isRecommended: kind == .parakeet110M,
                    isEnabled: model.canChangeModel
                ) { model.selectModel(kind) }
            }
            ModelProgressCard(model: model)
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
            HStack(spacing: 12) {
                IconTile(symbol: kind.settingsSymbol, tint: kind.settingsTint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(kind.settingsTitle).font(.system(size: 14, weight: .semibold))
                        if isRecommended { StatusPill(text: "Recommended", tint: .green) }
                    }
                    Text(kind.settingsTagline).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Chip(text: SettingsFormat.bytes(kind.artifact.expectedByteCount), symbol: "arrow.down.circle")
                SelectionMark(isSelected: isSelected)
            }
            .padding(12)
            .selectableTileBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isSelected)
        .opacity(!isEnabled && !isSelected ? 0.5 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ModelProgressCard: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        SettingsCard {
            switch model.modelPhase {
            case .checking:
                ProgressRow(title: "Checking for an existing copy…", fraction: nil)
            case .downloading(let received, let expected):
                ProgressRow(
                    title: "Downloading \(model.selectedModel.settingsTitle)",
                    detail: "\(SettingsFormat.bytes(received)) of \(SettingsFormat.bytes(expected))",
                    fraction: expected > 0 ? Double(received) / Double(expected) : nil
                )
            case .verifying:
                ProgressRow(title: "Verifying checksum…", fraction: nil)
            case .installed:
                Label("\(model.selectedModel.settingsTitle) is downloaded and verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") { model.retryInstall() }
                }
            }
        }
    }
}

private struct ProgressRow: View {
    let title: String
    var detail: String?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let detail { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "hand.raised.fill", tint: .blue, title: "Permissions",
                       subtitle: "Speakeasy needs three macOS permissions. You stay in control in System Settings.")
            SettingsCard {
                PermissionRow(
                    symbol: "mic.fill", tint: .red, title: "Microphone",
                    detail: "To hear you while you dictate. Nothing is recorded otherwise.",
                    state: model.microphone,
                    buttonTitle: model.microphone == .notDetermined ? "Allow" : "Open Settings",
                    action: model.requestMicrophone
                )
                Divider()
                PermissionRow(
                    symbol: "accessibility", tint: .blue, title: "Accessibility",
                    detail: "To paste text into the app you're using.",
                    state: model.accessibility,
                    buttonTitle: "Open Settings",
                    action: model.requestAccessibility
                )
                Divider()
                PermissionRow(
                    symbol: "keyboard.fill", tint: .indigo, title: "Input Monitoring",
                    detail: "To notice your dictation shortcut while other apps are in front.",
                    state: model.inputMonitoring,
                    buttonTitle: "Open Settings",
                    action: model.requestInputMonitoring
                )
            }
            if model.permissionsGranted {
                Label("All set. Speakeasy has everything it needs.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("In System Settings → Privacy & Security, turn on **Speakeasy** in each list, then come back here.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.visitedSystemSettings {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turned it on but it still shows as off? The entry may belong to an older copy of Speakeasy. Reset it and allow again, or restart the app.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if model.inputMonitoring != .granted {
                                Button("Reset & Ask Again") { model.resetInputMonitoring() }
                            }
                            Button("Restart Speakeasy") { model.relaunch() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: PermissionState
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state == .granted {
                StatusPill(text: "Allowed", tint: .green)
            } else {
                Button(buttonTitle, action: action)
            }
        }
    }
}

// MARK: - Try it

private struct TryItStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "waveform", tint: .pink, title: "Try it",
                       subtitle: "Dictate a sentence to make sure everything works end to end.")
            SettingsCard {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.shortcut.keycapLabels.enumerated()), id: \.offset) { item in
                            Keycap(label: item.element)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(instructions).font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Use a Different Shortcut…") { model.changeShortcut() }
                            .buttonStyle(.link)
                            .disabled(!model.enginePhase.isReady)
                    }
                }
            }
            SettingsCard { TestResult(model: model) }
            if model.functionKeyMayConflict {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("If pressing fn opens emoji or macOS Dictation, set “Press 🌐 key to” to “Do Nothing”.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings…") { model.openKeyboardSettings() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private var instructions: String {
        let name = model.shortcut.displayName
        return "Press \(name), say something like “Hello from Speakeasy”, then press \(name) again."
    }
}

private struct TestResult: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        if let transcript = model.testTranscript {
            VStack(alignment: .leading, spacing: 8) {
                Label("It works!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14, weight: .semibold))
                Text("“\(transcript)”")
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("In other apps, this text is pasted where your cursor is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch model.enginePhase {
            case .waiting:
                Label("Waiting for \(ListFormatter.localizedString(byJoining: model.engineBlockers))", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the model…").foregroundStyle(.secondary)
                }
            case .ready(let warmedUp):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusPill(text: "Listening for \(model.shortcut.displayName)", tint: .green)
                        Text("Your transcript will show up here.").foregroundStyle(.secondary)
                    }
                    if !warmedUp {
                        Text("The model's warm-up check failed. Dictation may be slow or fail the first time.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") { model.retryEngine() }
                }
            }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "checkmark", tint: .green,
                       title: model.canFinish ? "You're ready" : "Almost there",
                       subtitle: "Speakeasy lives in your menu bar.")
            SettingsCard {
                ChecklistRow(title: "Speech model downloaded and verified", isDone: model.modelPhase.isInstalled)
                ChecklistRow(title: "Microphone allowed", isDone: model.microphone == .granted)
                ChecklistRow(title: "Accessibility allowed", isDone: model.accessibility == .granted)
                ChecklistRow(title: "Input Monitoring allowed", isDone: model.inputMonitoring == .granted)
                ChecklistRow(title: "Model loaded", isDone: model.enginePhase.isReady)
                ChecklistRow(title: "Test dictation succeeded", isDone: model.testTranscript != nil)
            }
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: SpeakeasyBrand.statusBarImage)
                        .renderingMode(.template)
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                    Text("Click this icon in the menu bar for recent transcripts, settings, and to reopen this guide.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ChecklistRow: View {
    let title: String
    let isDone: Bool

    var body: some View {
        Label {
            Text(title).foregroundStyle(isDone ? .primary : .secondary)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.green : Color.secondary)
        }
    }
}
