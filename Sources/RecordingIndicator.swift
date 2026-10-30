import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import os

// The notch geometry and level normalizer are adapted from Megaphone's
// MIT-licensed RecordingOverlay.swift. See THIRD_PARTY_NOTICES.md. The
// grow-out-of-the-notch island, in-menu-bar plate on flat displays and the
// short error hold follow Hex's HUD placement design.

@MainActor
protocol RecordingFeedbackPresenting: AnyObject {
    func showRecording()
    func showProcessing()
    func hide()
    func showError(_ message: String)
}

extension RecordingFeedbackPresenting {
    func showError(_ message: String) {}
}

/// Pure placement math for the recording indicator, in AppKit coordinates
/// (y up). Frames inside `Layout` are relative to `panelFrame`.
struct RecordingIndicatorGeometry: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// A black island hanging from the hardware notch, flush with it.
        case notch
        /// A small plate inside the menu bar at the top center.
        case topPill
        /// A small floating pill above the Dock.
        case bottomPill
    }

    struct Layout: Equatable, Sendable {
        let capsule: CGRect
        let cornerRadius: CGFloat
        let dotCenter: CGPoint
        let barsFrame: CGRect
        let textFrame: CGRect
    }

    static let barCount = 4
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2.5
    static let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    static let barsHeight: CGFloat = 12
    static let dotDiameter: CGFloat = 6
    static let textHeight: CGFloat = 16

    static let wingWidth: CGFloat = 30
    static let notchTextRowHeight: CGFloat = 24
    static let notchExpandedWidth: CGFloat = 320

    static let pillCompactWidth: CGFloat = 54
    static let pillExpandedWidth: CGFloat = 320
    static let bottomPillHeight: CGFloat = 26
    static let bottomPillGap: CGFloat = 14
    static let fallbackMenuBarHeight: CGFloat = 24
    /// Room around a pill for its shadow.
    static let margin: CGFloat = 12

    let style: Style
    let panelFrame: CGRect
    /// Entrance and exit shape: tucked into the notch, or a dot-sized pill.
    let collapsed: Layout
    /// Recording or processing without text.
    let compact: Layout
    /// With one line of text: an error, or the opted-in live transcript.
    let expanded: Layout

    /// Only the bottom corners round when the shape hangs from the screen top.
    var isTopAttached: Bool { style == .notch }

    static func resolve(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        placement: OverlayStyle = .top
    ) -> RecordingIndicatorGeometry {
        switch placement {
        case .bottom:
            return bottomPill(visibleFrame: visibleFrame)
        case .top:
            if safeAreaTop > 0,
               let leftArea = auxiliaryTopLeftArea,
               let rightArea = auxiliaryTopRightArea {
                let notchWidth = screenFrame.width - leftArea.width - rightArea.width
                if notchWidth > 0, leftArea.width > 0, rightArea.width > 0 {
                    return notch(
                        screenFrame: screenFrame,
                        notchMidX: screenFrame.minX + leftArea.width + notchWidth / 2,
                        notchWidth: notchWidth,
                        notchHeight: safeAreaTop
                    )
                }
            }
            return topPill(screenFrame: screenFrame, visibleFrame: visibleFrame)
        }
    }

    private static func notch(
        screenFrame: CGRect,
        notchMidX: CGFloat,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> RecordingIndicatorGeometry {
        let compactWidth = notchWidth + 2 * wingWidth
        let expandedWidth = max(compactWidth, notchExpandedWidth)
        let expandedHeight = notchHeight + notchTextRowHeight
        let panelWidth = expandedWidth + 2 * margin
        let panelHeight = expandedHeight + margin
        let centerX = panelWidth / 2
        let bandMidY = panelHeight - notchHeight / 2
        let dotCenter = CGPoint(x: centerX - notchWidth / 2 - wingWidth / 2, y: bandMidY)
        let barsFrame = CGRect(
            x: centerX + notchWidth / 2 + wingWidth / 2 - barsWidth / 2,
            y: bandMidY - barsHeight / 2,
            width: barsWidth,
            height: barsHeight
        )
        let textRowMidY = panelHeight - notchHeight - notchTextRowHeight / 2
        let textFrame = CGRect(
            x: centerX - expandedWidth / 2 + 16,
            y: textRowMidY - textHeight / 2,
            width: expandedWidth - 32,
            height: textHeight
        )

        func layout(width: CGFloat, height: CGFloat, radius: CGFloat) -> Layout {
            Layout(
                capsule: CGRect(x: centerX - width / 2, y: panelHeight - height, width: width, height: height),
                cornerRadius: radius,
                dotCenter: dotCenter,
                barsFrame: barsFrame,
                textFrame: textFrame
            )
        }

        return RecordingIndicatorGeometry(
            style: .notch,
            panelFrame: CGRect(
                x: notchMidX - panelWidth / 2,
                y: screenFrame.maxY - panelHeight,
                width: panelWidth,
                height: panelHeight
            ),
            collapsed: layout(width: notchWidth, height: notchHeight, radius: 8),
            compact: layout(width: compactWidth, height: notchHeight, radius: 10),
            expanded: layout(width: expandedWidth, height: expandedHeight, radius: 16)
        )
    }

    private static func topPill(screenFrame: CGRect, visibleFrame: CGRect) -> RecordingIndicatorGeometry {
        let shownMenuBar = screenFrame.maxY - visibleFrame.maxY
        // A hidden menu bar (full screen, auto-hide) leaves no strip; place
        // the plate where the bar would be.
        let barHeight = shownMenuBar >= 16 ? shownMenuBar : fallbackMenuBarHeight
        let height = min(max(barHeight - 6, 16), 22)
        let topGap = max((barHeight - height) / 2, 2)
        let panelWidth = pillExpandedWidth + 2 * margin
        let panelHeight = topGap + height + margin
        return pill(
            style: .topPill,
            panelFrame: CGRect(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - panelHeight,
                width: panelWidth,
                height: panelHeight
            ),
            capsuleY: margin,
            height: height
        )
    }

    private static func bottomPill(visibleFrame: CGRect) -> RecordingIndicatorGeometry {
        let height = bottomPillHeight
        let panelWidth = pillExpandedWidth + 2 * margin
        let panelHeight = height + 2 * margin
        return pill(
            style: .bottomPill,
            panelFrame: CGRect(
                x: visibleFrame.midX - panelWidth / 2,
                y: visibleFrame.minY + bottomPillGap - margin,
                width: panelWidth,
                height: panelHeight
            ),
            capsuleY: margin,
            height: height
        )
    }

    private static func pill(
        style: Style,
        panelFrame: CGRect,
        capsuleY: CGFloat,
        height: CGFloat
    ) -> RecordingIndicatorGeometry {
        let centerX = panelFrame.width / 2
        let midY = capsuleY + height / 2

        func layout(width: CGFloat, contentWidth: CGFloat) -> Layout {
            let capsule = CGRect(x: centerX - width / 2, y: capsuleY, width: width, height: height)
            let contentMinX = centerX - contentWidth / 2
            return Layout(
                capsule: capsule,
                cornerRadius: height / 2,
                dotCenter: CGPoint(x: contentMinX + 14, y: midY),
                barsFrame: CGRect(x: contentMinX + 25, y: midY - barsHeight / 2, width: barsWidth, height: barsHeight),
                textFrame: CGRect(
                    x: contentMinX + 50,
                    y: midY - textHeight / 2,
                    width: max(contentWidth - 64, 0),
                    height: textHeight
                )
            )
        }

        return RecordingIndicatorGeometry(
            style: style,
            panelFrame: panelFrame,
            collapsed: layout(width: height, contentWidth: pillCompactWidth),
            compact: layout(width: pillCompactWidth, contentWidth: pillCompactWidth),
            expanded: layout(width: pillExpandedWidth, contentWidth: pillExpandedWidth)
        )
    }
}

