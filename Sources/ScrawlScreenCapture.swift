import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScrawlScreenCaptureError: Error, Equatable {
    case displayUnavailable
}

/// Still captures of one display, excluding Speakeasy's own overlay windows
/// so marks are drawn by `ScrawlRenderer` instead of screenshotted.
@available(macOS 14.0, *)
final class ScrawlScreenCapturer: @unchecked Sendable {
    func capture(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScrawlScreenCaptureError.displayUnavailable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

enum ScrawlScreenAccess {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt once; later calls only report the state.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

/// Finds the frontmost normal window under a point without needing a
/// screen capture, so the crop can follow the app that was marked.
enum ScrawlWindowLocator {
    private static let minimumSide: CGFloat = 80

    static func target(at point: CGPoint) -> ScrawlTarget? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // CoreGraphics window bounds use a top-left origin on the primary display.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height

        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= minimumSide, bounds.height >= minimumSide else {
                continue
            }
            let frame = CGRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            guard frame.contains(point) else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            return ScrawlTarget(frame: frame, ownerName: owner)
        }
        return nil
    }
}

extension NSScreen {
    var scrawlDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
