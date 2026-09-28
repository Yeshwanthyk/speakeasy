import Foundation
import XCTest
@testable import Speakeasy

final class OnlineSegmentCommitTests: XCTestCase {
    func testPauseAfterTwentySecondsCutsButShortGapDoesNot() {
        var cutter = OnlineSegmenter()
        for frame in 0..<1_100 {
            let quiet = (1_010..<1_020).contains(frame) || frame >= 1_050
            cutter.feed(offset: frame * 320, rms: quiet ? 0.0001 : 0.04)
        }
        XCTAssertEqual(cutter.nextCut, .init(start: 0, end: 1_050 * 320, overlapsPrevious: false))
    }

    func testForcedCutAtSixtySecondsAndOverlappingNextWindow() {
        var cutter = OnlineSegmenter()
        for frame in 0..<3_000 { cutter.feed(offset: frame * 320, rms: 0.04) }
        XCTAssertEqual(cutter.nextCut, .init(start: 0, end: 960_000, overlapsPrevious: false))
        cutter.acceptCut()
        for frame in 3_000..<5_900 { cutter.feed(offset: frame * 320, rms: 0.04) }
        XCTAssertEqual(cutter.nextCut, .init(start: 928_000, end: 1_888_000, overlapsPrevious: true))
    }

    func testPendingBackpressureAndCancelClearsQueue() {
        let fake = SlowSegmentTranscriber()
        let pipeline = OnlineSegmentCommit(transcriber: fake, filter: HallucinationFilter(), runID: { 17 })
        let samples = Self.speech(seconds: 20)
        let first = OnlineSegmenter.Cut(start: 0, end: samples.count, overlapsPrevious: false)
        XCTAssertTrue(pipeline.enqueue(first, samples: samples))
        XCTAssertEqual(fake.started.wait(timeout: .now() + 2), .success)
        let second = OnlineSegmenter.Cut(start: samples.count, end: samples.count * 2, overlapsPrevious: false)
        XCTAssertTrue(pipeline.enqueue(second, samples: samples))
        let third = OnlineSegmenter.Cut(start: samples.count * 2, end: samples.count * 3, overlapsPrevious: false)
        XCTAssertTrue(pipeline.enqueue(third, samples: samples))
        XCTAssertTrue(pipeline.enqueue(.init(start: samples.count * 3, end: samples.count * 4, overlapsPrevious: false), samples: samples))
        XCTAssertFalse(pipeline.enqueue(.init(start: samples.count * 4, end: samples.count * 5, overlapsPrevious: false), samples: samples))
        pipeline.cancel()
        fake.release.signal()
        XCTAssertEqual(fake.cancelled, [17])
        XCTAssertEqual(pipeline.committedText, "")
        XCTAssertThrowsError(try pipeline.finish(tail: [], tailStart: 0, finalRunID: 18, isCancelled: { false }))
    }

    func testStopWaitsForInflightAndPrioritizesTailOverPending() throws {
        let fake = SlowSegmentTranscriber()
        let pipeline = OnlineSegmentCommit(transcriber: fake, filter: HallucinationFilter(), runID: { 21 })
        let samples = Self.speech(seconds: 20)
        XCTAssertTrue(pipeline.enqueue(.init(start: 0, end: samples.count, overlapsPrevious: false), samples: samples))
        XCTAssertEqual(fake.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(pipeline.enqueue(.init(start: samples.count, end: samples.count * 2, overlapsPrevious: false), samples: samples))
        let done = expectation(description: "finished")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            let result = try? pipeline.finish(tail: samples, tailStart: samples.count * 2, finalRunID: 22, isCancelled: { false })
            XCTAssertEqual(result?.text, "one pending tail")
            XCTAssertEqual(result?.count, 2)
            XCTAssertEqual(result?.committedSeconds, 40)
            XCTAssertEqual(result?.tailSeconds, 20)
        }
        Thread.sleep(forTimeInterval: 0.05)
        fake.release.signal()
        wait(for: [done], timeout: 4)
        XCTAssertEqual(fake.calls, [21, 22, 21])
    }

    func testForcedOverlapJoinsWithoutRepeatedWords() {
        XCTAssertEqual(FinalTranscription.merge("The quick brown fox", "brown fox jumps"), "The quick brown fox jumps")
    }

    func testSegmentMetricsReachJSONLRecord() throws {
        var trace = TranscriptionTrace()
        trace.segmentCount = 3
        trace.committedAudioSeconds = 118
        trace.tailSeconds = 4.5
        trace.segmentWaitMs = 23
        let record = try XCTUnwrap(E2ETraceRecordFactory.record(from: trace, outcome: .noSpeech, deliveredText: nil))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertTrue(json.contains("\"segment_count\":3"))
        XCTAssertTrue(json.contains("\"committed_audio_seconds\":118"))
        XCTAssertTrue(json.contains("\"tail_seconds\":4.5"))
        XCTAssertTrue(json.contains("\"segment_wait_ms\":23"))
    }

    private static func speech(seconds: Int) -> ContiguousArray<Float> {
        var samples = ContiguousArray<Float>(repeating: 0, count: seconds * 16_000)
        for i in samples.indices where i / 1_600 % 2 == 0 {
            samples[i] = i % 16 < 8 ? 0.04 : -0.04
        }
        return samples
    }
}

private final class SlowSegmentTranscriber: Transcriber, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCalls: [UInt64] = []
    private var storedCancelled: [UInt64] = []
    var calls: [UInt64] { lock.lock(); defer { lock.unlock() }; return storedCalls }
    var cancelled: [UInt64] { lock.lock(); defer { lock.unlock() }; return storedCancelled }
    func transcribe(samples: ContiguousArray<Float>) throws -> String { "unused" }
    func transcribe(samples: ContiguousArray<Float>, runID: UInt64) throws -> String {
        lock.lock(); storedCalls.append(runID); let index = storedCalls.count; lock.unlock()
        if index == 1 { started.signal(); _ = release.wait(timeout: .now() + 4) }
        return ["one", "tail", "pending"][min(index - 1, 2)]
    }
    func cancel(runID: UInt64) { lock.lock(); storedCancelled.append(runID); lock.unlock() }
    func warmUp(runID: UInt64) throws {}
}