/// Picks the display for the indicator: the one holding most of the focused
/// window, else the one under the pointer.
enum RecordingIndicatorScreenSelection {
    /// Converts a `kCGWindowBounds` rect (origin top-left of the primary
    /// display, y down) to AppKit screen coordinates (y up).
    static func appKitRect(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryScreenHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func screenIndex(screenFrames: [CGRect], windowFrame: CGRect?, mouseLocation: CGPoint) -> Int? {
        if let windowFrame {
            var best: (index: Int, area: CGFloat)?
            for (index, frame) in screenFrames.enumerated() {
                let overlap = frame.intersection(windowFrame)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                if area > 0, area > (best?.area ?? 0) {
                    best = (index, area)
                }
            }
            if let best { return best.index }
        }
        // `contains` excludes the max edges; the pointer can rest on the top row.
        return screenFrames.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(mouseLocation) }
    }
}

@MainActor
final class RecordingIndicator: RecordingFeedbackPresenting {
    typealias LevelProvider = @MainActor () -> MicrophoneLevelSnapshot

    private static let frameInterval: TimeInterval = 1.0 / 30.0
    private static let barMultipliers: [CGFloat] = [0.55, 0.9, 1, 0.7]
    private static let notchExitDelay: TimeInterval = 0.32
    private static let fadeDuration: TimeInterval = 0.18

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "recording-indicator")
    private let levelProvider: LevelProvider
    private var invocationMode: () -> DictationInvocationMode = { .toggle }
    private var model = OverlayModel()
    private var panel: NSPanel?
    private var indicatorView: RecordingIndicatorView?
    private var geometry: RecordingIndicatorGeometry?
    private var activeDisplayID: CGDirectDisplayID?
    private var animationTimer: Timer?
    private var errorDismissal: Task<Void, Never>?
    private var levelSampler = LiveLevelSampler()
    private var animationStartedAt = CFAbsoluteTimeGetCurrent()
    private var presentationGeneration: UInt64 = 0
    private var reduceMotion = false

    init(levelProvider: @escaping LevelProvider) {
        self.levelProvider = levelProvider
    }

    deinit {
        animationTimer?.invalidate()
        errorDismissal?.cancel()
    }

    /// The invocation mode feeds the accessibility description only; the
    /// indicator itself is click-through and has no controls.
    func configure(invocationMode: @escaping () -> DictationInvocationMode) {
        self.invocationMode = invocationMode
    }

    func showRecording() {
        levelSampler = LiveLevelSampler()
        perform(model.record(showsLiveText: OverlayPreferences.showsLiveText()), lockToCurrentDisplay: true)
    }

    func showProcessing() {
        perform(model.process(), lockToCurrentDisplay: panel == nil)
    }

    func hide() {
        perform(model.hide(), lockToCurrentDisplay: false)
    }

    func showError(_ message: String) {
        perform(model.fail(message), lockToCurrentDisplay: panel == nil)
    }

    func updatePreview(_ text: String) {
        guard model.adopt(text), panel != nil else { return }
        refreshLayout(animated: !reduceMotion)
    }

    private func perform(_ effect: OverlayModel.Effect, lockToCurrentDisplay: Bool) {
        switch effect {
        case .noChange:
            return
        case .present:
            errorDismissal?.cancel()
            errorDismissal = nil
            present(lockToCurrentDisplay: lockToCurrentDisplay)
        case .presentError(let token, let duration):
            present(lockToCurrentDisplay: lockToCurrentDisplay)
            scheduleErrorDismissal(token: token, after: duration)
        case .dismiss:
            errorDismissal?.cancel()
            errorDismissal = nil
            dismiss()
        }
    }

    private func scheduleErrorDismissal(token: UInt64, after duration: TimeInterval) {
        errorDismissal?.cancel()
        let nanoseconds = UInt64(max(duration, 0) * 1_000_000_000)
        errorDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.perform(self.model.expireError(token: token), lockToCurrentDisplay: false)
        }
    }

    // MARK: - Presentation

    private func present(lockToCurrentDisplay: Bool) {
        presentationGeneration &+= 1
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animationStartedAt = CFAbsoluteTimeGetCurrent()

        if lockToCurrentDisplay || activeDisplayID == nil || activeScreen() == nil {
            activeDisplayID = targetScreen()?.displayID
        }
        guard let screen = activeScreen() ?? targetScreen() else {
            logger.error("No display available for recording indicator")
            return
        }

        let geometry = Self.geometry(for: screen, placement: OverlayPreferences.style())
        let isEntering = panel == nil || self.geometry?.style != geometry.style
        self.geometry = geometry

        let bounds = CGRect(origin: .zero, size: geometry.panelFrame.size)
        let view = indicatorView ?? RecordingIndicatorView(frame: bounds)
        view.frame = bounds
        view.configure(style: geometry.style, scale: screen.backingScaleFactor)
        indicatorView = view

        let panel = self.panel ?? Self.makePanel(frame: geometry.panelFrame)
        self.panel = panel
        if panel.contentView !== view { panel.contentView = view }
        panel.setFrame(geometry.panelFrame, display: false)

        let target = layout(in: geometry)
        if isEntering {
            view.apply(layout: geometry.collapsed, contentVisible: false, animated: false)
            let fadesIn = reduceMotion || geometry.style != .notch
            panel.alphaValue = fadesIn ? 0 : 1
            panel.orderFrontRegardless()
            view.apply(layout: target, contentVisible: true, animated: !reduceMotion)
            view.update(phase: model.phase, text: model.displayedText, animated: !reduceMotion)
            if fadesIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            view.apply(layout: target, contentVisible: true, animated: !reduceMotion)
            view.update(phase: model.phase, text: model.displayedText, animated: !reduceMotion)
        }

        announce(on: view)
        renderFrame()
        switch model.phase {
        case .recording, .processing:
            startAnimationTimer()
        case .hidden, .error:
            stopAnimationTimer()
        }
    }

    private func refreshLayout(animated: Bool) {
        guard let geometry, let indicatorView else { return }
        indicatorView.apply(layout: layout(in: geometry), contentVisible: true, animated: animated)
        indicatorView.update(phase: model.phase, text: model.displayedText, animated: animated)
    }

    private func layout(in geometry: RecordingIndicatorGeometry) -> RecordingIndicatorGeometry.Layout {
        model.displayedText == nil ? geometry.compact : geometry.expanded
    }

    private func dismiss() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        stopAnimationTimer()
        guard let panel else {
            activeDisplayID = nil
            return
        }

        let finish = { [weak self, weak panel] in
            guard let self, let panel, self.presentationGeneration == generation else { return }
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            if self.panel === panel {
                self.panel = nil
                self.indicatorView = nil
                self.geometry = nil
                self.activeDisplayID = nil
            }
        }

        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion, let geometry, let indicatorView {
            indicatorView.apply(layout: geometry.collapsed, contentVisible: false, animated: true)
            indicatorView.update(phase: .hidden, text: nil, animated: true)
            if geometry.style == .notch {
                // The island shrinks back behind the notch; no fade needed.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.notchExitDelay, execute: finish)
                return
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func announce(on view: RecordingIndicatorView) {
        guard let label = model.accessibilityLabel else { return }
        let modeName = invocationMode() == .pushToTalk ? "push to talk" : "hands-free"
        view.setAccessibilityLabel(model.phase == .recording ? "\(label), \(modeName)" : label)
        view.setAccessibilityValue(model.displayedText)
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: label,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderFrame()
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func renderFrame() {
        guard let indicatorView else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - animationStartedAt
        let multipliers = Self.barMultipliers

        switch model.phase {
        case .recording:
            let level = CGFloat(levelSampler.next(levelProvider()))
            let amplitudes = multipliers.enumerated().map { (index, multiplier) -> CGFloat in
                let base = min(level * multiplier, 1)
                guard !reduceMotion else { return base }
                let traveling = CGFloat(0.5 + 0.5 * sin((elapsed * 6.2) - Double(index) * 0.9))
                let pulse = traveling * 0.24
                return min(base * (0.76 + pulse) + (1 - base) * (0.03 + pulse * 0.2), 1)
            }
            // A slow breath on the dot says "live" without drawing the eye.
            let dotOpacity: CGFloat = reduceMotion ? 1 : CGFloat(0.8 + 0.2 * cos(elapsed * .pi))
            indicatorView.render(amplitudes: amplitudes, opacities: multipliers.map { _ in 1 }, dotOpacity: dotOpacity)

        case .processing:
            let waves = multipliers.indices.map { (index: Int) -> CGFloat in
                guard !reduceMotion else { return 0.5 }
                return CGFloat(0.5 + 0.5 * sin((elapsed * 5.2) - Double(index) * 1.1))
            }
            indicatorView.render(
                amplitudes: waves.map { 0.15 + $0 * 0.45 },
                opacities: waves.map { 0.35 + $0 * 0.5 },
                dotOpacity: 1
            )

        case .hidden, .error:
            indicatorView.render(
                amplitudes: multipliers.map { _ in 0 },
                opacities: multipliers.map { _ in 1 },
                dotOpacity: 1
            )
        }
    }

    // MARK: - Screens and panel

    private func activeScreen() -> NSScreen? {
        guard let activeDisplayID else { return nil }
        return NSScreen.screens.first { $0.displayID == activeDisplayID }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let index = RecordingIndicatorScreenSelection.screenIndex(
            screenFrames: screens.map(\.frame),
            windowFrame: Self.focusedWindowFrame(),
            mouseLocation: NSEvent.mouseLocation
        )
        if let index, screens.indices.contains(index) { return screens[index] }
        return NSScreen.main ?? screens.first
    }

    /// The frontmost app's frontmost normal window, in AppKit coordinates.
    /// Window bounds need no Screen Recording permission.
    private static func focusedWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else {
                continue
            }
            return RecordingIndicatorScreenSelection.appKitRect(
                fromWindowBounds: bounds,
                primaryScreenHeight: primary.frame.height
            )
        }
        return nil
    }

    private static func geometry(for screen: NSScreen, placement: OverlayStyle) -> RecordingIndicatorGeometry {
        RecordingIndicatorGeometry.resolve(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            placement: placement
        )
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = RecordingIndicatorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
            .ignoresCycle
        ]
        return panel
    }
}

