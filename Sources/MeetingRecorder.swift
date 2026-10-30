import AppKit
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

// MARK: - Preferences

enum MeetingPreferences {
    static let enabledKey = "meetingsEnabled"
    static let detectCallsKey = "meetingsDetectCalls"
    static let systemAudioKey = "meetingsCaptureSystemAudio"
    static let keepAudioDaysKey = "meetingsKeepAudioDays"

    /// Retention choices; `nil` keeps audio forever, 0 deletes it once the
    /// transcript is written.
    static let keepAudioChoices: [Int?] = [0, 7, 30, 90, nil]

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func detectsCalls(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: detectCallsKey) as? Bool ?? true
    }

    static func capturesSystemAudio(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: systemAudioKey) as? Bool ?? true
    }

    /// Default 30 days; a stored negative value means forever.
    static func keepAudioDays(defaults: UserDefaults = .standard) -> Int? {
        guard let stored = defaults.object(forKey: keepAudioDaysKey) as? Int else { return 30 }
        return stored < 0 ? nil : stored
    }

    static func setKeepAudioDays(_ days: Int?, defaults: UserDefaults = .standard) {
        defaults.set(days ?? -1, forKey: keepAudioDaysKey)
    }
}

// MARK: - System audio

/// Captures everything the Mac plays (the other side of a call) with
/// ScreenCaptureKit, excluding Speakeasy's own sounds. Needs Screen
/// Recording access, the same permission markups use.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: Error {
        case noDisplay
    }

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "meetings")
    private let queue = DispatchQueue(label: "com.speakeasy.app.meeting.system-audio", qos: .userInitiated)
    private let onSamples: (UnsafeBufferPointer<Float>) -> Void
    private let onStop: (Error?) -> Void
    private var stream: SCStream?

    init(onSamples: @escaping (UnsafeBufferPointer<Float>) -> Void, onStop: @escaping (Error?) -> Void) {
        self.onSamples = onSamples
        self.onStop = onStop
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        // Video is required by the API but unused: keep it tiny and slow.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            logger.error("Stopping system audio failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32 else {
            return
        }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                // Mono is requested; with more channels, keep the first.
                guard let buffer = buffers.first, let data = buffer.mData else { return }
                let stride = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                    ? 1 : Int(max(1, description.mChannelsPerFrame))
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = data.assumingMemoryBound(to: Float.self)
                if stride == 1 {
                    onSamples(UnsafeBufferPointer(start: pointer, count: count))
                } else {
                    let mono = (0..<(count / stride)).map { pointer[$0 * stride] }
                    mono.withUnsafeBufferPointer { onSamples($0) }
                }
            }
        } catch {
            logger.error("System audio buffer unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("System audio stopped: \(String(describing: error), privacy: .public)")
        onStop(error)
    }
}

// MARK: - One track

