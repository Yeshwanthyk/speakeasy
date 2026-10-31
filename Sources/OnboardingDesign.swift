import AppKit
import SwiftUI

// Visual language for first-run setup: one centred column, a neutral palette,
// a dark primary button, and motion only where a state changes. Values follow
// the Hex onboarding (src/rune_ui/onboarding.rs) scaled to this window.

enum OnboardingMetrics {
    /// Width of the page column and the footer.
    static let columnWidth: CGFloat = 500
    /// Body copy wraps narrower than the column so lines stay readable.
    static let leadWidth: CGFloat = 430
    static let topBarHeight: CGFloat = 48
    /// Back and primary slots are equal so the page dots stay centred.
    static let footerSlot: CGFloat = 150
    static let footerBottom: CGFloat = 28
    static let titleGap: CGFloat = 10
    static let sectionGap: CGFloat = 28
    static let rowMinHeight: CGFloat = 60
    static let buttonHeight: CGFloat = 30
    static let buttonRadius: CGFloat = 8
}

enum OnboardingType {
    static let title = Font.system(size: 26, weight: .semibold)
    static let lead = Font.system(size: 15)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let rowDetail = Font.system(size: 12)
    static let button = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .medium)
}

enum OnboardingColors {
    static let primaryFill = adaptive(
        light: NSColor(white: 0.13, alpha: 1),
        dark: NSColor(white: 0.94, alpha: 1)
    )
    static let primaryText = adaptive(light: .white, dark: NSColor(white: 0.08, alpha: 1))
    static let success = Color(nsColor: .systemGreen)
    static let lamp = Color(red: 0.42, green: 0.6, blue: 1.0)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

enum OnboardingMotion {
    /// Strong ease-out for anything entering or responding to a click.
    static let response = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    static let press = Animation.easeOut(duration: 0.16)
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.78)
}

/// Snapshot renders freeze every animation at its resting state.
private struct OnboardingStaticKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onboardingIsStatic: Bool {
        get { self[OnboardingStaticKey.self] }
        set { self[OnboardingStaticKey.self] = newValue }
    }
}

// MARK: - Buttons

struct OnboardingButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind = .primary
    var showsArrow = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            if showsArrow {
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
            }
        }
        .font(OnboardingType.button)
        .foregroundStyle(kind == .primary ? OnboardingColors.primaryText : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: OnboardingMetrics.buttonHeight)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: OnboardingMetrics.buttonRadius, style: .continuous))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(OnboardingMotion.press, value: configuration.isPressed)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: OnboardingMetrics.buttonRadius, style: .continuous)
        switch kind {
        case .primary:
            shape.fill(OnboardingColors.primaryFill)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        case .secondary:
            shape.fill(SettingsColors.cardFill)
                .overlay(shape.strokeBorder(SettingsColors.cardStroke))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        }
    }
}

// MARK: - Page chrome

struct OnboardingPageDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.paged) { step in
                Capsule()
                    .fill(step == current ? Color.primary.opacity(0.85) : Color.primary.opacity(0.15))
                    .frame(width: step == current ? 16 : 6, height: 6)
            }
        }
        .animation(OnboardingMotion.settle, value: current)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let index = OnboardingStep.paged.firstIndex(of: current) else { return "Setup complete" }
        return "Step \(index + 1) of \(OnboardingStep.paged.count)"
    }
}

/// Title and one lead paragraph, centred.
struct OnboardingHeading: View {
    let title: String
    var lead: String?

    var body: some View {
        VStack(spacing: OnboardingMetrics.titleGap) {
            Text(title)
                .font(OnboardingType.title)
                .kerning(-0.3)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let lead {
                Text(lead)
                    .font(OnboardingType.lead)
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: OnboardingMetrics.leadWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// White card with hairline separators between rows.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .settingsCardBackground(cornerRadius: 12)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

struct OnboardingRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

// MARK: - Model download pill

/// Corner status for the background model download, visible on every page
/// so the download never needs its own wait.
struct OnboardingModelPill: View {
    let phase: OnboardingModelPhase
    let retry: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .checking:
                label("Speech model", fraction: nil, trailing: nil)
            case .downloading(let received, let expected):
                let fraction = expected > 0 ? Double(received) / Double(expected) : 0
                label("Speech model", fraction: fraction, trailing: "\(Int(fraction * 100))%")
            case .verifying:
                label("Verifying model", fraction: 1, trailing: nil)
            case .installed:
                Label("Speech model ready", systemImage: "checkmark")
                    .foregroundStyle(OnboardingColors.success)
                    .transition(.opacity)
            case .failed:
                HStack(spacing: 8) {
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Retry", action: retry).buttonStyle(.link)
                }
            }
        }
        .font(OnboardingType.caption)
        .animation(OnboardingMotion.response, value: phase.isInstalled)
        .accessibilityElement(children: .combine)
    }

    private func label(_ title: String, fraction: Double?, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            OnboardingProgressBar(fraction: fraction)
                .frame(width: 96, height: 5)
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}

/// Thin capsule bar; a nil fraction shows a slow shimmer instead.
struct OnboardingProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SettingsColors.subtleFill)
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction ?? 0.18, 0), 1)))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        }
    }
}

// MARK: - Checkmark

/// A check that draws itself from left to right as `progress` goes 0 → 1.
struct CheckmarkShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        return path.trimmedPath(from: 0, to: progress)
    }
}

// MARK: - Hero

/// The app icon over a soft lamp that rises once, then breathes.
struct OnboardingHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingIsStatic) private var isStatic
    @State private var lit = false
    @State private var breathing = false

    var body: some View {
        ZStack {
            rays
                .frame(width: 420, height: 420)
                .opacity(lit ? 0.55 : 0)
                .scaleEffect(lit ? 1 : 0.7)
            RadialGradient(
                colors: [OnboardingColors.lamp.opacity(0.55), OnboardingColors.lamp.opacity(0.12), .clear],
                center: .center, startRadius: 4, endRadius: 150
            )
            .frame(width: 320, height: 320)
            .scaleEffect(lit ? (breathing ? 1.07 : 1) : 0.6)
            .opacity(lit ? 1 : 0)
            Image(nsImage: SpeakeasyBrand.appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
        .onAppear(perform: animateIn)
    }

    /// Thin conic rays, masked to fade out from the centre.
    private var rays: some View {
        let stops = (0..<48).map { index -> Gradient.Stop in
            let ray = index.isMultiple(of: 2)
            return Gradient.Stop(
                color: OnboardingColors.lamp.opacity(ray ? 0.35 : 0),
                location: CGFloat(index) / 47
            )
        }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center)
            .mask(RadialGradient(colors: [.white, .white.opacity(0.4), .clear], center: .center,
                                 startRadius: 30, endRadius: 210))
            .blur(radius: 6)
    }

    private func animateIn() {
        guard !isStatic, !reduceMotion else {
            lit = true
            return
        }
        withAnimation(.spring(response: 1.4, dampingFraction: 1).delay(0.15)) { lit = true }
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(1.8)) { breathing = true }
    }
}

/// An 8 pt dot that pulses while Speakeasy waits for a grant.
struct OnboardingPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingIsStatic) private var isStatic
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion, !isStatic else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}
