import XCTest
@testable import Speakeasy

final class TranscriptPostProcessorTests: XCTestCase {
    func testCommandsFormatPunctuationAndLineBreaks() {
        let processor = TranscriptPostProcessor()

        let result = processor.process(
            "hello comma world new paragraph left parenthesis next question mark right parenthesis"
        )

        XCTAssertEqual(result.rawText, "hello comma world new paragraph left parenthesis next question mark right parenthesis")
        XCTAssertEqual(result.finalText, "hello, world\n\n(next?)")
    }

    func testCommandsWinBeforePersonalCorrections() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "question mark", written: "the words question mark")
        ])

        XCTAssertEqual(processor.process("Is this question mark").finalText, "Is this?")
    }

    func testCorrectionsAreCaseAndDiacriticInsensitive() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "café", written: "coffee shop")
        ])

        XCTAssertEqual(processor.process("Meet me at CAFE").finalText, "Meet me at coffee shop")
    }

    func testLongestWholePhraseWins() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "project", written: "workstream"),
            TranscriptCorrection(heard: "project status", written: "workstream update")
        ])

        XCTAssertEqual(processor.process("project status today").finalText, "workstream update today")
        XCTAssertEqual(processor.process("projector status").finalText, "projector status")
    }

    func testReplacementOutputIsNotRecursivelyCorrected() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "alpha", written: "beta"),
            TranscriptCorrection(heard: "beta", written: "gamma")
        ])

        XCTAssertEqual(processor.process("alpha").finalText, "beta")
    }

    func testDuplicateNormalizedHeardValuesAreRejected() {
        XCTAssertThrowsError(try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "Resume", written: "one"),
            TranscriptCorrection(heard: "résumé", written: "two")
        ])) { error in
            XCTAssertEqual(error as? TranscriptPostProcessorError, .duplicateHeard(index: 1, duplicateOf: 0))
        }
    }

    func testBoundsRejectOversizedConfigurations() {
        let tooMany = (0...TranscriptPostProcessor.maxEnabledCorrections).map { index in
            TranscriptCorrection(heard: "heard \(index)", written: "written")
        }
        XCTAssertThrowsError(try TranscriptPostProcessor(corrections: tooMany))

        XCTAssertThrowsError(try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: String(repeating: "h", count: 129), written: "written")
        ]))
        XCTAssertThrowsError(try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "heard", written: String(repeating: "w", count: 129))
        ]))
    }

    func testMaximumCorrectionSetHasBoundedRuntime() throws {
        let corrections = (0..<TranscriptPostProcessor.maxEnabledCorrections).map { index in
            TranscriptCorrection(heard: "heard phrase \(index)", written: "written \(index)")
        }
        let processor = try TranscriptPostProcessor(corrections: corrections)
        let input = (0..<64).map { "heard phrase \($0)" }.joined(separator: " ")

        measure {
            for _ in 0..<100 {
                _ = processor.process(input).finalText
            }
        }
    }
}
