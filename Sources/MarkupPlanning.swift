import CoreGraphics
import Foundation

/// One numbered mark made during a markup session. Points use global AppKit
/// screen coordinates (origin at the bottom-left of the primary display).
struct MarkupAnnotation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case stroke
        case click
    }

    static let clickRadius: CGFloat = 16

    let number: Int
    let kind: Kind
    /// Recording sample offset, including pre-roll, when the mark began.
    let sampleOffset: Int
    /// Seconds since the session started.
    let elapsed: TimeInterval
    /// Frame of the display the mark was made on.
    let displayFrame: CGRect
    var strokes: [[CGPoint]]
    /// Frontmost window under the mark when it ended.
    var target: MarkupTarget?

    var bounds: CGRect {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        switch kind {
        case .stroke:
            return rect
        case .click:
            return rect.insetBy(dx: -Self.clickRadius, dy: -Self.clickRadius)
        }
    }
}

/// The window a mark landed on, in global AppKit coordinates.
struct MarkupTarget: Equatable, Sendable {
    let frame: CGRect
    let ownerName: String
}

/// Splits one recording into speech before the first mark plus one span per
/// mark. Cuts snap to the quietest nearby 20 ms frame so words stay whole.
enum MarkupTranscriptCutter {
    static let frameSamples = 320
    static let snapRadiusSamples = 9_600

    /// Returns `cuts.count + 1` contiguous ranges that cover every sample.
    static func ranges(cuts: [Int], samples: ContiguousArray<Float>) -> [Range<Int>] {
        var bounds = [0]
        for cut in cuts {
            let clamped = min(max(cut, 0), samples.count)
            let snapped = snap(clamped, in: samples)
            bounds.append(max(bounds[bounds.count - 1], snapped))
        }
        bounds.append(samples.count)
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
    }

    static func snap(_ cut: Int, in samples: ContiguousArray<Float>) -> Int {
        let lower = max(0, cut - snapRadiusSamples)
        let upper = min(samples.count - frameSamples, cut + snapRadiusSamples)
        guard upper >= lower else { return cut }

        var best = cut
        var bestEnergy = Float.greatestFiniteMagnitude
        var bestDistance = Int.max
        var start = lower
        while start <= upper {
            var energy: Float = 0
            for index in start..<(start + frameSamples) {
                energy += samples[index] * samples[index]
            }
            let distance = abs(start - cut)
            if energy < bestEnergy || (energy == bestEnergy && distance < bestDistance) {
                best = start
                bestEnergy = energy
                bestDistance = distance
            }
            start += frameSamples
        }
        return best
    }
}

/// Chooses the region of a screenshot worth showing for one mark: the mark
/// with generous context, kept inside the window it was drawn on.
enum MarkupCropPlanner {
    static let padding: CGFloat = 160
    static let minimumSize = CGSize(width: 720, height: 450)
    /// Above this share of the container, show the whole container instead.
    static let wholeContainerThreshold: CGFloat = 0.8

    static func crop(mark: CGRect, container: CGRect) -> CGRect {
        guard !container.isNull, !container.isEmpty else { return container }
        guard !mark.isNull else { return container }

        var target = mark.insetBy(dx: -padding, dy: -padding)
        if target.width < minimumSize.width {
            target = target.insetBy(dx: -(minimumSize.width - target.width) / 2, dy: 0)
        }
        if target.height < minimumSize.height {
            target = target.insetBy(dx: 0, dy: -(minimumSize.height - target.height) / 2)
        }

        if target.width >= container.width * wholeContainerThreshold,
           target.height >= container.height * wholeContainerThreshold {
            return container
        }

        // Slide the region inside the container before clipping so a mark
        // near an edge keeps its full context on the other side.
        target.size.width = min(target.width, container.width)
        target.size.height = min(target.height, container.height)
        target.origin.x = min(max(target.minX, container.minX), container.maxX - target.width)
        target.origin.y = min(max(target.minY, container.minY), container.maxY - target.height)
        return target.integral.intersection(container)
    }
}

