import AppKit
import SwiftUI

/// Full-screen transparent canvases plus a floating control bar. Mouse input
/// passes through to apps until Shift is held, then strokes draw here.
@MainActor
final class ScrawlOverlayController: NSObject {
    var onStrokeBegan: ((CGPoint, NSScreen) -> Void)?
    var onStrokeMoved: ((CGPoint) -> Void)?
    var onStrokeEnded: (() -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?

    let hudModel = ScrawlHUDModel()
    private var canvases: [ScrawlCanvasWindow] = []
    private var hud: NSPanel?
    private var modifierTimer: Timer?
    private var clickMonitor: Any?
    private var isDrawingEnabled = false
    private var isStroking = false

    func show() {
        canvases = NSScreen.screens.map { screen in
            let window = ScrawlCanvasWindow(screen: screen)
            window.canvas.onStrokeBegan = { [weak self] point in
                self?.isStroking = true
                self?.onStrokeBegan?(point, screen)
            }
            window.canvas.onStrokeMoved = { [weak self] point in self?.onStrokeMoved?(point) }
            window.canvas.onStrokeEnded = { [weak self] in
                self?.isStroking = false
                self?.onStrokeEnded?()
                self?.refreshDrawingMode()
            }
            window.orderFrontRegardless()
            return window
        }

        // NSEvent.modifierFlags reads the global modifier state, so polling
        // needs no extra permission and also sees Shift held before launch.
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(pollModifiers),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer

        // Global monitors only see other apps' clicks, so control-bar clicks never become marks.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDrawingEnabled else { return }
                self.onClick?(NSEvent.mouseLocation)
            }
        }
    }

    func render(annotations: [ScrawlAnnotation], live: [CGPoint]?) {
        for window in canvases {
            window.canvas.annotations = annotations
            window.canvas.liveStroke = live
            window.canvas.needsDisplay = true
        }
        hudModel.markCount = annotations.count
    }

    func close() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        canvases.forEach { $0.orderOut(nil) }
        canvases = []
        hud?.orderOut(nil)
        hud = nil
    }

    @objc private func pollModifiers() {
        refreshDrawingMode()
    }

    private func refreshDrawingMode() {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        // Finish an in-progress stroke even if Shift is released mid-drag.
        let enabled = shiftHeld || isStroking
        guard enabled != isDrawingEnabled else { return }
        isDrawingEnabled = enabled
        hudModel.isDrawing = enabled
        for window in canvases {
            window.ignoresMouseEvents = !enabled
            window.canvas.isDrawingEnabled = enabled
            window.canvas.needsDisplay = true
        }
    }

    /// Shown once the recording becomes a scrawl; plain dictation never sees it.
    func showHUD() {
        guard hud == nil else { return }
        let view = ScrawlHUDView(
            model: hudModel,
            undo: { [weak self] in self?.onUndo?() },
            cancel: { [weak self] in self?.onCancel?() },
            finish: { [weak self] in self?.onFinish?() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let panel = NSPanel(
            contentRect: CGRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 12,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        hud = panel
    }
}

final class ScrawlHUDModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var markCount = 0
    @Published var isDrawing = false
    @Published var level: Float = 0
}

/// Matches the recording pill: near-black capsule, hairline border, white type.
private enum ScrawlHUDStyle {
    static let background = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let border = Color.white.opacity(0.16)
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color(red: 1, green: 0.23, blue: 0.19)
}

private struct ScrawlHUDView: View {
    @ObservedObject var model: ScrawlHUDModel
    let undo: () -> Void
    let cancel: () -> Void
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot()
                Text(ScrawlSummary.timestamp(model.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                LevelBars(level: model.level)
            }
            HUDDivider()
            hint
            if model.markCount > 0 {
                Text("\(model.markCount) \(model.markCount == 1 ? "mark" : "marks")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ScrawlHUDStyle.accent.opacity(0.85)))
                    .transition(.scale.combined(with: .opacity))
            }
            HUDDivider()
            HStack(spacing: 4) {
                Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(HUDIconButtonStyle())
                    .disabled(model.markCount == 0)
                    .help("Undo last mark")
                Button(action: cancel) { Image(systemName: "xmark") }
                    .buttonStyle(HUDIconButtonStyle())
                    .help("Discard this scrawl")
            }
            Button(action: finish) {
                Text("Finish")
            }
            .buttonStyle(HUDPrimaryButtonStyle())
            .help("Build the contact sheet and copy it (or press fn)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(ScrawlHUDStyle.background))
        .overlay(Capsule().strokeBorder(ScrawlHUDStyle.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: model.markCount)
        .animation(.easeOut(duration: 0.15), value: model.isDrawing)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(10)
    }

    private var hint: some View {
        HStack(spacing: 5) {
            Text("⇧")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(model.isDrawing ? .white : ScrawlHUDStyle.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(model.isDrawing ? ScrawlHUDStyle.accent : Color.white.opacity(0.12))
                )
            Text(model.isDrawing ? "Drawing" : "hold to draw · click to mark")
                .font(.system(size: 12))
                .foregroundColor(ScrawlHUDStyle.secondary)
        }
    }
}

private struct RecordingDot: View {
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(ScrawlHUDStyle.accent)
            .frame(width: 8, height: 8)
            .opacity(isDimmed ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }
}

private struct LevelBars: View {
    private static let weights: [Float] = [0.55, 0.85, 1, 0.75, 0.5]
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: 3 + 11 * CGFloat(min(1, level * Self.weights[index])))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct HUDDivider: View {
    var body: some View {
        Rectangle()
            .fill(ScrawlHUDStyle.border)
            .frame(width: 1, height: 16)
    }
}

private struct HUDIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(isEnabled ? 0.9 : 0.3))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.08)))
            .contentShape(Circle())
    }
}

