import AppKit
import Foundation
import os

/// Turns a dictation into a markup: while fn is recording, holding Shift and
/// moving the pointer draws a numbered mark, Shift-clicking pins a point or
/// removes the mark under it, and scrolling fades marks off screen. On
/// stop, each mark becomes a cropped keyframe on a contact sheet and the
/// transcript is split per mark, then both go to the clipboard.
@MainActor
final class MarkupSessionController: AnnotationRecordingObserving {
    struct Actions {
        let currentOffset: () -> Int?
        let commitMark: (Int) -> Bool
        let removeMark: (Int) -> Void
        let finishRecording: () -> Void
        let cancelRecording: () -> Void
        /// Pastes into the front app; false when no paste could be posted.
        let pasteMarkup: (String) -> Bool
        let microphoneLevel: () -> MicrophoneLevelSnapshot
        let notify: (UserFeedbackEvent) -> Void
    }

    private enum Phase {
        case idle
        /// Recording; overlay shows nothing until a mark exists.
        case armed
        /// At least one mark exists; the control bar is visible.
        case active
        case finishing
    }

    /// Ink that strays less than this from its start is a stationary Shift
    /// press (a capital letter, a Shift-click), not a mark.
    private static let minimumStrokeSpan: CGFloat = 6
    /// A stroke starting this soon after the previous one extends that mark.
    private static let strokeMergeInterval: TimeInterval = 1.2
    private static let doubleClickInterval: TimeInterval = 0.35

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "markup")
    private let actions: Actions
    private var phase: Phase = .idle
    private var overlay: MarkupOverlayController?
    private var hudTimer: Timer?
    private var levelSampler = LiveLevelSampler()
    private var recordingStartedAt = Date()
    private var annotations: [MarkupAnnotation] = []
    /// Keyed by `sampleOffset`, which stays fixed when marks are renumbered.
    private var captures: [Int: Task<CGImage?, Never>] = [:]
    /// Sample offsets of marks faded off screen by a scroll.
    private var scrolledAway: Set<Int> = []
    private var liveStroke: [CGPoint] = []
    private var liveStrokeOffset: Int?
    private var liveStrokeScreen: NSScreen?
    private var liveStrokeStartedAt: Date?
    private var lastStrokeEndedAt: Date?
    private var lastClickAt: Date?

    init(actions: Actions) {
        self.actions = actions
    }

    /// Markups need ScreenCaptureKit stills (macOS 14) and Screen Recording access.
    static var isAvailable: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return MarkupScreenAccess.hasPermission()
    }

    // MARK: - AnnotationRecordingObserving

    func annotationRecordingDidStart() {
        guard phase == .idle, Self.isAvailable else { return }
        phase = .armed
        reset()
        recordingStartedAt = Date()
        let overlay = MarkupOverlayController()
        overlay.onInkBegan = { [weak self] point, screen in self?.strokeBegan(at: point, on: screen) }
        overlay.onInkMoved = { [weak self] point in self?.strokeMoved(to: point) }
        overlay.onInkEnded = { [weak self] in self?.strokeEnded() }
        overlay.onShiftClick = { [weak self] point in self?.shiftClicked(at: point) }
        overlay.onScroll = { [weak self] in self?.scrolled() }
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
        actions.notify(.status("Building markup…"))

        Task { [weak self] in
            var images: [Int: CGImage] = [:]
            for mark in marks {
                if let image = await pending[mark.sampleOffset]?.value { images[mark.number] = image }
            }
            let captured = images
            let output = await Task.detached(priority: .userInitiated) {
                MarkupBundleWriter.write(marks: marks, images: captured, result: result, duration: duration)
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

        guard let screen, Self.span(stroke) >= Self.minimumStrokeSpan else { return }

        let now = Date()
        if let lastEnded = lastStrokeEndedAt,
           startedAt.timeIntervalSince(lastEnded) <= Self.strokeMergeInterval,
           var previous = annotations.last,
           previous.kind == .stroke,
           !scrolledAway.contains(previous.sampleOffset),
           previous.displayFrame == screen.frame {
            previous.strokes.append(stroke)
            previous.target = MarkupWindowLocator.target(at: center(of: previous.bounds)) ?? previous.target
            annotations[annotations.count - 1] = previous
            lastStrokeEndedAt = now
            capture(previous, on: screen)
            return
        }

        guard let offset, actions.commitMark(offset) else { return }
        var annotation = MarkupAnnotation(
            number: annotations.count + 1,
            kind: .stroke,
            sampleOffset: offset,
            elapsed: startedAt.timeIntervalSince(recordingStartedAt),
            displayFrame: screen.frame,
            strokes: [stroke],
            target: nil
        )
        annotation.target = MarkupWindowLocator.target(at: center(of: annotation.bounds))
        add(annotation, on: screen)
        lastStrokeEndedAt = now
    }

    private func shiftClicked(at point: CGPoint) {
        guard phase == .armed || phase == .active else { return }
        let now = Date()
        // A Shift-double-click would pin and then remove the same point.
        if let lastClickAt, now.timeIntervalSince(lastClickAt) < Self.doubleClickInterval { return }
        lastClickAt = now
        if let index = annotations.lastIndex(where: {
            !scrolledAway.contains($0.sampleOffset) && MarkupHitTest.hits($0, at: point)
        }) {
            removeMark(at: index)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let offset = actions.currentOffset(),
              actions.commitMark(offset) else {
            return
        }
        let annotation = MarkupAnnotation(
            number: annotations.count + 1,
            kind: .click,
            sampleOffset: offset,
            elapsed: now.timeIntervalSince(recordingStartedAt),
            displayFrame: screen.frame,
            strokes: [[point]],
            target: MarkupWindowLocator.target(at: point)
        )
        add(annotation, on: screen)
        render()
    }

    private func scrolled() {
        let onScreen = annotations.filter { !scrolledAway.contains($0.sampleOffset) }
        guard !onScreen.isEmpty else { return }
        scrolledAway.formUnion(onScreen.map(\.sampleOffset))
        lastStrokeEndedAt = nil
        overlay?.fadeOut(onScreen)
        render()
    }

    private func add(_ annotation: MarkupAnnotation, on screen: NSScreen) {
        annotations.append(annotation)
        capture(annotation, on: screen)
        if phase == .armed {
            phase = .active
            overlay?.showHUD(on: screen)
            startHUDTimer()
        }
    }

    private func undo() {
        removeMark(at: annotations.count - 1)
    }

    private func removeMark(at index: Int) {
        guard phase == .active, annotations.indices.contains(index) else { return }
        let removed = annotations.remove(at: index)
        actions.removeMark(removed.sampleOffset)
        captures.removeValue(forKey: removed.sampleOffset)?.cancel()
        scrolledAway.remove(removed.sampleOffset)
        for position in annotations.indices {
            annotations[position].number = position + 1
        }
        lastStrokeEndedAt = nil
        render()
    }

    private func capture(_ annotation: MarkupAnnotation, on screen: NSScreen) {
        guard #available(macOS 14.0, *), let displayID = screen.markupDisplayID else { return }
        captures[annotation.sampleOffset]?.cancel()
        let logger = logger
        captures[annotation.sampleOffset] = Task {
            do {
                return try await MarkupScreenCapturer().capture(displayID: displayID)
            } catch {
                logger.error("Markup screenshot failed: \(String(describing: error))")
                return nil
            }
        }
    }

    // MARK: - Delivery

    private func deliver(_ output: MarkupBundleWriter.Output) {
        phase = .idle
        reset()
        switch output {
        case .success(let text):
            // Text only: apps given text and an image on one item paste just
            // the image. The text names the contact sheet's path.
            if actions.pasteMarkup(text) { return }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                actions.notify(.error("Markup saved, but the clipboard could not be updated"))
                return
            }
            actions.notify(.status("Markup copied — paste it into your agent"))
        case .failure(let message):
            actions.notify(.error(message))
        }
    }

    // MARK: - Overlay

    private func render() {
        overlay?.render(
            annotations: annotations.filter { !scrolledAway.contains($0.sampleOffset) },
            markCount: annotations.count,
            live: liveStroke.isEmpty ? nil : liveStroke
        )
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
        scrolledAway = []
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

    /// Farthest distance from the first point, so jitter in place stays small.
    private static func span(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        return points.reduce(0) { max($0, hypot($1.x - first.x, $1.y - first.y)) }
    }
}

/// Writes a markup bundle under Application Support and returns the text and
/// contact sheet to copy. Audio is never written to disk.
enum MarkupBundleWriter {
    enum Output {
        case success(text: String)
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
        marks: [MarkupAnnotation],
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
            return .failure("Markup could not be saved")
        }
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)

        var tiles: [CGImage] = []
        var items: [MarkupSummary.Item] = []
        do {
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            for (index, mark) in marks.enumerated() {
                let segment = index + 1 < transcript.segments.count ? transcript.segments[index + 1] : ""
                items.append(MarkupSummary.Item(
                    number: mark.number,
                    elapsed: mark.elapsed,
                    wasClick: mark.kind == .click,
                    targetName: mark.target?.ownerName,
                    transcript: segment
                ))
                guard let image = images[mark.number],
                      let annotated = MarkupRenderer.annotate(image, annotation: mark) else {
                    continue
                }
                if let png = MarkupRenderer.pngData(annotated) {
                    let name = String(format: "frame-%02d.png", mark.number)
                    try png.write(to: framesDirectory.appendingPathComponent(name), options: .atomic)
                }
                let container = mark.target.map { $0.frame.intersection(mark.displayFrame) } ?? mark.displayFrame
                let crop = MarkupCropPlanner.crop(
                    mark: mark.bounds,
                    container: container.isNull || container.isEmpty ? mark.displayFrame : container
                )
                if let tile = MarkupRenderer.crop(annotated, displayFrame: mark.displayFrame, to: crop) {
                    tiles.append(tile)
                }
            }
        } catch {
            return .failure("Markup frames could not be saved")
        }

        var contactSheetPath: String?
        if let sheet = MarkupRenderer.contactSheet(tiles), let png = MarkupRenderer.pngData(sheet) {
            let url = directory.appendingPathComponent("contact-sheet.png")
            if (try? png.write(to: url, options: .atomic)) != nil {
                contactSheetPath = url.path
            }
        }

        let text = MarkupSummary.text(
            bundlePath: directory.path,
            contactSheetPath: contactSheetPath,
            duration: duration,
            preamble: transcript.segments.first ?? "",
            items: items,
            failedSegmentCount: transcript.failedSegmentCount
        )
        try? Data(text.utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
        pruneOldBundles(in: directory.deletingLastPathComponent())
        return .success(text: text)
    }

    private static func makeDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "Speakeasy"
        let url = base
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("markups", isDirectory: true)
            .appendingPathComponent("markup-\(directoryFormatter.string(from: Date()))", isDirectory: true)
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
            .filter { $0.lastPathComponent.hasPrefix("markup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in bundles.dropFirst(retainedBundleCount) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