/// Never key or main, so showing it can never take focus from the app the
/// person is dictating into.
private final class RecordingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingIndicatorView: NSView {
    private struct Palette {
        let background: CGColor
        let border: CGColor
        let borderWidth: CGFloat
        let foreground: CGColor
        let shadowOpacity: Float

        static func resolve(style: RecordingIndicatorGeometry.Style, isDark: Bool) -> Palette {
            switch (style, isDark) {
            case (.notch, _):
                // Must match the hardware notch in either appearance.
                return Palette(
                    background: CGColor(gray: 0, alpha: 1),
                    border: CGColor(gray: 0, alpha: 0),
                    borderWidth: 0,
                    foreground: CGColor(gray: 1, alpha: 0.92),
                    shadowOpacity: 0
                )
            case (_, true):
                return Palette(
                    background: CGColor(gray: 0.12, alpha: 0.94),
                    border: CGColor(gray: 1, alpha: 0.14),
                    borderWidth: 0.5,
                    foreground: CGColor(gray: 1, alpha: 0.92),
                    shadowOpacity: 0.35
                )
            case (_, false):
                return Palette(
                    background: CGColor(gray: 0.985, alpha: 0.96),
                    border: CGColor(gray: 0, alpha: 0.1),
                    borderWidth: 0.5,
                    foreground: CGColor(gray: 0.1, alpha: 0.85),
                    shadowOpacity: 0.16
                )
            }
        }
    }