private struct HUDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ScrawlHUDStyle.background)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

/// Buttons in a non-activating panel must respond to the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ScrawlCanvasWindow: NSPanel {
    let canvas: ScrawlCanvasView

    init(screen: NSScreen) {
        canvas = ScrawlCanvasView(screenOrigin: screen.frame.origin)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        contentView = canvas
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScrawlCanvasView: NSView {
    var onStrokeBegan: ((CGPoint) -> Void)?
    var onStrokeMoved: ((CGPoint) -> Void)?
    var onStrokeEnded: (() -> Void)?
    var annotations: [ScrawlAnnotation] = []
    var liveStroke: [CGPoint]?
    var isDrawingEnabled = false
    private let screenOrigin: CGPoint
    private static let markColor = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor.white
    ]

    init(screenOrigin: CGPoint) {
        self.screenOrigin = screenOrigin
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onStrokeBegan?(globalPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        onStrokeMoved?(globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        onStrokeEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDrawingEnabled {
            drawDrawingModeFrame()
        }
        for annotation in annotations {
            switch annotation.kind {
            case .stroke:
                annotation.strokes.forEach(strokeSmoothed)
            case .click:
                annotation.strokes.flatMap { $0 }.forEach(drawClickRing)
            }
            let bounds = annotation.bounds
            if !bounds.isNull {
                drawBadge(annotation.number, at: localPoint(CGPoint(x: bounds.maxX, y: bounds.maxY)))
            }
        }
        if let liveStroke {
            strokeSmoothed(liveStroke)
        }
    }

    private func drawDrawingModeFrame() {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        frame.lineWidth = 4
        Self.markColor.withAlphaComponent(0.18).setStroke()
        frame.stroke()
        frame.lineWidth = 1.5
        Self.markColor.withAlphaComponent(0.7).setStroke()
        frame.stroke()
    }

    /// Midpoint quadratic curves turn jittery mouse samples into ink.
    private func strokeSmoothed(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: localPoint(first))
        if points.count < 3 {
            points.dropFirst().forEach { path.line(to: localPoint($0)) }
            if points.count == 1 { path.line(to: localPoint(first)) }
        } else {
            for index in 1..<(points.count - 1) {
                let control = localPoint(points[index])
                let next = localPoint(points[index + 1])
                let mid = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
                path.curve(to: mid, controlPoint1: control, controlPoint2: control)
            }
            path.line(to: localPoint(points[points.count - 1]))
        }
        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 7
        path.stroke()
        Self.markColor.setStroke()
        path.lineWidth = 4
        path.stroke()
    }

    private func drawClickRing(_ point: CGPoint) {
        let center = localPoint(point)
        let radius = ScrawlAnnotation.clickRadius
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        ring.lineWidth = 6
        ring.stroke()
        Self.markColor.setStroke()
        ring.lineWidth = 3
        ring.stroke()
    }

    private func drawBadge(_ number: Int, at center: CGPoint) {
        let radius: CGFloat = 12
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Self.markColor.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        circle.lineWidth = 2
        circle.stroke()
        let label = NSAttributedString(string: "\(number)", attributes: Self.badgeAttributes)
        let size = label.size()
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + screenOrigin.x, y: local.y + screenOrigin.y)
    }

    private func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenOrigin.x, y: point.y - screenOrigin.y)
    }
}
