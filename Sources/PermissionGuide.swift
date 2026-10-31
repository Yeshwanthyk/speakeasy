import AppKit
import SwiftUI

/// A small floating panel pinned to the System Settings window while the
/// user grants Accessibility or Input Monitoring. It says what to do and,
/// for list-based grants, offers a Speakeasy tile to drag into the list.
@MainActor
final class PermissionGuideController {
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let panelSize = NSSize(width: 460, height: 112)
    private static let inset: CGFloat = 16
    private static let trackIntervalNanoseconds: UInt64 = 120_000_000
    /// Stop following Settings after this long; the onboarding row still waits.
    private static let lifetimeNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private var panel: NSPanel?
    private var trackTask: Task<Void, Never>?

    /// Opens System Settings at `permission` and, for list grants, pins the guide.
    func open(_ permission: OnboardingPermission) {
        let url = Self.settingsURL(for: permission)
        let coldLaunch = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
        NSWorkspace.shared.open(url)
        if coldLaunch {
            // A cold System Settings launch often lands on its last pane and
            // ignores the anchor; asking again once it is up fixes that.
            Task { @MainActor in
                for delay: UInt64 in [350_000_000, 850_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    NSWorkspace.shared.open(url)
                }
            }
        }
        guard let copy = PermissionGuideCopy(permission) else {
            close()
            return
        }
        show(copy)
    }

    func close() {
        trackTask?.cancel()
        trackTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(_ copy: PermissionGuideCopy) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = PermissionGuideView(copy: copy, size: Self.panelSize)
        panel.alphaValue = 0
        self.panel = panel
        trackTask = Task { @MainActor [weak self] in
            await self?.track(panel)
        }
    }

    /// Follows the Settings window; closes once it has been seen and is gone.
    private func track(_ panel: NSPanel) async {
        var seenSettings = false
        var elapsed: UInt64 = 0
        while !Task.isCancelled, elapsed < Self.lifetimeNanoseconds {
            if let frame = Self.settingsWindowFrame() {
                seenSettings = true
                panel.setFrameOrigin(Self.origin(beside: frame, panelSize: panel.frame.size))
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.2
                        panel.animator().alphaValue = 1
                    }, completionHandler: nil)
                }
            } else if seenSettings {
                break
            }
            try? await Task.sleep(nanoseconds: Self.trackIntervalNanoseconds)
            elapsed += Self.trackIntervalNanoseconds
        }
        if !Task.isCancelled, self.panel === panel { close() }
    }

    /// Bottom-right corner inside the Settings window, kept on screen.
    private static func origin(beside settings: NSRect, panelSize: NSSize) -> NSPoint {
        var origin = NSPoint(x: settings.maxX - panelSize.width - inset, y: settings.minY + inset)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - panelSize.width - inset)
            origin.y = min(max(origin.y, visible.minY + inset), visible.maxY - panelSize.height - inset)
        }
        return origin
    }

    /// The largest normal-layer System Settings window, in Cocoa coordinates.
    /// Owner names and bounds do not need Screen Recording permission.
    private static func settingsWindowFrame() -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let frames = info.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerName as String] as? String == "System Settings",
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 200, rect.height > 200 else { return nil }
            return rect
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // CGWindow bounds are top-left based on the primary screen.
        return NSRect(x: largest.minX, y: primaryHeight - largest.maxY, width: largest.width, height: largest.height)
    }

    private static func settingsURL(for permission: OnboardingPermission) -> URL {
        switch permission {
        case .microphone: return Permissions.microphoneSettingsURL
        case .accessibility: return Permissions.accessibilitySettingsURL
        case .inputMonitoring: return Permissions.inputMonitoringSettingsURL
        }
    }
}

/// What the guide says for a permission; nil when there is no list to drag into.
struct PermissionGuideCopy: Equatable {
    let instruction: String

    init?(_ permission: OnboardingPermission) {
        switch permission {
        case .microphone:
            return nil
        case .accessibility:
            instruction = "Drag Speakeasy into the Accessibility list, or switch it on"
        case .inputMonitoring:
            instruction = "Switch Speakeasy on in Input Monitoring, or drag it in"
        }
    }
}

/// The panel's content: SwiftUI chrome around an AppKit drag source.
final class PermissionGuideView: NSView {
    init(copy: PermissionGuideCopy, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        let chrome = NSHostingView(rootView: PermissionGuideChrome(instruction: copy.instruction))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)

        let tile = AppDragTile(frame: NSRect(x: 16, y: 14, width: size.width - 32, height: 46))
        addSubview(tile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

struct PermissionGuideChrome: View {
    let instruction: String
    /// Snapshots draw the tile face here because the AppKit tile is a separate view.
    var drawsTileFace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                Text(instruction).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            AppDragTileFace()
                .frame(height: 46)
                .opacity(drawsTileFace ? 1 : 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SettingsColors.cardStroke))
        )
    }
}

/// Looks like a Finder row for the app so dragging it reads naturally.
struct AppDragTileFace: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: SpeakeasyBrand.appIcon)
                .resizable()
                .frame(width: 28, height: 28)
            Text("Speakeasy").font(.system(size: 13, weight: .semibold))
            Text("Drag me")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsColors.cardFill)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SettingsColors.cardStroke))
        )
    }
}

/// Drags the app bundle URL, which the privacy lists accept as an entry.
final class AppDragTile: NSView, NSDraggingSource {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let face = NSHostingView(rootView: AppDragTileFace())
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Keep mouse events here rather than in the hosted SwiftUI face.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return SpeakeasyBrand.appIcon }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