/// Packs keyframes into the shortest column first. Frames use a top-left
/// origin and are returned in tile order.
struct ContactSheetLayout: Equatable {
    let canvasSize: CGSize
    let frames: [CGRect]

    static func make(
        tileSizes: [CGSize],
        maxColumnWidth: CGFloat = 960,
        spacing: CGFloat = 16,
        maxColumns: Int = 2
    ) -> ContactSheetLayout {
        guard !tileSizes.isEmpty, maxColumns > 0 else {
            return ContactSheetLayout(canvasSize: .zero, frames: [])
        }

        let columnCount = min(maxColumns, tileSizes.count)
        let widest = tileSizes.map(\.width).max() ?? maxColumnWidth
        let columnWidth = min(maxColumnWidth, widest)
        var columnHeights = Array(repeating: spacing, count: columnCount)
        var frames: [CGRect] = []
        frames.reserveCapacity(tileSizes.count)

        for size in tileSizes {
            let scale = size.width > 0 ? min(1, columnWidth / size.width) : 1
            let tile = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            var column = 0
            for index in 1..<columnCount where columnHeights[index] < columnHeights[column] {
                column = index
            }
            let x = spacing + CGFloat(column) * (columnWidth + spacing)
            frames.append(CGRect(origin: CGPoint(x: x, y: columnHeights[column]), size: tile))
            columnHeights[column] += tile.height + spacing
        }

        let width = spacing + CGFloat(columnCount) * (columnWidth + spacing)
        let height = columnHeights.max() ?? spacing
        return ContactSheetLayout(canvasSize: CGSize(width: width, height: height), frames: frames)
    }
}

/// The text handed to an agent alongside the contact sheet.
enum MarkupSummary {
    struct Item: Equatable {
        let number: Int
        let elapsed: TimeInterval
        let wasClick: Bool
        let targetName: String?
        let transcript: String
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func text(
        bundlePath: String,
        contactSheetPath: String?,
        duration: TimeInterval,
        preamble: String,
        items: [Item],
        failedSegmentCount: Int
    ) -> String {
        let markWord = items.count == 1 ? "mark" : "marks"
        var lines = ["[Speakeasy markup · \(timestamp(duration)) · \(items.count) \(markWord) · \(bundlePath)]"]
        if let contactSheetPath {
            lines.append("Contact sheet: \(contactSheetPath) (numbered marks match the list below; full frames in frames/)")
        }
        if !preamble.isEmpty {
            lines.append("\"\(preamble)\"")
        }
        for item in items {
            var label = "#\(item.number) (\(timestamp(item.elapsed)))"
            if item.wasClick { label += " [clicked]" }
            if let targetName = item.targetName, !targetName.isEmpty { label += " \(targetName):" }
            let speech = item.transcript.isEmpty ? "(no speech)" : "\"\(item.transcript)\""
            lines.append("- \(label) \(speech)")
        }
        if failedSegmentCount > 0 {
            let noun = failedSegmentCount == 1 ? "segment" : "segments"
            lines.append("Note: \(failedSegmentCount) speech \(noun) could not be transcribed.")
        }
        return lines.joined(separator: "\n")
    }
}

enum AnnotationCaptureError: Error, Equatable {
    case interrupted
}

/// Speech split at each markup mark.
struct AnnotationTranscript: Equatable, Sendable {
    /// `marks + 1` entries: speech before the first mark, then one per mark.
    let segments: [String]
    let failedSegmentCount: Int
}

/// Receives the dictation lifecycle so marks can turn a recording into a markup.
@MainActor
protocol AnnotationRecordingObserving: AnyObject {
    func annotationRecordingDidStart()
    /// The recording ended without becoming a markup (normal stop, cancel, or interruption).
    func annotationRecordingDidEnd()
    func annotationRecordingDidFinish(_ result: Result<AnnotationTranscript, AnnotationCaptureError>)
}