/// Writes one track to disk and cuts it into segments for transcription.
/// All work runs on a private serial queue; memory stays bounded by the
/// longest segment no matter how long the meeting runs.
final class MeetingTrackPipeline: @unchecked Sendable {
    let track: MeetingTrack
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "meetings")
    private let queue: DispatchQueue
    private let writer: ChunkedWAVWriter?
    private let onSegment: (MeetingTrack, TimeInterval, ContiguousArray<Float>) -> Void
    private var segmenter = MeetingSegmenter()
    private var window = MeetingSampleWindow()
    private var pendingFrame: [Float] = []
    /// Seconds after the meeting start when this track's first sample arrived.
    private var startOffset: TimeInterval?
    private let meetingStart: Date
    private var didLogWriteFailure = false

    init(
        track: MeetingTrack,
        meetingStart: Date,
        writer: ChunkedWAVWriter?,
        onSegment: @escaping (MeetingTrack, TimeInterval, ContiguousArray<Float>) -> Void
    ) {
        self.track = track
        self.meetingStart = meetingStart
        self.writer = writer
        self.onSegment = onSegment
        queue = DispatchQueue(label: "com.speakeasy.app.meeting.\(track.rawValue)", qos: .utility)
    }

    /// Copies the samples; safe to call from an audio callback.
    func ingest(_ samples: UnsafeBufferPointer<Float>) {
        let copy = Array(samples)
        let arrival = Date()
        queue.async { [self] in
            if startOffset == nil {
                startOffset = max(0, arrival.timeIntervalSince(meetingStart))
            }
            process(copy)
        }
    }

    /// Flushes the last segment and closes the audio file; returns chunk names.
    func finish(completion: @escaping ([String]) -> Void) {
        queue.async { [self] in
            if !pendingFrame.isEmpty {
                feedFrame(pendingFrame)
                pendingFrame = []
            }
            if let range = segmenter.finish() {
                emit(range)
            }
            do {
                try writer?.finish()
            } catch {
                logger.error("Closing \(self.track.rawValue, privacy: .public) audio failed: \(String(describing: error), privacy: .public)")
            }
            completion(writer?.chunkNames ?? [])
        }
    }

    private func process(_ samples: [Float]) {
        do {
            try writer?.append(samples)
        } catch where !didLogWriteFailure {
            didLogWriteFailure = true
            logger.error("Writing \(self.track.rawValue, privacy: .public) audio failed: \(String(describing: error), privacy: .public)")
        } catch {}
        samples.withUnsafeBufferPointer { window.append($0) }

        var index = 0
        if !pendingFrame.isEmpty {
            let needed = MeetingSegmenter.frameSamples - pendingFrame.count
            let take = min(needed, samples.count)
            pendingFrame.append(contentsOf: samples[0..<take])
            index = take
            if pendingFrame.count == MeetingSegmenter.frameSamples {
                feedFrame(pendingFrame)
                pendingFrame = []
            }
        }
        while index + MeetingSegmenter.frameSamples <= samples.count {
            feedFrame(Array(samples[index..<(index + MeetingSegmenter.frameSamples)]))
            index += MeetingSegmenter.frameSamples
        }
        if index < samples.count {
            pendingFrame.append(contentsOf: samples[index...])
        }
    }

    private func feedFrame(_ frame: [Float]) {
        let rms = (frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, frame.count))).squareRoot()
        if let range = segmenter.feed(rms: rms) {
            emit(range)
        }
        window.discard(through: segmenter.segmentStart)
    }

    private func emit(_ range: Range<Int>) {
        let audio = window.take(range)
        guard !audio.isEmpty else { return }
        let start = (startOffset ?? 0) + Double(range.lowerBound) / Double(MeetingSegmenter.sampleRate)
        onSegment(track, start, audio)
    }
}

// MARK: - Transcription worker

/// Transcribes finished segments one at a time off the main thread and logs
/// them to the meeting folder. Bounded: when the transcriber falls behind,
/// extra segments are skipped and counted instead of queuing without limit.
final class MeetingTranscriptionWorker: @unchecked Sendable {
    /// Segments waiting for the transcriber.
    static let maximumPendingSegments = 60

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "meetings")
    private let queue = DispatchQueue(label: "com.speakeasy.app.meeting.transcribe", qos: .utility)
    private let lock = UnfairLock()
    private let library: MeetingLibrary
    private let transcribe: @Sendable (ContiguousArray<Float>) -> String?
    private var onSegment: (@Sendable (UUID, MeetingSegment) -> Void)?
    private var pending = 0
    private var skipped = 0

    init(library: MeetingLibrary, transcribe: @escaping @Sendable (ContiguousArray<Float>) -> String?) {
        self.library = library
        self.transcribe = transcribe
    }

    /// Receives each saved segment on the worker's queue.
    func setSegmentHandler(_ handler: @escaping @Sendable (UUID, MeetingSegment) -> Void) {
        lock.withLock { onSegment = handler }
    }

    func reset() {
        lock.withLock {
            pending = 0
            skipped = 0
        }
    }

    var skippedCount: Int { lock.withLock { skipped } }

    func enqueue(track: MeetingTrack, start: TimeInterval, audio: ContiguousArray<Float>, meetingID: UUID) {
        let accepted = lock.withLock { () -> Bool in
            guard pending < Self.maximumPendingSegments else {
                skipped += 1
                return false
            }
            pending += 1
            return true
        }
        guard accepted else {
            logger.error("Meeting transcription is behind; skipped a segment")
            return
        }
        let duration = Double(audio.count) / Double(MeetingSegmenter.sampleRate)
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            guard let text = transcribe(audio)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return
            }
            let segment = MeetingSegment(track: track, start: start, end: start + duration, text: text)
            do {
                try library.appendSegment(segment, meeting: meetingID)
            } catch {
                logger.error("Could not save a meeting segment: \(String(describing: error), privacy: .public)")
            }
            let handler = lock.withLock { onSegment }
            handler?(meetingID, segment)
        }
    }

    /// Calls back once every segment queued so far has been handled.
    func drain(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }
}