    private static let recordingDot = CGColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
    private static let errorDot = CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)
    private static let minimumBarHeight: CGFloat = 2.5
    private static let textFontSize: CGFloat = 12

    private let capsuleLayer = CALayer()
    private let contentLayer = CALayer()
    private let dotLayer = CALayer()
    private let barsLayer = CALayer()
    private let barLayers: [CALayer]
    private let textLayer = CATextLayer()
    private var style: RecordingIndicatorGeometry.Style = .topPill
    private var phase: OverlayModel.Phase = .hidden

    override init(frame frameRect: NSRect) {
        barLayers = (0..<RecordingIndicatorGeometry.barCount).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        let diameter = RecordingIndicatorGeometry.dotDiameter
        dotLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dotLayer.cornerRadius = diameter / 2
        for barLayer in barLayers {
            barLayer.cornerRadius = RecordingIndicatorGeometry.barWidth / 2
            barsLayer.addSublayer(barLayer)
        }
        textLayer.font = NSFont.systemFont(ofSize: Self.textFontSize, weight: .medium)
        textLayer.fontSize = Self.textFontSize
        textLayer.isWrapped = false
        textLayer.truncationMode = .start
        textLayer.opacity = 0
        contentLayer.opacity = 0

        contentLayer.addSublayer(dotLayer)
        contentLayer.addSublayer(barsLayer)
        contentLayer.addSublayer(textLayer)
        layer?.addSublayer(capsuleLayer)
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textLayer.contentsScale = window?.backingScaleFactor ?? textLayer.contentsScale
    }

    func configure(style: RecordingIndicatorGeometry.Style, scale: CGFloat) {
        self.style = style
        textLayer.contentsScale = scale
        textLayer.alignmentMode = style == .notch ? .center : .left
        capsuleLayer.maskedCorners = style == .notch
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        capsuleLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        capsuleLayer.shadowRadius = 8
        capsuleLayer.shadowOffset = CGSize(width: 0, height: -2)
        needsLayout = true
        layoutSubtreeIfNeeded()
        applyColors()
    }

    func apply(layout: RecordingIndicatorGeometry.Layout, contentVisible: Bool, animated: Bool) {
        let diameter = RecordingIndicatorGeometry.dotDiameter
        Self.spring(capsuleLayer, to: layout.capsule, cornerRadius: layout.cornerRadius, animated: animated)
        Self.spring(
            dotLayer,
            to: CGRect(
                x: layout.dotCenter.x - diameter / 2,
                y: layout.dotCenter.y - diameter / 2,
                width: diameter,
                height: diameter
            ),
            cornerRadius: diameter / 2,
            animated: animated
        )
        Self.spring(barsLayer, to: layout.barsFrame, cornerRadius: 0, animated: animated)
        Self.spring(textLayer, to: layout.textFrame, cornerRadius: 0, animated: animated)
        Self.fade(contentLayer, to: contentVisible ? 1 : 0, duration: animated ? 0.16 : 0)
    }

    func update(phase: OverlayModel.Phase, text: String?, animated: Bool) {
        self.phase = phase
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let text { textLayer.string = text }
        CATransaction.commit()
        let textOpacity: Float
        if text == nil {
            textOpacity = 0
        } else if phase == .processing {
            textOpacity = 0.6
        } else {
            textOpacity = 1
        }
        // Text waits for the shape to open before it fades in.
        let delay: CFTimeInterval = textLayer.opacity == 0 ? 0.08 : 0
        Self.fade(textLayer, to: textOpacity, duration: animated ? 0.16 : 0, delay: animated ? delay : 0)
        if case .error = phase {
            Self.fade(barsLayer, to: 0, duration: animated ? 0.12 : 0)
        } else {
            Self.fade(barsLayer, to: 1, duration: animated ? 0.12 : 0)
        }
        applyColors()
    }

    func render(amplitudes: [CGFloat], opacities: [CGFloat], dotOpacity: CGFloat) {
        let bounds = barsLayer.bounds
        let spacing = RecordingIndicatorGeometry.barWidth + RecordingIndicatorGeometry.barSpacing
        CATransaction.begin()
        // Interpolate between 30 Hz samples instead of stepping.
        CATransaction.setAnimationDuration(1.0 / 30.0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        for (index, barLayer) in barLayers.enumerated() {
            let amplitude = min(max(amplitudes.indices.contains(index) ? amplitudes[index] : 0, 0), 1)
            let opacity = min(max(opacities.indices.contains(index) ? opacities[index] : 1, 0), 1)
            let height = Self.minimumBarHeight + (bounds.height - Self.minimumBarHeight) * amplitude
            barLayer.frame = CGRect(
                x: CGFloat(index) * spacing,
                y: (bounds.height - height) / 2,
                width: RecordingIndicatorGeometry.barWidth,
                height: height
            )
            barLayer.opacity = Float(opacity)
        }
        dotLayer.opacity = Float(min(max(dotOpacity, 0), 1))
        CATransaction.commit()
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = Palette.resolve(style: style, isDark: isDark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsuleLayer.backgroundColor = palette.background
        capsuleLayer.borderColor = palette.border
        capsuleLayer.borderWidth = palette.borderWidth
        capsuleLayer.shadowOpacity = palette.shadowOpacity
        for barLayer in barLayers {
            barLayer.backgroundColor = palette.foreground
        }
        textLayer.foregroundColor = palette.foreground
        switch phase {
        case .recording, .hidden:
            dotLayer.backgroundColor = Self.recordingDot
        case .processing:
            dotLayer.backgroundColor = palette.foreground.copy(alpha: 0.45) ?? palette.foreground
        case .error:
            dotLayer.backgroundColor = Self.errorDot
        }
        CATransaction.commit()
    }

    // MARK: - Motion helpers

    /// Moves a layer with a slightly underdamped spring, starting from where
    /// it is on screen so interrupted transitions stay continuous.
    private static func spring(_ layer: CALayer, to frame: CGRect, cornerRadius: CGFloat, animated: Bool) {
        let current = layer.presentation() ?? layer
        let fromPosition = current.position
        let fromSize = current.bounds.size
        let fromRadius = current.cornerRadius

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.cornerRadius = cornerRadius
        CATransaction.commit()

        guard animated else {
            layer.removeAnimation(forKey: "position")
            layer.removeAnimation(forKey: "bounds.size")
            layer.removeAnimation(forKey: "cornerRadius")
            return
        }
        addSpring(to: layer, keyPath: "position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position),
                  changed: fromPosition != layer.position)
        addSpring(to: layer, keyPath: "bounds.size", from: NSValue(size: fromSize), to: NSValue(size: layer.bounds.size),
                  changed: fromSize != layer.bounds.size)
        addSpring(to: layer, keyPath: "cornerRadius", from: NSNumber(value: Double(fromRadius)),
                  to: NSNumber(value: Double(cornerRadius)), changed: fromRadius != cornerRadius)
    }

    private static func addSpring(to layer: CALayer, keyPath: String, from: Any, to: Any, changed: Bool) {
        guard changed else { return }
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = 340
        animation.damping = 26
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: keyPath)
    }

    private static func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let from = (layer.presentation() ?? layer).opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        guard duration > 0, from != opacity else {
            layer.removeAnimation(forKey: "opacity")
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "opacity")
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
