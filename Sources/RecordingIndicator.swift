import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import os

// The notch geometry and compact signal treatment are adapted from Megaphone's
// MIT-licensed RecordingOverlay.swift. See THIRD_PARTY_NOTICES.md.

enum RecordingFeedbackPhase: Equatable, Sendable {
    case recording
    case processing
}

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

struct RecordingIndicatorGeometry: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case notchWings
        case topPill
    }

    static let wingWidth: CGFloat = 36
    static let pillWidth: CGFloat = 92
    static let pillHeight: CGFloat = 30

    let style: Style
    let panelFrame: CGRect
    let signalFrame: CGRect
    let bottomCornerRadius: CGFloat

    static func resolve(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> RecordingIndicatorGeometry {
        if safeAreaTop > 0,
           let leftArea = auxiliaryTopLeftArea,
           let rightArea = auxiliaryTopRightArea {
            let notchWidth = screenFrame.width - leftArea.width - rightArea.width
            if notchWidth > 0 {
                let height = max(screenFrame.maxY - visibleFrame.maxY, safeAreaTop)
                let width = wingWidth + notchWidth + wingWidth
                return RecordingIndicatorGeometry(
                    style: .notchWings,
                    panelFrame: CGRect(
                        x: leftArea.maxX - wingWidth,
                        y: screenFrame.maxY - height,
                        width: width,
                        height: height
                    ),
                    signalFrame: CGRect(x: 0, y: 0, width: wingWidth, height: height),
                    bottomCornerRadius: 12
                )
            }
        }

        return RecordingIndicatorGeometry(
            style: .topPill,
            panelFrame: CGRect(
                x: screenFrame.midX - pillWidth / 2,
                y: screenFrame.maxY - pillHeight,
                width: pillWidth,
                height: pillHeight
            ),
            signalFrame: CGRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
            bottomCornerRadius: 12
        )
    }
}

struct LiveAudioLevelNormalizer {
    private static let minimumRMS: Float = 0.00001
    private static let minSpanDB: Float = 18
    private static let peakHeadroomDB: Float = 8
    private static let speechGateMarginDB: Float = 3
    private static let minimumVisibleActiveLevel: Float = 0.12
    private static let noiseGateNormalizedThreshold: Float = 0.06
    private static let floorRiseWindowDB: Float = 4
    private static let floorFallBlend: Float = 0.12
    private static let floorRiseBlend: Float = 0.02
    private static let peakAttackBlend: Float = 0.55
    private static let peakReleaseBlend: Float = 0.04
    private static let displayAttackBlend: Float = 0.45
    private static let displayReleaseBlend: Float = 0.12

    private var noiseFloorDB: Float = -55
    private var peakCeilingDB: Float = -37
    private var displayLevel: Float = 0

    mutating func reset() {
        noiseFloorDB = -55
        peakCeilingDB = -37
        displayLevel = 0
    }

    mutating func normalizedLevel(forRMS rms: Float) -> Float {
        let safeRMS = rms.isFinite ? max(rms, Self.minimumRMS) : Self.minimumRMS
        let levelDB = 20 * log10f(safeRMS)

        updateNoiseFloor(with: levelDB)
        updatePeakCeiling(with: levelDB)

        let displayCeilingDB = peakCeilingDB + Self.peakHeadroomDB
        let dynamicSpan = max(displayCeilingDB - noiseFloorDB, Self.minSpanDB + Self.peakHeadroomDB)
        var normalized = clamp((levelDB - noiseFloorDB) / dynamicSpan)
        let isActiveSpeech = levelDB >= noiseFloorDB + Self.speechGateMarginDB

        if normalized < Self.noiseGateNormalizedThreshold,
           levelDB <= noiseFloorDB + Self.speechGateMarginDB {
            normalized = 0
        } else if isActiveSpeech {
            normalized = max(normalized, Self.minimumVisibleActiveLevel)
        }

        let blend = normalized > displayLevel ? Self.displayAttackBlend : Self.displayReleaseBlend
        displayLevel = mix(displayLevel, normalized, blend)
        return displayLevel
    }

    private mutating func updateNoiseFloor(with levelDB: Float) {
        let ceilingLimitedLevel = min(levelDB, peakCeilingDB - Self.minSpanDB)
        if ceilingLimitedLevel <= noiseFloorDB {
            noiseFloorDB = mix(noiseFloorDB, ceilingLimitedLevel, Self.floorFallBlend)
        } else if ceilingLimitedLevel <= noiseFloorDB + Self.floorRiseWindowDB {
            noiseFloorDB = mix(noiseFloorDB, ceilingLimitedLevel, Self.floorRiseBlend)
        }
    }

