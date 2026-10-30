import XCTest
@testable import Speakeasy

final class MeetingCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = testScratchDirectory.appendingPathComponent("meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Chunked WAV writer

    func testWriterRotatesChunksAndKeepsEverySample() throws {
        let writer = ChunkedWAVWriter(directory: directory, prefix: "you", chunkSeconds: 0.01) // 160 samples
        let samples = (0..<400).map { Float($0 % 50) / 50 - 0.5 }
        try writer.append(Array(samples[0..<250]))
        try writer.append(Array(samples[250...]))
        try writer.finish()

        XCTAssertEqual(writer.chunkNames, ["you-0001.wav", "you-0002.wav", "you-0003.wav"])
        XCTAssertEqual(writer.totalSamples, 400)
        let decoded = try writer.chunkNames.flatMap { try Self.readWAV(directory.appendingPathComponent($0)) }
        XCTAssertEqual(decoded.count, 400)
        for (original, roundTripped) in zip(samples, decoded) {
            XCTAssertEqual(original, roundTripped, accuracy: 1.0 / 16_000)
        }
    }

    func testOpenChunkHeaderIsValidBeforeFinish() throws {
        // A crash before finish() must still leave a readable file.
        let writer = ChunkedWAVWriter(directory: directory, prefix: "them")
        try writer.append([Float](repeating: 0.25, count: 1_000))

        let samples = try Self.readWAV(directory.appendingPathComponent("them-0001.wav"))
        XCTAssertEqual(samples.count, 1_000)
    }

    func testWriterClampsNonFiniteAndOutOfRangeSamples() throws {
        let writer = ChunkedWAVWriter(directory: directory, prefix: "x")
        try writer.append([.nan, .infinity, 2, -2])
        try writer.finish()

        let samples = try Self.readWAV(directory.appendingPathComponent("x-0001.wav"))
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0)
        XCTAssertEqual(samples[2], 1, accuracy: 0.001)
        XCTAssertEqual(samples[3], -1, accuracy: 0.001)
    }

    func testHourLongStreamUsesBoundedChunkCount() {
        // 16 kHz × 3600 s in 5-minute chunks → 12 files, regardless of length.
        let chunkSamples = Int(ChunkedWAVWriter.defaultChunkSeconds * 16_000)
        XCTAssertEqual((16_000 * 3_600 + chunkSamples - 1) / chunkSamples, 12)
    }

    // MARK: - Segmenter

    func testSegmenterCutsAtAPauseAfterTheMinimumLength() {
        var segmenter = MeetingSegmenter()
        var cuts: [Range<Int>] = []
        for _ in 0..<200 { if let cut = segmenter.feed(rms: 0.1) { cuts.append(cut) } } // 4 s speech
        for _ in 0..<30 { if let cut = segmenter.feed(rms: 0.0005) { cuts.append(cut) } } // 600 ms pause

        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts.first?.lowerBound, 0)
        XCTAssertEqual(cuts.first?.upperBound, (200 + MeetingSegmenter.pauseFrames) * MeetingSegmenter.frameSamples)
    }

    func testSegmenterForcesACutAtTheMaximumLength() {
        var segmenter = MeetingSegmenter()
        var cuts: [Range<Int>] = []
        for _ in 0..<(MeetingSegmenter.maximumSamples / MeetingSegmenter.frameSamples + 10) {
            if let cut = segmenter.feed(rms: 0.1) { cuts.append(cut) }
        }
        XCTAssertEqual(cuts.first?.count, MeetingSegmenter.maximumSamples)
    }

    func testSilentStretchesAreSkippedNotTranscribed() {
        var segmenter = MeetingSegmenter()
        var cuts: [Range<Int>] = []
        for _ in 0..<(MeetingSegmenter.maximumSamples / MeetingSegmenter.frameSamples * 3) {
            if let cut = segmenter.feed(rms: 0) { cuts.append(cut) }
        }
        XCTAssertEqual(cuts, [])
        XCTAssertEqual(segmenter.segmentStart, MeetingSegmenter.maximumSamples * 3)
    }

    func testFinishFlushesTheTail() {
        var segmenter = MeetingSegmenter()
        for _ in 0..<50 { _ = segmenter.feed(rms: 0.1) }
        XCTAssertEqual(segmenter.finish(), 0..<(50 * MeetingSegmenter.frameSamples))
        XCTAssertNil(segmenter.finish())
    }

    func testSampleWindowReturnsRangesAndTrims() {
        var window = MeetingSampleWindow()
        [Float](repeating: 1, count: 100).withUnsafeBufferPointer { window.append($0) }
        [Float](repeating: 2, count: 100).withUnsafeBufferPointer { window.append($0) }

        let first = window.take(50..<150)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(first.first, 1)
        XCTAssertEqual(first.last, 2)
        XCTAssertEqual(window.startOffset, 150)
        XCTAssertEqual(window.samples.count, 50)
        XCTAssertEqual(window.take(0..<10).count, 0, "already-discarded audio is gone")
    }

    // MARK: - Echo filter

    func testMicSegmentRepeatingTheOtherSideIsDropped() {
        let them = MeetingSegment(track: .them, start: 10, end: 14, text: "Can everyone see my screen right now?")
        let echo = MeetingSegment(track: .you, start: 10.4, end: 14.2, text: "everyone see my screen right now")
        let reply = MeetingSegment(track: .you, start: 15, end: 16, text: "Yes, looks good to me.")

        XCTAssertEqual(MeetingEchoFilter.removingEchoes([them, echo, reply]), [them, reply])
    }

    func testSimilarWordsFarApartInTimeAreKept() {
        let them = MeetingSegment(track: .them, start: 0, end: 3, text: "let's ship the release")
        let later = MeetingSegment(track: .you, start: 60, end: 63, text: "let's ship the release")

        XCTAssertEqual(MeetingEchoFilter.removingEchoes([them, later]).count, 2)
    }

    func testMicrophoneOnlyMeetingsKeepEverything() {
        let segments = [MeetingSegment(track: .you, start: 0, end: 1, text: "hello")]
        XCTAssertEqual(MeetingEchoFilter.removingEchoes(segments), segments)
    }

    // MARK: - Notes and Markdown

    func testNotesFindActionItemsAndTalkTime() {
        let notes = MeetingNotes.extract(from: [
            MeetingSegment(track: .you, start: 0, end: 30, text: "Thanks for joining. I'll send the deck by Friday."),
            MeetingSegment(track: .them, start: 30, end: 40, text: "Great. Can you also share the numbers? The weather is nice.")
        ])

        XCTAssertEqual(notes.talkTime[.you], 30)
        XCTAssertEqual(notes.talkTime[.them], 10)
        XCTAssertEqual(notes.actionItems.map(\.text), ["I'll send the deck by Friday.", "Can you also share the numbers?"])
        XCTAssertEqual(notes.actionItems.map(\.track), [.you, .them])
    }

    func testTurnsJoinCloseSegmentsFromTheSameSpeaker() {
        let turns = MeetingFormat.turns([
            MeetingSegment(track: .you, start: 0, end: 4, text: "First part"),
            MeetingSegment(track: .you, start: 5, end: 8, text: "second part."),
            MeetingSegment(track: .them, start: 9, end: 10, text: "Reply."),
            MeetingSegment(track: .you, start: 20, end: 21, text: "Later.")
        ])

        XCTAssertEqual(turns.map(\.text), ["First part second part.", "Reply.", "Later."])
    }

    func testMarkdownListsNotesThenTranscript() {
        let manifest = MeetingManifest(
            id: UUID(), title: "Design review", startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3_725), appName: "Zoom", state: .finished,
            capturedSystemAudio: true
        )
        let segments = [MeetingSegment(track: .them, start: 65, end: 70, text: "We should cut scope.")]
        let markdown = MeetingFormat.markdown(manifest: manifest, segments: segments, notes: .extract(from: segments))

        XCTAssertTrue(markdown.hasPrefix("# Design review\n"))
        XCTAssertTrue(markdown.contains("1:02:05"))
        XCTAssertTrue(markdown.contains("Zoom"))
        XCTAssertTrue(markdown.contains("- [Them 1:05] We should cut scope."))
        XCTAssertTrue(markdown.contains("**Them** (1:05): We should cut scope."))
        XCTAssertLessThan(
            markdown.range(of: "## Notes")?.lowerBound ?? markdown.endIndex,
            markdown.range(of: "## Transcript")?.lowerBound ?? markdown.startIndex
        )
    }

    // MARK: - Retention

    func testRetentionDeletesOnlyOldFinishedAudio() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func meeting(daysAgo: Double, state: MeetingManifest.State = .finished, audio: Bool = true) -> MeetingManifest {
            let ended = now.addingTimeInterval(-daysAgo * 86_400)
            return MeetingManifest(
                id: UUID(), title: "m", startedAt: ended.addingTimeInterval(-60), endedAt: ended,
                state: state, audioChunks: audio ? ["you": ["you-0001.wav"]] : [:]
            )
        }
        let old = meeting(daysAgo: 40)
        let recent = meeting(daysAgo: 5)
        let live = meeting(daysAgo: 40, state: .recording)
        let noAudio = meeting(daysAgo: 40, audio: false)

        XCTAssertEqual(MeetingRetention.audioToDelete([old, recent, live, noAudio], now: now, keepDays: 30), [old.id])
        XCTAssertEqual(MeetingRetention.audioToDelete([old], now: now, keepDays: nil), [])
    }

    // MARK: - Library

    func testLibraryRoundTripsManifestsAndSegmentsAndToleratesATornLine() throws {
        let library = MeetingLibrary(root: directory)
        let manifest = MeetingManifest(
            id: UUID(), title: "Sync", startedAt: Date(timeIntervalSince1970: 1_000), state: .recording
        )
        let folder = try library.create(manifest)
        let segment = MeetingSegment(track: .you, start: 1, end: 2, text: "hello")
        try library.appendSegment(segment, meeting: manifest.id)
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(MeetingLibrary.segmentsName))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"track\":\"them\",\"sta".utf8))
        try handle.close()

        XCTAssertEqual(library.manifests().map(\.id), [manifest.id])
        XCTAssertEqual(library.segments(meeting: manifest.id), [segment])

        try Data().write(to: folder.appendingPathComponent("you-0002.wav"))
        try Data().write(to: folder.appendingPathComponent("you-0001.wav"))
        library.recoverInterrupted(except: nil)
        let recovered = library.manifest(id: manifest.id)
        XCTAssertEqual(recovered?.state, .interrupted)
        XCTAssertEqual(recovered?.endedAt, Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(recovered?.chunks(for: .you), ["you-0001.wav", "you-0002.wav"])
        let transcript = try String(contentsOf: library.transcriptURL(meeting: manifest.id), encoding: .utf8)
        XCTAssertTrue(transcript.contains("**You** (0:01): hello"))
    }

    func testLibraryDeletesAudioButKeepsTheTranscript() throws {
        let library = MeetingLibrary(root: directory)
        var manifest = MeetingManifest(id: UUID(), title: "m", startedAt: Date(), state: .finished)
        let folder = try library.create(manifest)
        let audio = folder.appendingPathComponent("you-0001.wav")
        try Data([1, 2, 3]).write(to: audio)
        manifest.audioChunks = ["you": ["you-0001.wav"]]
        try library.save(manifest)
        try library.writeTranscript("# m\n", meeting: manifest.id)

        try library.deleteAudio(meeting: manifest.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.transcriptURL(meeting: manifest.id).path))
        XCTAssertEqual(library.manifest(id: manifest.id)?.audioDeleted, true)
        XCTAssertEqual(library.manifest(id: manifest.id)?.hasAudio, false)
    }

    func testFutureSchemaManifestsAreSkipped() throws {
        let library = MeetingLibrary(root: directory)
        var manifest = MeetingManifest(id: UUID(), title: "m", startedAt: Date(), state: .finished)
        manifest.schemaVersion = MeetingManifest.currentSchemaVersion + 1
        _ = try library.create(manifest)

        XCTAssertEqual(library.manifests(), [])
    }

    // MARK: - Helpers

    private static func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        let declared = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(declared), data.count - 44, "header data size matches the file")
        return stride(from: 44, to: data.count, by: 2).map { offset in
            let value = data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self).littleEndian }
            return Float(value) / Float(Int16.max)
        }
    }
}

