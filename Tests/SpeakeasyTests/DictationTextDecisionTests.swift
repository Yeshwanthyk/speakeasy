import XCTest
@testable import Speakeasy

final class DictationTextDecisionTests: XCTestCase {
    private let filter = HallucinationFilter()

    func testBlankTextIsEmpty() {
        XCTAssertEqual(evaluate("  \n\t "), .empty)
    }

    func testFilterRejectionCarriesItsReason() {
        XCTAssertEqual(
            evaluate("bye", activeDurationSeconds: 0.8, activeRMS: 0.001),
            .hallucination(.exactPattern)
        )
    }

    func testAcceptedTextIsTrimmedAndCorrected() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "kudo", written: "CUDA")
        ])

        XCTAssertEqual(
            evaluate("  kudo question mark \n", postProcessor: processor),
            .accepted(
                ProcessedTranscript(
                    rawText: "kudo question mark",
                    finalText: "CUDA?",
                    stageChanges: [
                        StageChange(stage: "commands", count: 1),
                        StageChange(stage: "exactCorrections", count: 1)
                    ]
                )
            )
        )
    }

    func testTextThatCorrectsToWhitespaceIsEmpty() {
        XCTAssertEqual(evaluate("new line"), .empty)
    }

    func testDecisionMatchesTheFilterAndProcessorItComposes() throws {
        let processor = try TranscriptPostProcessor(corrections: [
            TranscriptCorrection(heard: "speak easy", written: "Speakeasy")
        ])
        let text = "open speak easy settings"

        guard case .accepted(let transcript) = evaluate(text, postProcessor: processor) else {
            return XCTFail("expected accepted text")
        }
        XCTAssertEqual(filter.verdict(for: text), .accepted)
        XCTAssertEqual(transcript, processor.process(text))
    }

    private func evaluate(
        _ text: String,
        postProcessor: TranscriptPostProcessor = TranscriptPostProcessor(),
        activeDurationSeconds: TimeInterval? = 2,
        activeRMS: Float? = 0.05
    ) -> DictationTextDecision {
        DictationTextDecision.evaluate(
            text,
            filter: filter,
            postProcessor: postProcessor,
            activeDurationSeconds: activeDurationSeconds,
            activeRMS: activeRMS
        )
    }
}
