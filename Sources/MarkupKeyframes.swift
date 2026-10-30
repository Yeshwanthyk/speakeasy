import ApplicationServices
import CoreGraphics
import Foundation

/// A coarse brightness grid of a screenshot, used to tell whether two marks
/// were made on the same unchanged screen.
struct LumaSignature: Equatable, Sendable {
    static let columns = 16
    static let rows = 8
    static let cellCount = columns * rows

    /// Mean luminance per cell, 0...1.
    let cells: [Float]

    init(cells: [Float]) {
        self.cells = cells
    }

    init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.cellCount)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: Self.columns,
                height: Self.rows,
                bitsPerComponent: 8,
                bytesPerRow: Self.columns,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drawn else { return nil }
        cells = pixels.map { Float($0) / 255 }
    }

    /// Mean absolute per-cell difference, 0 (identical) to 1.
    func difference(to other: LumaSignature) -> Float {
        guard cells.count == other.cells.count, !cells.isEmpty else { return 1 }
        let total = zip(cells, other.cells).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
        return total / Float(cells.count)
    }
}

/// Decides which marks share one contact-sheet tile, and how many tiles to
/// show. Every mark still gets its own full frame under frames/.
enum MarkupFrameGrouper {
    /// Below this luma difference two stills show the same screen.
    static let sameScreenThreshold: Float = 0.05
    static let maximumTiles = 12

    struct Entry: Equatable {
        let displayFrame: CGRect
        let signature: LumaSignature?
    }

    /// Consecutive marks on the same display whose stills match share a
    /// group. Marks without a still stand alone.
    static func groups(_ entries: [Entry]) -> [[Int]] {
        var groups: [[Int]] = []
        for (index, entry) in entries.enumerated() {
            if let lastIndex = groups.last?.last,
               entries[lastIndex].displayFrame == entry.displayFrame,
               let previous = entries[lastIndex].signature,
               let current = entry.signature,
               previous.difference(to: current) < sameScreenThreshold {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    /// Keeps at most `maximumTiles` groups, spread evenly and always
    /// including the first and last.
    static func capped(_ groups: [[Int]]) -> [[Int]] {
        guard groups.count > maximumTiles else { return groups }
        let last = groups.count - 1
        let picks = (0..<maximumTiles).map { slot in
            Int((Double(slot) * Double(last) / Double(maximumTiles - 1)).rounded())
        }
        return Array(Set(picks)).sorted().map { groups[$0] }
    }
}

/// Turns accessibility attributes into a short phrase such as
/// "“Save” button", so an agent knows what a mark points at without
/// opening the image.
enum MarkupElementDescriber {
    static let maximumTextLength = 60

    private static let roleNames: [String: String] = [
        "AXButton": "button",
        "AXLink": "link",
        "AXStaticText": "text",
        "AXTextField": "text field",
        "AXTextArea": "text area",
        "AXSearchField": "search field",
        "AXImage": "image",
        "AXCheckBox": "checkbox",
        "AXRadioButton": "radio button",
        "AXPopUpButton": "pop-up menu",
        "AXComboBox": "combo box",
        "AXMenuItem": "menu item",
        "AXMenuButton": "menu button",
        "AXTab": "tab",
        "AXCell": "cell",
        "AXRow": "row",
        "AXHeading": "heading",
        "AXSlider": "slider",
        "AXDisclosureTriangle": "disclosure triangle",
        "AXToolbar": "toolbar"
    ]

    /// Containers say nothing useful about what was marked.
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWindow", "AXWebArea",
        "AXLayoutArea", "AXApplication", "AXUnknown", "AXList", "AXOutline", "AXTable"
    ]

    static func describe(
        role: String?,
        subrole: String? = nil,
        title: String?,
        description: String?,
        value: String?
    ) -> String? {
        if subrole == "AXSecureTextField" { return "password field" }
        guard let role, !containerRoles.contains(role) else { return nil }
        let name = [title, description, value]
            .compactMap { $0.map(collapse) }
            .first { !$0.isEmpty }
        let roleName = roleNames[role]
        switch (name, roleName) {
        case let (name?, roleName?):
            return "“\(truncate(name))” \(roleName)"
        case let (name?, nil):
            return "“\(truncate(name))”"
        case (nil, _):
            return nil
        }
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maximumTextLength else { return text }
        return String(text.prefix(maximumTextLength)) + "…"
    }
}

/// Reads the accessibility element under a point. Hung apps cost at most
/// the per-message timeout per attribute; callers run this off the main
/// thread.
enum MarkupElementLocator {
    static let messagingTimeout: Float = 0.1

    /// `point` is in global AppKit coordinates (bottom-left origin).
    static func label(at point: CGPoint) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(primaryHeight - point.y), &hit
        ) == .success, var element = hit else {
            return nil
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        // Text runs inside buttons and links describe themselves poorly;
        // one step up usually names the control.
        for _ in 0..<2 {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            if let label = MarkupElementDescriber.describe(
                role: string(element, kAXRoleAttribute),
                subrole: string(element, kAXSubroleAttribute),
                title: string(element, kAXTitleAttribute),
                description: string(element, kAXDescriptionAttribute),
                value: string(element, kAXValueAttribute)
            ) {
                return label
            }
            guard let parent = parent(of: element) else { return nil }
            element = parent
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