    private mutating func updatePeakCeiling(with levelDB: Float) {
        let minimumCeiling = noiseFloorDB + Self.minSpanDB
        if levelDB >= peakCeilingDB {
            peakCeilingDB = mix(peakCeilingDB, levelDB, Self.peakAttackBlend)
        } else {
            peakCeilingDB = mix(peakCeilingDB, max(levelDB, minimumCeiling), Self.peakReleaseBlend)
        }
        peakCeilingDB = max(peakCeilingDB, minimumCeiling)
    }

    private func mix(_ current: Float, _ target: Float, _ blend: Float) -> Float {
        current + (target - current) * blend
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

@MainActor
final class RecordingIndicator: RecordingFeedbackPresenting {
    typealias LevelProvider = @MainActor () -> MicrophoneLevelSnapshot

    private static let animationInterval: TimeInterval = 1.0 / 30.0
    private static let barMultipliers: [CGFloat] = [0.5, 0.75, 1, 0.75, 0.5]

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "recording-indicator")
    private let levelProvider: LevelProvider
    private let bottomOverlay = BottomOverlay()

    func configureBottom(mode: @escaping () -> DictationInvocationMode,
                         selectMode: @escaping (DictationInvocationMode) -> Void,
                         copyLast: @escaping () -> Void,
                         pasteLast: @escaping () -> Void,
                         undoLast: @escaping () -> Void) {
        bottomOverlay.currentMode = mode
        bottomOverlay.selectMode = selectMode
        bottomOverlay.copyLast = copyLast
        bottomOverlay.pasteLast = pasteLast
        bottomOverlay.undoLast = undoLast
        bottomOverlay.model.start(mode: mode())
    }

    func updatePreview(_ text: String) { bottomOverlay.updatePreview(text) }
    func showError(_ message: String) { bottomOverlay.showError(message) }
    private var panel: NSPanel?
    private var indicatorView: RecordingIndicatorView?
    private var animationTimer: Timer?
    private var activeDisplayID: CGDirectDisplayID?
    private var phase: RecordingFeedbackPhase = .recording
    private var levelNormalizer = LiveAudioLevelNormalizer()
    private var animationStartedAt = CFAbsoluteTimeGetCurrent()
    private var presentationGeneration: UInt64 = 0

    init(levelProvider: @escaping LevelProvider) {
        self.levelProvider = levelProvider
        bottomOverlay.levelProvider = { levelProvider().normalizedLevel }
    }

    deinit {
        animationTimer?.invalidate()
    }

    func showRecording() {
        if OverlayPreferences.style() == .bottomPill {
            bottomOverlay.showRecording()
            return
        }
        levelNormalizer.reset()
        show(phase: .recording, lockToCurrentDisplay: true)
    }

    func showProcessing() {
        if OverlayPreferences.style() == .bottomPill {
            bottomOverlay.showProcessing()
            return
        }
        show(phase: .processing, lockToCurrentDisplay: panel == nil)
    }

    func hide() {
        bottomOverlay.hide()
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
                self.activeDisplayID = nil
            }
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func show(phase: RecordingFeedbackPhase, lockToCurrentDisplay: Bool) {
        presentationGeneration &+= 1
        self.phase = phase
        animationStartedAt = CFAbsoluteTimeGetCurrent()

        if lockToCurrentDisplay || activeDisplayID == nil {
            activeDisplayID = targetScreen()?.displayID
        }
        guard let screen = activeScreen() ?? targetScreen() else {
            logger.error("No display available for recording indicator")
            return
        }

        let geometry = Self.geometry(for: screen)
        let view = indicatorView ?? RecordingIndicatorView(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        view.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        view.update(geometry: geometry)
        let accessibilityLabel = phase == .recording
            ? "Speakeasy is recording"
            : "Speakeasy is processing dictation"
        view.setAccessibilityLabel(accessibilityLabel)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: view,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: accessibilityLabel,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
        indicatorView = view

        if let panel {
            panel.contentView = view
            panel.alphaValue = 1
            panel.setFrame(geometry.panelFrame, display: true)
            panel.orderFrontRegardless()
        } else {
            let panel = Self.makePanel(frame: geometry.panelFrame)
            panel.contentView = view
            self.panel = panel

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 1
                panel.setFrame(geometry.panelFrame, display: true)
                panel.orderFrontRegardless()
            } else {
                var entranceFrame = geometry.panelFrame
                entranceFrame.origin.y += 4
                panel.alphaValue = 0
                panel.setFrame(entranceFrame, display: true)
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(geometry.panelFrame, display: true)
                }
            }
        }

        renderFrame()
        startAnimationTimer()
    }