final class MeetingSummarizerTests: XCTestCase {
    func testPromptLabelsSpeakersAndKeepsBothEndsOfLongMeetings() {
        let segments = (0..<2_000).map {
            MeetingSegment(track: $0.isMultiple(of: 2) ? .you : .them, start: Double($0) * 10, end: Double($0) * 10 + 5, text: "line \($0)")
        }
        let prompt = MeetingSummarizer.prompt(for: segments)

        XCTAssertTrue(prompt.hasPrefix("You: line 0"))
        XCTAssertTrue(prompt.contains("[…]"))
        XCTAssertTrue(prompt.hasSuffix("line 1999"))
        XCTAssertLessThanOrEqual(prompt.count, MeetingSummarizer.maximumTranscriptCharacters + 10)
    }

    func testTitleIsTheFirstLineWithoutMarkup() {
        XCTAssertEqual(MeetingSummarizer.title(from: "**Title: Q3 planning**\n- Ship it"), "Q3 planning")
        XCTAssertEqual(MeetingSummarizer.title(from: "# Hiring sync\n- one"), "Hiring sync")
        XCTAssertNil(MeetingSummarizer.title(from: String(repeating: "long ", count: 40)))
        XCTAssertNil(MeetingSummarizer.title(from: ""))
    }
}
