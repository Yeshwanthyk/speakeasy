import AppKit

/// Shared visual identity: the "Signal Fold" mark from `Assets/AppIcon`.
@MainActor
enum SpeakeasyBrand {
    /// The bundled app icon (`speakeasy.icns`), falling back to a drawn mark
    /// when running outside the app bundle (tests, `swift build`).
    static var appIcon: NSImage {
        if Bundle.main.url(forResource: "speakeasy", withExtension: "icns") != nil {
            return NSApp.applicationIconImage
        }
        return drawnAppIcon
    }

    static let drawnAppIcon: NSImage = NSImage(size: NSSize(width: 256, height: 256), flipped: true) { rect in
        let scale = rect.width / 1024
        let tile = NSBezierPath(
            roundedRect: NSRect(x: 64 * scale, y: 64 * scale, width: 896 * scale, height: 896 * scale),
            xRadius: 220 * scale,
            yRadius: 220 * scale
        )
        NSColor(red: 0.929, green: 0.922, blue: 0.890, alpha: 1).setFill()
        tile.fill()
        NSColor(red: 0.106, green: 0.110, blue: 0.098, alpha: 1).setStroke()
        foldPath(bands: [260, 436, 612, 788], depth: 80, scale: scale, lineWidth: 76).stroke()
        return true
    }

    /// Template status-bar glyph: the four-band fold without the tile.
    static let statusBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 1024
            NSColor.black.setStroke()
            // Bands shifted up to centre the fold within the glyph box.
            foldPath(bands: [200, 400, 600, 800], depth: 110, scale: scale, lineWidth: 96, inset: 60).stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Speakeasy"
        return image
    }()

    private static func foldPath(
        bands: [CGFloat],
        depth: CGFloat,
        scale: CGFloat,
        lineWidth: CGFloat,
        inset: CGFloat = 184
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for y in bands {
            path.move(to: NSPoint(x: inset * scale, y: y * scale))
            path.line(to: NSPoint(x: 392 * scale, y: y * scale))
            path.line(to: NSPoint(x: 464 * scale, y: (y + depth) * scale))
            path.line(to: NSPoint(x: 560 * scale, y: (y + depth) * scale))
            path.line(to: NSPoint(x: 632 * scale, y: y * scale))
            path.line(to: NSPoint(x: (1024 - inset) * scale, y: y * scale))
        }
        return path
    }
}

/// Converts raw microphone RMS snapshots into a perceptual 0...1 display level
/// and reports whether the capture is currently producing fresh samples.
struct LiveLevelSampler {
    /// Consecutive polls without a new sample before the input reads as idle
    /// (the capture only publishes levels while recording).
    static let idleAfterTicks = 4

    private var normalizer = LiveAudioLevelNormalizer()
    private var lastSequence: UInt64?
    private var staleTicks = Int.max
    private(set) var isLive = false

    mutating func next(_ snapshot: MicrophoneLevelSnapshot) -> Float {
        // The first observation only sets a baseline, so a snapshot left over
        // from the previous recording never reads as live.
        if let lastSequence, snapshot.sequence != lastSequence {
            staleTicks = 0
        } else if staleTicks != Int.max {
            staleTicks += 1
        }
        lastSequence = snapshot.sequence
        isLive = staleTicks < Self.idleAfterTicks
        return normalizer.normalizedLevel(forRMS: isLive ? snapshot.normalizedLevel : 0)
    }
}

/// Segmented, colour-graded input meter used in the status menu.
final class LevelMeterView: NSView {
    var level: Float = 0 {
        didSet { if oldValue != level { needsDisplay = true } }
    }
    var isLive = false {
        didSet { if oldValue != isLive { needsDisplay = true } }
    }

    private let segmentCount = 32

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
        let lit = Int((CGFloat(level) * CGFloat(segmentCount)).rounded(.up))
        for index in 0..<segmentCount {
            let fraction = CGFloat(index) / CGFloat(segmentCount - 1)
            // Bars rise toward the centre so the idle meter still reads as a waveform.
            let envelope = 0.45 + 0.55 * sin(fraction * .pi)
            let height = max(bounds.height * envelope, 3)
            let rect = NSRect(
                x: CGFloat(index) * (width + gap),
                y: (bounds.height - height) / 2,
                width: width,
                height: height
            )
            let color: NSColor
            if isLive && index < lit {
                color = Self.color(at: fraction)
            } else {
                color = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
            }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    static func color(at fraction: CGFloat) -> NSColor {
        switch fraction {
        case ..<0.6: return .systemGreen
        case ..<0.82: return .systemYellow
        default: return .systemOrange
        }
    }
}
