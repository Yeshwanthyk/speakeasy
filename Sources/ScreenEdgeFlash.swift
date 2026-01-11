import AppKit
import Foundation
import os

final class ScreenEdgeFlash {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "flash")
    private var window: NSPanel?
    private var borderView: NSView?
    private var hideToken: UUID?

    func flash(duration: TimeInterval = 0.18, lineWidth: CGFloat = 3) {
        let (window, borderView) = ensureWindow()
        updateFrame(window: window, borderView: borderView, lineWidth: lineWidth)

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.06
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

    private func ensureWindow() -> (NSPanel, NSView) {
        if let window, let borderView {
            return (window, borderView)
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let borderView = NSView(frame: .zero)
        borderView.wantsLayer = true
        borderView.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
        borderView.layer?.shadowColor = NSColor.systemTeal.cgColor
        borderView.layer?.shadowOpacity = 0.7
        borderView.layer?.shadowRadius = 16
        borderView.layer?.shadowOffset = .zero
        panel.contentView = borderView

        self.window = panel
        self.borderView = borderView
        return (panel, borderView)
    }

    private func updateFrame(window: NSPanel, borderView: NSView, lineWidth: CGFloat) {
        guard let screen = NSScreen.main else {
            logger.error("Missing main screen")
            return
        }

        let frame = screen.frame
        window.setFrame(frame, display: true)
        borderView.frame = CGRect(origin: .zero, size: frame.size)
        borderView.layer?.borderWidth = lineWidth
        borderView.layer?.cornerRadius = 18
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
