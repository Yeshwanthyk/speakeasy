import AppKit
import Foundation
import os

/// Turns a dictation into a scrawl: while fn is recording, holding Shift and
/// drawing (or clicking after the first drawing) adds numbered marks. On
/// stop, each mark becomes a cropped keyframe on a contact sheet and the
/// transcript is split per mark, then both go to the clipboard.
@MainActor
final class ScrawlSessionController: AnnotationRecordingObserving {
    struct Actions {
        let currentOffset: () -> Int?
        let commitMark: (Int) -> Bool
        let removeLastMark: () -> Void
        let finishRecording: () -> Void
        let cancelRecording: () -> Void
        let microphoneLevel: () -> MicrophoneLevelSnapshot
        let notify: (UserFeedbackEvent) -> Void
    }

    private enum Phase {
        case idle
        /// Recording; overlay is invisible until Shift is held.
        case armed
        /// At least one mark exists; the control bar is visible.
        case active
        case finishing
    }

    /// Strokes shorter than this are treated as stray Shift-clicks.
    private static let minimumStrokeLength: CGFloat = 8
    /// A stroke starting this soon after the previous one extends that mark.
    private static let strokeMergeInterval: TimeInterval = 1.2
    private static let doubleClickInterval: TimeInterval = 0.35

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "scrawl")
    private let actions: Actions
    private var phase: Phase = .idle
    private var overlay: ScrawlOverlayController?
    private var hudTimer: Timer?
    private var levelSampler = LiveLevelSampler()
    private var recordingStartedAt = Date()
    private var annotations: [ScrawlAnnotation] = []
    private var captures: [Int: Task<CGImage?, Never>] = [:]
    private var liveStroke: [CGPoint] = []
    private var liveStrokeOffset: Int?
    private var liveStrokeScreen: NSScreen?
    private var liveStrokeStartedAt: Date?
    private var lastStrokeEndedAt: Date?
    private var lastClickAt: Date?

    init(actions: Actions) {
        self.actions = actions
    }

    /// Scrawls need ScreenCaptureKit stills (macOS 14) and Screen Recording access.
    static var isAvailable: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return ScrawlScreenAccess.hasPermission()
    }

    // MARK: - AnnotationRecordingObserving

    func annotationRecordingDidStart() {
        guard phase == .idle, Self.isAvailable else { return }
        phase = .armed
        reset()
        recordingStartedAt = Date()
        let overlay = ScrawlOverlayController()
        overlay.onStrokeBegan = { [weak self] point, screen in self?.strokeBegan(at: point, on: screen) }
        overlay.onStrokeMoved = { [weak self] point in self?.strokeMoved(to: point) }
        overlay.onStrokeEnded = { [weak self] in self?.strokeEnded() }
        overlay.onClick = { [weak self] point in self?.clicked(at: point) }
        overlay.onUndo = { [weak self] in self?.undo() }
        overlay.onCancel = { [weak self] in self?.actions.cancelRecording() }
        overlay.onFinish = { [weak self] in self?.actions.finishRecording() }
        overlay.show()
        self.overlay = overlay
    }

    func annotationRecordingDidEnd() {
        // The coordinator already reports cancels and interruptions.
        guard phase == .armed || phase == .active else { return }
        tearDown()
    }

    func annotationRecordingDidFinish(_ result: Result<AnnotationTranscript, AnnotationCaptureError>) {
        guard phase == .active || phase == .armed else { return }
        phase = .finishing
        let marks = annotations
        let pending = captures
        let duration = Date().timeIntervalSince(recordingStartedAt)
        closeOverlay()
        actions.notify(.status("Building scrawl…"))

        Task { [weak self] in
            var images: [Int: CGImage] = [:]
            for (number, task) in pending {
                if let image = await task.value { images[number] = image }
            }
            let captured = images
            let output = await Task.detached(priority: .userInitiated) {
                ScrawlBundleWriter.write(marks: marks, images: captured, result: result, duration: duration)
            }.value
            self?.deliver(output)
        }
    }

    // MARK: - Marks

    private func strokeBegan(at point: CGPoint, on screen: NSScreen) {
        guard phase == .armed || phase == .active else { return }
        liveStroke = [point]
        liveStrokeScreen = screen
        liveStrokeStartedAt = Date()
        liveStrokeOffset = actions.currentOffset()
        render()
    }

    private func strokeMoved(to point: CGPoint) {
        guard let last = liveStroke.last, hypot(point.x - last.x, point.y - last.y) >= 1.5 else { return }
        liveStroke.append(point)
        render()
    }

    private func strokeEnded() {
        let stroke = liveStroke
        let screen = liveStrokeScreen
        let offset = liveStrokeOffset
        let startedAt = liveStrokeStartedAt ?? Date()
        liveStroke = []
        liveStrokeScreen = nil
        liveStrokeOffset = nil
        liveStrokeStartedAt = nil
        defer { render() }

        guard let screen, Self.pathLength(stroke) >= Self.minimumStrokeLength else { return }

        let now = Date()
        if let lastEnded = lastStrokeEndedAt,
           startedAt.timeIntervalSince(lastEnded) <= Self.strokeMergeInterval,
           var previous = annotations.last,
           previous.kind == .stroke,
           previous.displayFrame == screen.frame {
            previous.strokes.append(stroke)
            previous.target = ScrawlWindowLocator.target(at: center(of: previous.bounds)) ?? previous.target
            annotations[annotations.count - 1] = previous
            lastStrokeEndedAt = now
            capture(previous, on: screen)
            return
        }

        guard let offset, actions.commitMark(offset) else { return }
        var annotation = ScrawlAnnotation(
            number: annotations.count + 1,
            kind: .stroke,
            sampleOffset: offset,
            elapsed: startedAt.timeIntervalSince(recordingStartedAt),
            displayFrame: screen.frame,
            strokes: [stroke],
            target: nil
        )
        annotation.target = ScrawlWindowLocator.target(at: center(of: annotation.bounds))
        add(annotation, on: screen)
        lastStrokeEndedAt = now
    }

    private func clicked(at point: CGPoint) {
        // Clicks only become marks once the user has started drawing, so
        // focusing a text field during plain dictation stays plain.
        guard phase == .active else { return }
        let now = Date()
        if let lastClickAt, now.timeIntervalSince(lastClickAt) < Self.doubleClickInterval { return }
        lastClickAt = now
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let offset = actions.currentOffset(),
              actions.commitMark(offset) else {
            return
        }
        let annotation = ScrawlAnnotation(
            number: annotations.count + 1,
            kind: .click,
            sampleOffset: offset,
            elapsed: now.timeIntervalSince(recordingStartedAt),
            displayFrame: screen.frame,
            strokes: [[point]],
            target: ScrawlWindowLocator.target(at: point)
        )
        add(annotation, on: screen)
        render()
    }

    private func add(_ annotation: ScrawlAnnotation, on screen: NSScreen) {
        annotations.append(annotation)
        capture(annotation, on: screen)
        if phase == .armed {
            phase = .active
            overlay?.showHUD()
            startHUDTimer()
        }
    }

    private func undo() {
        guard phase == .active, let removed = annotations.popLast() else { return }
        actions.removeLastMark()
        captures.removeValue(forKey: removed.number)?.cancel()
        lastStrokeEndedAt = nil
        render()
    }

    private func capture(_ annotation: ScrawlAnnotation, on screen: NSScreen) {
        guard #available(macOS 14.0, *), let displayID = screen.scrawlDisplayID else { return }
        captures[annotation.number]?.cancel()
        let logger = logger
        captures[annotation.number] = Task {
            do {
                return try await ScrawlScreenCapturer().capture(displayID: displayID)
            } catch {
                logger.error("Scrawl screenshot failed: \(String(describing: error))")
                return nil
            }
        }
    }

    // MARK: - Delivery

    private func deliver(_ output: ScrawlBundleWriter.Output) {
        phase = .idle
        reset()
        switch output {
        case .success(let text, let contactSheet):
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if let contactSheet {
                item.setData(contactSheet, forType: .png)
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else {
                actions.notify(.error("Scrawl saved, but the clipboard could not be updated"))
                return
            }
            actions.notify(.status("Scrawl copied — paste it into your agent"))
        case .failure(let message):
            actions.notify(.error(message))
        }
    }

    // MARK: - Overlay

    private func render() {
        overlay?.render(annotations: annotations, live: liveStroke.isEmpty ? nil : liveStroke)
    }

    private func startHUDTimer() {
        hudTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHUD() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    private func updateHUD() {
        guard let model = overlay?.hudModel else { return }
        model.elapsed = Date().timeIntervalSince(recordingStartedAt)
        model.level = levelSampler.next(actions.microphoneLevel())
    }

    private func closeOverlay() {
        hudTimer?.invalidate()
        hudTimer = nil
        overlay?.close()
        overlay = nil
    }

    private func tearDown() {
        closeOverlay()
        captures.values.forEach { $0.cancel() }
        phase = .idle
        reset()
    }

    private func reset() {
        annotations = []
        captures = [:]
        liveStroke = []
        liveStrokeOffset = nil
        liveStrokeScreen = nil
        liveStrokeStartedAt = nil
        lastStrokeEndedAt = nil
        lastClickAt = nil
        levelSampler = LiveLevelSampler()
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

/// Writes a scrawl bundle under Application Support and returns the text and
/// contact sheet to copy. Audio is never written to disk.
enum ScrawlBundleWriter {
    enum Output {
        case success(text: String, contactSheet: Data?)
        case failure(String)
    }

    static let retainedBundleCount = 20

    private static let directoryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func write(
        marks: [ScrawlAnnotation],
        images: [Int: CGImage],
        result: Result<AnnotationTranscript, AnnotationCaptureError>,
        duration: TimeInterval
    ) -> Output {
        let transcript: AnnotationTranscript
        switch result {
        case .success(let value):
            transcript = value
        case .failure(.interrupted):
            transcript = AnnotationTranscript(
                segments: Array(repeating: "", count: marks.count + 1),
                failedSegmentCount: marks.count + 1
            )
        }

        let directory: URL
        do {
            directory = try makeDirectory()
        } catch {
            return .failure("Scrawl could not be saved")
        }
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)

        var tiles: [CGImage] = []
        var items: [ScrawlSummary.Item] = []
        do {
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            for (index, mark) in marks.enumerated() {
                let segment = index + 1 < transcript.segments.count ? transcript.segments[index + 1] : ""
                items.append(ScrawlSummary.Item(
                    number: mark.number,
                    elapsed: mark.elapsed,
                    wasClick: mark.kind == .click,
                    targetName: mark.target?.ownerName,
                    transcript: segment
                ))
                guard let image = images[mark.number],
                      let annotated = ScrawlRenderer.annotate(image, annotation: mark) else {
                    continue
                }
                if let png = ScrawlRenderer.pngData(annotated) {
                    let name = String(format: "frame-%02d.png", mark.number)
                    try png.write(to: framesDirectory.appendingPathComponent(name), options: .atomic)
                }
                let container = mark.target.map { $0.frame.intersection(mark.displayFrame) } ?? mark.displayFrame
                let crop = ScrawlCropPlanner.crop(
                    mark: mark.bounds,
                    container: container.isNull || container.isEmpty ? mark.displayFrame : container
                )
                if let tile = ScrawlRenderer.crop(annotated, displayFrame: mark.displayFrame, to: crop) {
                    tiles.append(tile)
                }
            }
        } catch {
            return .failure("Scrawl frames could not be saved")
        }

        var contactSheet: Data?
        var contactSheetPath: String?
        if let sheet = ScrawlRenderer.contactSheet(tiles), let png = ScrawlRenderer.pngData(sheet) {
            let url = directory.appendingPathComponent("contact-sheet.png")
            if (try? png.write(to: url, options: .atomic)) != nil {
                contactSheet = png
                contactSheetPath = url.path
            }
        }

        let text = ScrawlSummary.text(
            bundlePath: directory.path,
            contactSheetPath: contactSheetPath,
            duration: duration,
            preamble: transcript.segments.first ?? "",
            items: items,
            failedSegmentCount: transcript.failedSegmentCount
        )
        try? Data(text.utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
        pruneOldBundles(in: directory.deletingLastPathComponent())
        return .success(text: text, contactSheet: contactSheet)
    }

    private static func makeDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        let url = base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("scrawls", isDirectory: true)
            .appendingPathComponent("scrawl-\(directoryFormatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Screenshots can hold sensitive content; keep only recent bundles.
    private static func pruneOldBundles(in parent: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let bundles = entries
            .filter { $0.lastPathComponent.hasPrefix("scrawl-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in bundles.dropFirst(retainedBundleCount) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
