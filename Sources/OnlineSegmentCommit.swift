import Accelerate
import Foundation

/// Pure offset-based cutter. Feed consecutive 20 ms frame energies; the caller
/// retains ownership of PCM and advances the cursor only after enqueue succeeds.
struct OnlineSegmenter {
    static let sampleRate = 16_000
    static let frameSamples = 320
    static let minimumSamples = 20 * sampleRate
    static let maximumSamples = 60 * sampleRate
    static let silenceFrames = 15

    struct Cut: Equatable {
        let start: Int
        let end: Int
        let overlapsPrevious: Bool
    }

    private(set) var committedEnd = 0
    private var scanOffset = 0
    private var quietStart: Int?
    private var quietFrames = 0
    private var proposed: Cut?
    private var floor: Float = 0.002

    mutating func feed(offset: Int, rms: Float) {
        guard offset == scanOffset else { return }
        scanOffset += Self.frameSamples
        // Track a slowly rising ambient floor, but adapt quickly downward.
        floor = min(max(floor * 0.999, rms * 0.25), max(0.002, rms))
        if rms < max(0.002, floor * 2) {
            if quietFrames == 0 { quietStart = offset }
            quietFrames += 1
        } else {
            quietFrames = 0
            quietStart = nil
        }
        guard proposed == nil else { return }
        if quietFrames >= Self.silenceFrames,
           let quietStart, quietStart - committedEnd >= Self.minimumSamples {
            proposed = Cut(start: committedEnd, end: quietStart, overlapsPrevious: false)
        } else if scanOffset - committedEnd >= Self.maximumSamples - (committedEnd == 0 ? 0 : FinalTranscription.overlapSamples) {
            proposed = Cut(start: max(0, committedEnd - (committedEnd == 0 ? 0 : FinalTranscription.overlapSamples)),
                           end: committedEnd + Self.maximumSamples - (committedEnd == 0 ? 0 : FinalTranscription.overlapSamples), overlapsPrevious: committedEnd != 0)
        }
    }

    var nextCut: Cut? { proposed }

    mutating func acceptCut() {
        guard let proposed else { return }
        committedEnd = proposed.end
        self.proposed = nil
        quietFrames = 0
        quietStart = nil
        // Keep scanning at the current position; if backpressure delayed a cut,
        // subsequent frames can force another cut on the next polling cycle.
        if scanOffset - committedEnd >= Self.maximumSamples - FinalTranscription.overlapSamples {
            self.proposed = Cut(start: max(0, committedEnd - FinalTranscription.overlapSamples),
                                end: committedEnd + Self.maximumSamples - FinalTranscription.overlapSamples, overlapsPrevious: true)
        }
    }
}


/// A single worker serializes committed inference. A pending PCM buffer may be
/// extended only up to one native window; when full, capture keeps the rest.
final class OnlineSegmentCommit: @unchecked Sendable {
    private struct Segment {
        var start: Int
        var end: Int
        var samples: ContiguousArray<Float>
        var overlapsPrevious: Bool
    }
    private let lock = NSCondition()
    private let worker = DispatchQueue(label: "com.speakeasy.app.segment-commit", qos: .userInitiated)
    private let transcriber: Transcriber
    private let runID: () -> UInt64
    private let filter: HallucinationFilter
    private var pending: Segment?
    private var activeRunID: UInt64?
    private var results: [(Int, String, Bool)] = []
    private var stopped = false
    private var cancelled = false
    private var failure: Error?
    private var storedCommittedEnd = 0
    var committedEnd: Int {
        lock.lock(); defer { lock.unlock() }
        return storedCommittedEnd
    }
    private var committedCount = 0
    private var lastCutForced = false

    init(transcriber: Transcriber, filter: HallucinationFilter, runID: @escaping () -> UInt64) {
        self.transcriber = transcriber
        self.filter = filter
        self.runID = runID
    }

    func enqueue(_ cut: OnlineSegmenter.Cut, samples: ContiguousArray<Float>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !stopped, cut.end > storedCommittedEnd,
              samples.count == cut.end - cut.start else { return false }
        if var pending {
            // Overlapping forced cuts retain only the existing prefix once.
            let extraStart = max(pending.end, cut.start)
            let extra = cut.end - extraStart
            guard pending.samples.count + extra <= FinalTranscription.windowSamples else { return false }
            pending.samples.append(contentsOf: samples.suffix(extra))
            pending.end = cut.end
            self.pending = pending
        } else {
            pending = Segment(start: cut.start, end: cut.end, samples: samples,
                              overlapsPrevious: cut.overlapsPrevious)
            if activeRunID == nil { worker.async { self.drain() } }
        }
        storedCommittedEnd = cut.end
        committedCount += 1
        lastCutForced = cut.overlapsPrevious || cut.end - cut.start == FinalTranscription.windowSamples
        return true
    }