    private func startAnimationTimer() {
        stopAnimationTimer()
        let timer = Timer(timeInterval: Self.animationInterval, repeats: true) { [weak self] _ in
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let amplitudes: [CGFloat]
        let opacities: [CGFloat]

        switch phase {
        case .recording:
            let level = CGFloat(levelNormalizer.normalizedLevel(forRMS: levelProvider().normalizedLevel))
            amplitudes = Self.barMultipliers.enumerated().map { index, multiplier in
                let base = min(level * multiplier, 1)
                guard !reduceMotion else { return base }
                let traveling = CGFloat(0.5 + 0.5 * sin((elapsed * 6.2) - Double(index) * 0.78))
                let shimmer = CGFloat(0.5 + 0.5 * sin((elapsed * 3.1) + Double(index) * 0.5))
                let pulse = traveling * 0.22 + shimmer * 0.06
                return min(base * (0.74 + pulse) + (1 - base) * (0.04 + pulse * 0.28), 1)
            }
            opacities = Array(repeating: 1, count: Self.barMultipliers.count)

        case .processing:
            amplitudes = Self.barMultipliers.indices.map { index in
                guard !reduceMotion else { return index == 2 ? 0.72 : 0.3 }
                let wave = CGFloat(0.5 + 0.5 * sin((elapsed * 5.2) - Double(index) * 0.9))
                return 0.18 + wave * 0.64
            }
            opacities = Self.barMultipliers.indices.map { index in
                guard !reduceMotion else { return index == 2 ? 0.95 : 0.45 }
                let wave = CGFloat(0.5 + 0.5 * sin((elapsed * 5.2) - Double(index) * 0.9))
                return 0.42 + wave * 0.5
            }
        }

        indicatorView.render(amplitudes: amplitudes, opacities: opacities)
    }

    private func activeScreen() -> NSScreen? {
        guard let activeDisplayID else { return nil }
        return NSScreen.screens.first { $0.displayID == activeDisplayID }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func geometry(for screen: NSScreen) -> RecordingIndicatorGeometry {
        RecordingIndicatorGeometry.resolve(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
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
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        return panel
    }
}

@MainActor
private final class RecordingIndicatorView: NSView {
    private static let minimumBarHeight: CGFloat = 2
    private static let maximumBarHeight: CGFloat = 14
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.5

    private let backgroundLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let barLayers = (0..<5).map { _ in CALayer() }
    private var geometry = RecordingIndicatorGeometry.resolve(
        screenFrame: .zero,
        visibleFrame: .zero,
        safeAreaTop: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        backgroundLayer.backgroundColor = NSColor.black.cgColor
        backgroundLayer.mask = maskLayer
        layer?.addSublayer(backgroundLayer)
        for barLayer in barLayers {
            barLayer.backgroundColor = NSColor.white.cgColor
            backgroundLayer.addSublayer(barLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        maskLayer.frame = bounds
        maskLayer.path = Self.bottomRoundedPath(in: bounds, radius: geometry.bottomCornerRadius)
        CATransaction.commit()
    }

    func update(geometry: RecordingIndicatorGeometry) {
        self.geometry = geometry
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func render(amplitudes: [CGFloat], opacities: [CGFloat]) {
        let signalFrame = geometry.signalFrame
        let totalWidth = CGFloat(barLayers.count) * Self.barWidth
            + CGFloat(barLayers.count - 1) * Self.barSpacing
        let firstX = signalFrame.midX - totalWidth / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            let amplitude = min(max(amplitudes[safe: index] ?? 0, 0), 1)
            let height = Self.minimumBarHeight
                + (Self.maximumBarHeight - Self.minimumBarHeight) * amplitude
            barLayer.frame = CGRect(
                x: firstX + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                y: signalFrame.midY - height / 2,
                width: Self.barWidth,
                height: height
            )
            barLayer.cornerRadius = Self.barWidth / 2
            barLayer.opacity = Float(min(max(opacities[safe: index] ?? 1, 0), 1))
        }
        CATransaction.commit()
    }

    private static func bottomRoundedPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
