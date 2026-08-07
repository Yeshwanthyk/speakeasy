#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("could not decode \(path)\n", stderr)
        exit(1)
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("could not create pixel context for \(path)\n", stderr)
        exit(1)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    func isCorruptYellow(_ x: Int, _ y: Int) -> Bool {
        let index = (y * width + x) * 4
        let red = pixels[index]
        let green = pixels[index + 1]
        let blue = pixels[index + 2]
        let alpha = pixels[index + 3]
        return alpha > 240 && red > 220 && green > 170 && blue < 80
    }

    var corruptEdgePixels = 0
    for x in 0..<width {
        corruptEdgePixels += isCorruptYellow(x, 0) ? 1 : 0
        corruptEdgePixels += isCorruptYellow(x, height - 1) ? 1 : 0
    }
    if height > 2 {
        for y in 1..<(height - 1) {
            corruptEdgePixels += isCorruptYellow(0, y) ? 1 : 0
            corruptEdgePixels += isCorruptYellow(width - 1, y) ? 1 : 0
        }
    }
    guard corruptEdgePixels == 0 else {
        fputs("\(path) contains \(corruptEdgePixels) opaque saturated-yellow edge pixels\n", stderr)
        exit(1)
    }
}