    var canAcceptCut: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !stopped && pending == nil
    }

    var hasWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil || activeRunID != nil
    }


    var tailOverlapSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return lastCutForced ? FinalTranscription.overlapSamples : 0
    }

    var committedText: String {
        lock.lock(); defer { lock.unlock() }
        return results.sorted { $0.0 < $1.0 }.reduce("") { text, part in
            part.2 ? FinalTranscription.merge(text, part.1) : [text, part.1].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func drain() {
        while true {
            let id = runID()
            lock.lock()
            guard !cancelled, !stopped, let segment = pending else {
                activeRunID = nil
                lock.broadcast(); lock.unlock(); return
            }
            pending = nil
            activeRunID = id
            lock.unlock()
            do {
                if SpeechGate.analyze(segment.samples).hasSpeech {
                    let (text, _) = try transcriber.transcribeWithTimings(samples: segment.samples, runID: id)
                    let rms = Self.rms(segment.samples)
                    let accepted = filter.verdict(for: text, activeDurationSeconds: Double(segment.samples.count) / 16_000,
                                                  activeRMS: rms)
                    lock.lock()
                    if !cancelled, case .accepted = accepted {
                        results.append((segment.start, text, segment.overlapsPrevious))
                    }
                    lock.unlock()
                }
            } catch {
                lock.lock(); if !cancelled { failure = error }; lock.unlock()
            }
            lock.lock()
            activeRunID = nil
            lock.broadcast()
            lock.unlock()
        }
    }

    func beginStopping() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Stop gives the tail priority over any queued commit. Caller is off-main.
    func finish(tail: ContiguousArray<Float>, tailStart: Int, finalRunID: UInt64,
                isCancelled: () -> Bool) throws -> (text: String, count: Int, committedSeconds: Double, tailSeconds: Double, waitMs: Double, tailTimings: NativeASRTimings?) {
        let start = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        stopped = true
        while activeRunID != nil { lock.wait() }
        let waitMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let queued = pending
        pending = nil
        let prior = results
        let end = storedCommittedEnd
        let count = committedCount
        let error = failure
        let wasCancelled = cancelled
        activeRunID = finalRunID
        lock.unlock()
        defer {
            lock.lock()
            activeRunID = nil
            lock.broadcast()
            lock.unlock()
        }
        if wasCancelled || isCancelled() { throw CancellationError() }
        if let error { throw error }
        // The native session is free now: tail first, then the outstanding commit.
        let tailText: String
        let tailTimings: NativeASRTimings?
        if !tail.isEmpty && SpeechGate.analyze(tail).hasSpeech {
            (tailText, tailTimings) = try FinalTranscription.run(samples: tail, transcriber: transcriber, runID: finalRunID, isCancelled: isCancelled)
        } else { (tailText, tailTimings) = ("", nil) }
        var parts = prior
        if let queued, SpeechGate.analyze(queued.samples).hasSpeech {
            if isCancelled() { throw CancellationError() }
            let queuedRunID = runID()
            lock.lock()
            activeRunID = queuedRunID
            lock.unlock()
            let text = try transcriber.transcribe(samples: queued.samples, runID: queuedRunID)
            if case .accepted = filter.verdict(for: text,
                                               activeDurationSeconds: Double(queued.samples.count) / 16_000,
                                               activeRMS: Self.rms(queued.samples)) {
                parts.append((queued.start, text, queued.overlapsPrevious))
            }
        }
        parts.sort { $0.0 < $1.0 }
        var joined = ""
        for (_, text, overlap) in parts {
            joined = overlap ? FinalTranscription.merge(joined, text)
                : [joined, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
        joined = tailStart < end ? FinalTranscription.merge(joined, tailText)
            : [joined, tailText].filter { !$0.isEmpty }.joined(separator: " ")
        return (joined, count, Double(end) / 16_000, Double(tail.count) / 16_000, waitMs, tailTimings)
    }

    func cancel(excluding runID: UInt64? = nil) {
        lock.lock()
        cancelled = true
        pending = nil
        results.removeAll()
        let id = activeRunID
        lock.broadcast()
        lock.unlock()
        if let id, id != runID { transcriber.cancel(runID: id) }
    }

    private static func rms(_ samples: ContiguousArray<Float>) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard !buffer.isEmpty else { return 0 }
            return vDSP.meanSquare(buffer).squareRoot()
        }
    }
}
