import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws marks onto screenshots and composes the contact sheet. Pure
/// CoreGraphics, so it runs off the main thread.
enum MarkupRenderer {
    private static let markColor = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    private static let haloColor = CGColor(gray: 1, alpha: 0.55)
    private static let sheetBackground = CGColor(gray: 0.11, alpha: 1)

    /// Returns `image` with `annotation` drawn in the display's pixel space.
    static func annotate(_ image: CGImage, annotation: MarkupAnnotation) -> CGImage? {
        let frame = annotation.displayFrame
        guard frame.width > 0, let context = makeContext(width: image.width, height: image.height) else {
            return nil
        }
        let scale = CGFloat(image.width) / frame.width
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // Bitmap contexts share AppKit's bottom-left origin, so a global
        // point maps by subtracting the display origin and scaling.
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - frame.minX) * scale, y: (point.y - frame.minY) * scale)
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.kind {
        case .stroke:
            for (color, width) in [(haloColor, 7 * scale), (markColor, 4 * scale)] {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                for stroke in annotation.strokes where !stroke.isEmpty {
                    context.addPath(smoothedPath(stroke.map(pixel)))
                    context.strokePath()
                }
            }
        case .click:
            let radius = MarkupAnnotation.clickRadius * scale
            for point in annotation.strokes.flatMap({ $0 }) {
                let center = pixel(point)
                let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.setStrokeColor(haloColor)
                context.setLineWidth(6 * scale)
                context.strokeEllipse(in: ring)
                context.setStrokeColor(markColor)
                context.setLineWidth(3 * scale)
                context.strokeEllipse(in: ring)
            }
        }

        let bounds = annotation.bounds
        if !bounds.isNull {
            drawBadge(
                number: annotation.number,
                elapsed: annotation.elapsed,
                at: pixel(CGPoint(x: bounds.maxX, y: bounds.maxY)),
                scale: scale,
                in: context
            )
        }
        return context.makeImage()
    }

    /// Crops `image` (a capture of `displayFrame`) to `rect` in global points.
    static func crop(_ image: CGImage, displayFrame: CGRect, to rect: CGRect) -> CGImage? {
        guard displayFrame.width > 0 else { return nil }
        let scale = CGFloat(image.width) / displayFrame.width
        // CGImage cropping uses a top-left origin.
        let pixels = CGRect(
            x: (rect.minX - displayFrame.minX) * scale,
            y: (displayFrame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        return image.cropping(to: pixels)
    }

    static func contactSheet(_ tiles: [CGImage]) -> CGImage? {
        let layout = ContactSheetLayout.make(
            tileSizes: tiles.map { CGSize(width: $0.width, height: $0.height) }
        )
        guard let context = makeContext(
            width: Int(layout.canvasSize.width),
            height: Int(layout.canvasSize.height)
        ) else {
            return nil
        }
        context.setFillColor(sheetBackground)
        context.fill(CGRect(origin: .zero, size: layout.canvasSize))
        context.interpolationQuality = .high
        for (tile, frame) in zip(tiles, layout.frames) {
            let flipped = CGRect(
                x: frame.minX,
                y: layout.canvasSize.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            context.draw(tile, in: flipped)
        }
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Midpoint quadratic curves, matching the on-screen canvas.
    static func smoothedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            if points.count == 1 { path.addLine(to: first) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// A dark pill holding a red number cap and the mark's time, so a pasted
    /// contact sheet reads on its own: `#3  0:13`.
    private static func drawBadge(
        number: Int,
        elapsed: TimeInterval,
        at anchor: CGPoint,
        scale: CGFloat,
        in context: CGContext
    ) {
        let height = 28 * scale
        let inset = 2.5 * scale
        let capHeight = height - inset * 2
        let numberLine = textLine("#\(number)", size: 15 * scale, weight: .emphasizedSystem)
        let timeLine = textLine(MarkupSummary.timestamp(elapsed), size: 12.5 * scale, weight: .system)
        let capWidth = max(capHeight, lineWidth(numberLine) + 12 * scale)
        let width = inset + capWidth + 7 * scale + lineWidth(timeLine) + 9 * scale

        // Keep the cap on the mark's corner and grow leftward, inside the crop.
        let origin = CGPoint(
            x: min(max(anchor.x + capHeight / 2 + inset - width, 0), CGFloat(context.width) - width),
            y: min(max(anchor.y - height / 2, 0), CGFloat(context.height) - height)
        )
        let pill = CGRect(origin: origin, size: CGSize(width: width, height: height))
        context.addPath(CGPath(roundedRect: pill, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(sheetBackground)
        context.fillPath()
        context.addPath(CGPath(roundedRect: pill.insetBy(dx: scale / 2, dy: scale / 2), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        context.setLineWidth(1.5 * scale)
        context.strokePath()

        let cap = CGRect(x: pill.minX + inset, y: pill.minY + inset, width: capWidth, height: capHeight)
        context.addPath(CGPath(roundedRect: cap, cornerWidth: capHeight / 2, cornerHeight: capHeight / 2, transform: nil))
        context.setFillColor(markColor)
        context.fillPath()

        draw(numberLine, centeredIn: cap, in: context)
        let timeX = cap.maxX + 7 * scale
        draw(timeLine, centeredIn: CGRect(x: timeX, y: pill.minY, width: lineWidth(timeLine), height: height), in: context)
    }

    private static func textLine(_ text: String, size: CGFloat, weight: CTFontUIFontType) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(weight, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func draw(_ line: CTLine, centeredIn rect: CGRect, in context: CGContext) {
        // Image bounds are relative to the current text position, which the previous draw advanced.
        context.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: rect.midX - bounds.midX, y: rect.midY - bounds.midY)
        CTLineDraw(line, context)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
