import AppKit
import SwiftUI

@MainActor
final class BottomOverlay {
    let model = OverlayModel()
    var currentMode: () -> DictationInvocationMode = { .toggle }
    var levelProvider: () -> Float = { 0 }
    var selectMode: (DictationInvocationMode) -> Void = { _ in }
    var copyLast: () -> Void = {}
    var pasteLast: () -> Void = {}
    var undoLast: () -> Void = {}
    private var panel: NSPanel?
    private var hosting: NSHostingView<BottomOverlayView>?
    private var display: NSScreen?
    private var previousApp: NSRunningApplication?
    private var dismissal: DispatchWorkItem?
    private var meter: OverlayMeterView?

    func showRecording() {
        dismissal?.cancel()
        model.start(mode: currentMode())
        previousApp = nil
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = app
        }
        guard OverlayPreferences.style() == .bottomPill else { hide(); return }
        display = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        show()
    }

    func showProcessing() {
        guard panel != nil else { return }
        model.transcribe()
        meter?.processing = true
        resize()
    }

    func updatePreview(_ text: String) {
        guard panel != nil, OverlayPreferences.showsLiveText() else { return }
        let revision = model.revision
        model.adopt(text)
        if model.revision != revision { resize() }
    }

    func showError(_ message: String) {
        guard panel != nil else { return }
        model.fail(message)
        resize()
        scheduleHide(after: 1.5)
    }

    func hide() {
        guard panel != nil else { return }
        model.finish()
        scheduleHide(after: 0.35)
    }

    private func scheduleHide(after interval: TimeInterval) {
        dismissal?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func dismiss() {
        guard let panel else { return }
        meter?.stop()
        meter = nil
        self.panel = nil
        hosting = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
    }

    private func show() {
        guard let display else { return }
        let width = min(460, display.visibleFrame.width - 32)
        let frame = CGRect(x: display.visibleFrame.midX - width / 2, y: display.visibleFrame.minY + 52,
                           width: width, height: height)
        let panel = self.panel ?? OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let meter = self.meter ?? OverlayMeterView(frame: .zero)
        meter.processing = false
        meter.levelProvider = { [weak self] in self?.levelProvider() ?? 0 }
        meter.start()
        self.meter = meter
        let content = BottomOverlayView(model: model, meter: meter,
                                        selectMode: { [weak self] mode in
                                            self?.selectMode(mode)
                                            self?.model.setMode(self?.currentMode() ?? mode)
                                        },
                                        copyLast: { [weak self] in self?.copyLast() },
                                        pasteLast: { [weak self] in self?.pasteToPrevious { self?.pasteLast() } },
                                        undoLast: { [weak self] in self?.pasteToPrevious { self?.undoLast() } })
        let hosting = NSHostingView(rootView: content)
        self.hosting = hosting
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func pasteToPrevious(_ action: @escaping () -> Void) {
        guard let previousApp, !previousApp.isTerminated else { action(); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp.processIdentifier {
            action()
            return
        }
        guard previousApp.activate(options: [.activateIgnoringOtherApps]) else { action(); return }
        Task { @MainActor in
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp.processIdentifier {
                    action()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // The coordinator's target-aware paste path copies without posting events if activation failed.
            action()
        }
    }

    /// Fixed panel height: chips row + a two-line transcript window. The
    /// pill never resizes or moves while text grows; older lines scroll off.
    private let height: CGFloat = 112

    /// Kept as a no-op hook: the panel size is fixed by design.
    private func resize() {}
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct BottomOverlayView: View {
    /// Two lines of 13 pt medium text.
    static let transcriptWindowHeight: CGFloat = 36

    @ObservedObject var model: OverlayModel
    let meter: OverlayMeterView
    let selectMode: (DictationInvocationMode) -> Void
    let copyLast: () -> Void
    let pasteLast: () -> Void
    let undoLast: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Menu(model.modeLabel) {
                    Button("Hands-Free") { selectMode(.toggle) }
                    Button("Push to Talk") { selectMode(.pushToTalk) }
                }
                Menu("Actions") {
                    Button("Copy Last Transcription", action: copyLast)
                    Button("Paste Last Transcription", action: pasteLast)
                    Divider()
                    Button("Undo Corrections on Last", action: undoLast)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .tint(.white)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.88))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.displayedText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Two-line window pinned to the newest text: overflow
                        // exits through the top edge, never truncating the tail.
                        .frame(height: Self.transcriptWindowHeight, alignment: .bottomLeading)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [.init(color: .black.opacity(0.35), location: 0),
                                        .init(color: .black, location: 0.3)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    HStack {
                        if model.phase == .transcribing { ProgressView().controlSize(.mini).tint(.white) }
                        else { MeterRepresentable(meter: meter).frame(width: 24, height: 15) }
                        Spacer()
                        Text(model.phase == .transcribing ? "Transcribing…" : model.modeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 17).fill(Color(red: 0.10, green: 0.11, blue: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct MeterRepresentable: NSViewRepresentable {
    let meter: OverlayMeterView
    func makeNSView(context: Context) -> OverlayMeterView { meter }
    func updateNSView(_ nsView: OverlayMeterView, context: Context) {}
}

@MainActor
final class OverlayMeterView: NSView {
    var levelProvider: (() -> Float)?
    var processing = false
    private var timer: Timer?
    private let bars = (0..<5).map { _ in CALayer() }
    private var tick = 0.0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars { bar.backgroundColor = NSColor.white.cgColor; bar.cornerRadius = 1; layer?.addSublayer(bar) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawBars() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func drawBars() {
        tick += 0.17
        let level = CGFloat(min(max(levelProvider?() ?? 0, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let wave = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.5 : (sin(tick - Double(index) * 0.8) + 1) / 2
            let height = 2 + 12 * (processing ? CGFloat(0.2 + 0.7 * wave) : max(level, 0.12) * CGFloat(0.55 + 0.45 * wave))
            bar.frame = CGRect(x: CGFloat(index) * 4.5, y: (bounds.height - height) / 2, width: 2, height: height)
        }
        CATransaction.commit()
    }
}
