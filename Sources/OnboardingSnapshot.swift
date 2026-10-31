import AppKit
import SwiftUI

/// `Speakeasy --onboarding-snapshot <dir>` renders every onboarding preview
/// scenario, light and dark, to PNGs and exits. Nothing is requested,
/// downloaded, or persisted.
@MainActor
enum OnboardingSnapshot {
    static let argument = "--onboarding-snapshot"
    private static let settleNanoseconds: UInt64 = 450_000_000

    static func outputDirectory(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// Returns the files written; throws on the first failure.
    static func render(to directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearance) else { continue }
            for scenario in OnboardingPreviewScenario.all {
                let model = OnboardingModel.preview(scenario)
                let view = OnboardingView(model: model).environment(\.onboardingIsStatic, true)
                let url = directory.appendingPathComponent("\(scenario.name)-\(suffix).png")
                try await capture(view, size: OnboardingWindowController.contentSize, appearance: appearance, to: url)
                written.append(url)
            }
            if let copy = PermissionGuideCopy(.accessibility) {
                let guide = PermissionGuideChrome(instruction: copy.instruction, drawsTileFace: true)
                    .padding(24)
                    .background(Color(nsColor: .underPageBackgroundColor))
                let url = directory.appendingPathComponent("12-guide-panel-\(suffix).png")
                try await capture(guide, size: NSSize(width: 508, height: 160), appearance: appearance, to: url)
                written.append(url)
            }
        }
        return written
    }

    private static func capture<Content: View>(
        _ view: Content,
        size: NSSize,
        appearance: NSAppearance,
        to url: URL
    ) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(nanoseconds: settleNanoseconds)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.noBitmap(url.lastPathComponent)
        }
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noBitmap(url.lastPathComponent)
        }
        try data.write(to: url)
    }

    enum SnapshotError: Error {
        case noBitmap(String)
    }
}