// MARK: - Controller

struct MeetingOffer: Equatable, Identifiable {
    let bundleIdentifier: String
    let appName: String
    var id: String { bundleIdentifier }
}

/// Owns meeting recording: capture sources, transcription of finished
/// segments, call detection, and writing the finished transcript.
@MainActor
final class MeetingController: ObservableObject {
    struct Dependencies {
        /// Installs (or with nil removes) an observer of converted mic samples.
        var setMicrophoneObserver: (((UnsafeBufferPointer<Float>) -> Void)?) -> Void
        /// Transcribes one segment with corrections applied; nil when it
        /// held no speech. Called off the main thread.
        var transcribe: @Sendable (ContiguousArray<Float>) -> String?
        var notify: (UserFeedbackEvent) -> Void
        var clients: () -> Set<MicrophoneClient> = { MicrophoneClientMonitor.currentClients() }
        var hasScreenRecordingAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }
    }

    struct Recording: Equatable {
        let id: UUID
        let startedAt: Date
        let title: String
        let appBundleIdentifier: String?
        let capturesSystemAudio: Bool
    }

    static let liveSegmentLimit = 400

    @Published private(set) var recording: Recording?
    @Published private(set) var liveSegments: [MeetingSegment] = []
    @Published private(set) var offer: MeetingOffer?
    @Published private(set) var meetings: [MeetingManifest] = []
    @Published private(set) var isFinishing = false

    let library: MeetingLibrary
    private let dependencies: Dependencies
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "meetings")
    private let worker: MeetingTranscriptionWorker
    private var detector = MeetingDetector()
    private var detectionTimer: Timer?
    private var micPipeline: MeetingTrackPipeline?
    private var systemPipeline: MeetingTrackPipeline?
    private var systemCapture: AnyObject?
    private var manifest: MeetingManifest?
    private var offerTimeout: DispatchWorkItem?

    init(library: MeetingLibrary = MeetingLibrary(), dependencies: Dependencies) {
        self.library = library
        self.dependencies = dependencies
        worker = MeetingTranscriptionWorker(library: library, transcribe: dependencies.transcribe)
        worker.setSegmentHandler { [weak self] meetingID, segment in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.appendLive(segment, meetingID: meetingID) }
            }
        }
        library.recoverInterrupted(except: nil)
        applyRetention()
        reloadMeetings()
        updateDetection()
    }

    var isRecording: Bool { recording != nil }

    func reloadMeetings() {
        meetings = library.manifests()
    }

    // MARK: Recording

    func start(appBundleIdentifier: String? = nil, appName: String? = nil) {
        guard recording == nil, !isFinishing else { return }
        offer = nil
        let startedAt = Date()
        let title = Self.title(appName: appName, at: startedAt)
        let wantsSystemAudio = MeetingPreferences.capturesSystemAudio()
        var canCaptureSystem = false
        if #available(macOS 13.0, *) {
            canCaptureSystem = wantsSystemAudio && dependencies.hasScreenRecordingAccess()
        }
        let manifest = MeetingManifest(
            id: UUID(), title: title, startedAt: startedAt, appName: appName,
            state: .recording, capturedSystemAudio: canCaptureSystem
        )
        let folder: URL
        do {
            folder = try library.create(manifest)
        } catch {
            dependencies.notify(.error("Could not create the meeting folder"))
            return
        }

        let worker = worker
        let meetingID = manifest.id
        let onSegment: (MeetingTrack, TimeInterval, ContiguousArray<Float>) -> Void = { track, start, audio in
            worker.enqueue(track: track, start: start, audio: audio, meetingID: meetingID)
        }
        worker.reset()
        let mic = MeetingTrackPipeline(
            track: .you, meetingStart: startedAt,
            writer: ChunkedWAVWriter(directory: folder, prefix: MeetingTrack.you.rawValue),
            onSegment: onSegment
        )
        micPipeline = mic
        dependencies.setMicrophoneObserver { samples in mic.ingest(samples) }

        if canCaptureSystem, #available(macOS 13.0, *) {
            let system = MeetingTrackPipeline(
                track: .them, meetingStart: startedAt,
                writer: ChunkedWAVWriter(directory: folder, prefix: MeetingTrack.them.rawValue),
                onSegment: onSegment
            )
            systemPipeline = system
            let notify = dependencies.notify
            let capture = SystemAudioCapture(
                onSamples: { system.ingest($0) },
                onStop: { _ in
                    DispatchQueue.main.async {
                        notify(.error("System audio stopped; still recording your microphone"))
                    }
                }
            )
            systemCapture = capture
            Task { @MainActor [weak self] in
                do {
                    try await capture.start()
                } catch {
                    self?.logger.error("System audio unavailable: \(String(describing: error), privacy: .public)")
                    self?.dependencies.notify(.error("Recording your microphone only; system audio is unavailable"))
                    self?.markSystemAudioUnavailable()
                }
            }
        } else if wantsSystemAudio {
            dependencies.notify(.status("Recording your microphone only. Allow Screen Recording to include the other side."))
        }

        self.manifest = manifest
        liveSegments = []
        recording = Recording(
            id: manifest.id, startedAt: startedAt, title: title,
            appBundleIdentifier: appBundleIdentifier, capturesSystemAudio: canCaptureSystem
        )
        dependencies.notify(.status("Recording meeting"))
        reloadMeetings()
    }

    func stop() {
        guard recording != nil, let base = manifest else { return }
        recording = nil
        manifest = nil
        isFinishing = true
        dependencies.setMicrophoneObserver(nil)
        let capture = systemCapture
        systemCapture = nil
        let pipelines = [micPipeline, systemPipeline].compactMap { $0 }
        micPipeline = nil
        systemPipeline = nil
        let worker = worker
        dependencies.notify(.status("Finishing meeting transcript…"))

        Task { @MainActor [weak self] in
            if #available(macOS 13.0, *), let capture = capture as? SystemAudioCapture {
                await capture.stop()
            }
            var chunks: [String: [String]] = [:]
            for pipeline in pipelines {
                chunks[pipeline.track.rawValue] = await withCheckedContinuation { continuation in
                    pipeline.finish { continuation.resume(returning: $0) }
                }
            }
            // Segments flushed by the pipelines are queued before this runs.
            await withCheckedContinuation { continuation in
                worker.drain { continuation.resume() }
            }
            var finished = base
            finished.endedAt = Date()
            finished.audioChunks = chunks
            finished.state = .finished
            guard let self else { return }
            await self.writeTranscript(for: finished, skipped: worker.skippedCount)
            self.isFinishing = false
            self.applyRetention()
            self.reloadMeetings()
            self.updateDetection()
        }
    }

    private func appendLive(_ segment: MeetingSegment, meetingID: UUID) {
        guard recording?.id == meetingID else { return }
        liveSegments.append(segment)
        if liveSegments.count > Self.liveSegmentLimit {
            liveSegments.removeFirst(liveSegments.count - Self.liveSegmentLimit)
        }
    }

    private func markSystemAudioUnavailable() {
        guard var manifest else { return }
        manifest.capturedSystemAudio = false
        self.manifest = manifest
        try? library.save(manifest)
    }

    private func writeTranscript(for manifest: MeetingManifest, skipped: Int) async {
        let segments = MeetingEchoFilter.removingEchoes(library.segments(meeting: manifest.id))
        var notes = MeetingNotes.extract(from: segments)
        notes.summary = await MeetingSummarizer.summary(of: segments)
        var finished = manifest
        // A failed system-audio start is recorded on disk, not in `manifest`.
        if let saved = library.manifest(id: manifest.id) {
            finished.capturedSystemAudio = saved.capturedSystemAudio
        }
        if let summary = notes.summary, let title = MeetingSummarizer.title(from: summary) {
            finished.title = title
        }
        do {
            try library.save(finished)
            try library.writeTranscript(
                MeetingFormat.markdown(manifest: finished, segments: segments, notes: notes),
                meeting: manifest.id
            )
            let note = skipped > 0 ? " (\(skipped) segments skipped while busy)" : ""
            dependencies.notify(.status("Meeting transcript saved\(note)"))
        } catch {
            dependencies.notify(.error("Meeting transcript could not be saved"))
        }
    }

    // MARK: Library actions

    func deleteAudio(_ id: UUID) {
        try? library.deleteAudio(meeting: id)
        reloadMeetings()
    }

    func delete(_ id: UUID) {
        guard recording?.id != id else { return }
        try? library.delete(meeting: id)
        reloadMeetings()
    }

    func transcript(_ id: UUID) -> String {
        if let text = try? String(contentsOf: library.transcriptURL(meeting: id), encoding: .utf8) {
            return text
        }
        guard let manifest = library.manifest(id: id) else { return "" }
        let segments = MeetingEchoFilter.removingEchoes(library.segments(meeting: id))
        return MeetingFormat.markdown(manifest: manifest, segments: segments, notes: .extract(from: segments))
    }

    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: id)])
    }

    func applyRetention() {
        let expired = MeetingRetention.audioToDelete(
            library.manifests(), now: Date(), keepDays: MeetingPreferences.keepAudioDays()
        )
        for id in expired {
            try? library.deleteAudio(meeting: id)
        }
    }

    // MARK: Detection

    /// Starts or stops polling microphone users to match the preferences.
    func updateDetection() {
        let wanted = MeetingPreferences.isEnabled()
            && MeetingPreferences.detectsCalls()
            && MicrophoneClientMonitor.isSupported
        if wanted, detectionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollDetection() }
            }
            RunLoop.main.add(timer, forMode: .common)
            detectionTimer = timer
        } else if !wanted {
            detectionTimer?.invalidate()
            detectionTimer = nil
            offer = nil
        }
    }

    private func pollDetection() {
        let event = detector.observe(
            now: ProcessInfo.processInfo.systemUptime,
            clients: dependencies.clients(),
            isRecording: recording != nil || isFinishing,
            recordingApp: recording?.appBundleIdentifier
        )
        switch event {
        case .offer(let bundleIdentifier, let name):
            present(MeetingOffer(bundleIdentifier: bundleIdentifier, appName: name))
        case .ended:
            dependencies.notify(.status("Call ended; finishing the meeting"))
            stop()
        case nil:
            break
        }
    }

    private func present(_ offer: MeetingOffer) {
        self.offer = offer
        offerTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self?.offer == offer else { return }
                self?.offer = nil
            }
        }
        offerTimeout = timeout
        // An unanswered offer closes; it never starts a recording by itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func acceptOffer() {
        guard let offer else { return }
        start(appBundleIdentifier: offer.bundleIdentifier, appName: offer.appName)
    }

    func declineOffer() {
        guard let offer else { return }
        detector.snooze(offer.bundleIdentifier)
        self.offer = nil
    }

    private static func title(appName: String?, at date: Date) -> String {
        let time = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        return appName.map { "\($0) call · \(time)" } ?? "Meeting · \(time)"
    }
}
