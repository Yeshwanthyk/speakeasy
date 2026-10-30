import AppKit
import SwiftUI

// Shared layout, colour, and type tokens for Settings and the windows that
// borrow its look (onboarding, meetings, corrections). Views use these names
// instead of literal numbers so every page keeps one rhythm.

/// Layout tokens. The page title, section labels, and row text share one
/// leading edge: cards sit `rowInset` outside it.
enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 200
    static let contentMaxWidth: CGFloat = 620
    /// Horizontal padding of the page column; card edges sit here.
    static let pageGutter: CGFloat = 24
    static let pageTop: CGFloat = 36
    static let pageBottom: CGFloat = 28
    /// Between the page header and sections, and between sections.
    static let sectionGap: CGFloat = 20
    /// From a section label to its card.
    static let labelGap: CGFloat = 6
    /// A row's text inset inside its card; also the separator inset.
    static let rowInset: CGFloat = 16
    static let cardPaddingY: CGFloat = 12
    /// Between rows (and their separators) inside a card.
    static let cardSpacing: CGFloat = 12
    static let rowMinHeight: CGFloat = 22
    static let rowControlGap: CGFloat = 16
    static let rowIconWidth: CGFloat = 18
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
}

/// Type styles: one size step between a row's title and its detail.
enum SettingsType {
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let pageSubtitle = Font.system(size: 12)
    static let sectionLabel = Font.system(size: 12, weight: .medium)
    static let rowTitle = Font.system(size: 13)
    static let rowTitleEmphasis = Font.system(size: 13, weight: .medium)
    static let rowDetail = Font.system(size: 11)
    static let meta = Font.system(size: 11).monospacedDigit()
    static let sidebarItem = Font.system(size: 13)
}

/// Appearance-aware surface colours. Light mode draws white cards on the
/// window background; dark mode lifts cards with a faint white wash.
enum SettingsColors {
    static let cardFill = adaptive(light: NSColor.white, dark: NSColor.white.withAlphaComponent(0.05))
    static let cardStroke = adaptive(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    static let selectedFill = adaptive(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let hoverFill = adaptive(
        light: NSColor.black.withAlphaComponent(0.035),
        dark: NSColor.white.withAlphaComponent(0.05)
    )
    /// Wells: search fields, empty-state badges, unfilled meter segments.
    static let subtleFill = adaptive(
        light: NSColor.black.withAlphaComponent(0.05),
        dark: NSColor.white.withAlphaComponent(0.07)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// The raised card surface used by every settings section.
    func settingsCardBackground(cornerRadius: CGFloat = SettingsMetrics.cardRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(SettingsColors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(SettingsColors.cardStroke)
        )
    }
}

/// A setting: title and optional one-line detail on the left, its control on
/// the right, on one line.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let symbol: String?
    let control: Control
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowControlGap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: SettingsMetrics.rowIconWidth)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(SettingsType.rowTitle)
                    if let detail {
                        Text(detail)
                            .font(SettingsType.rowDetail)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A short secondary line under a card, on the row text edge.
struct SettingsNote: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(SettingsType.rowDetail)
        .foregroundColor(color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SettingsMetrics.rowInset)
    }
}

/// Nothing to show: a quiet badge, a title, and one line of guidance.
struct SettingsEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                        .fill(SettingsColors.subtleFill)
                )
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title).font(SettingsType.rowTitleEmphasis)
            Text(detail)
                .font(SettingsType.rowDetail)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }
}
