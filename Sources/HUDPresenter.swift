import AppKit
import Foundation
import os

final class HUDPresenter {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "hud")
    private var window: NSPanel?
    private var label: NSTextField?
    private var hideToken: UUID?

    func show(message: String, duration: TimeInterval = 0.8) {
        let (window, label) = ensureWindow()
        label.stringValue = message

        let labelSize = label.intrinsicContentSize
        let padding: CGFloat = 18
        let width = min(420, labelSize.width + padding * 2)
        let height = labelSize.height + 16

        label.frame = CGRect(
            x: (width - labelSize.width) * 0.5,
            y: (height - labelSize.height) * 0.5,
            width: labelSize.width,
            height: labelSize.height
        )

        window.setContentSize(NSSize(width: width, height: height))
        position(window: window, size: NSSize(width: width, height: height))

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.hideToken == token else {
                return
            }
            self.hide(window: window)
        }
    }

    private func ensureWindow() -> (NSPanel, NSTextField) {
        if let window, let label {
            return (window, label)
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center

        let container = NSView(frame: .zero)
        container.addSubview(label)
        panel.contentView = container

        self.window = panel
        self.label = label
        return (panel, label)
    }

    private func position(window: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else {
            logger.error("Missing main screen")
            return
        }

        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width * 0.5,
            y: frame.maxY - size.height - 120
        )
        window.setFrameOrigin(origin)
    }

    private func hide(window: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}
