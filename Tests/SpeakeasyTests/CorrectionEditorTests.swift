import XCTest
@testable import Speakeasy

@MainActor
final class CorrectionEditorTests: XCTestCase {
    func testEditorAddsAndSavesAValidatedCorrection() async {
        var saved: [TranscriptCorrection] = []
        let model = CorrectionEditorModel(
            loadCorrections: { [] },
            saveCorrections: { corrections in
                saved = corrections
                return true
            }
        )

        model.addCorrection()
        model.corrections[0].heard = "whisp"
        model.corrections[0].written = "Wisp"

        XCTAssertTrue(model.hasUnsavedChanges)
        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(saved.map(\.written), ["Wisp"])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.errorMessage)
    }

    func testEditorKeepsChangesAndExplainsDuplicatePhrases() async {
        var saveCallCount = 0
        let model = CorrectionEditorModel(
            loadCorrections: { [] },
            saveCorrections: { _ in
                saveCallCount += 1
                return true
            }
        )
        model.corrections = [
            TranscriptCorrection(heard: "Resume", written: "first"),
            TranscriptCorrection(heard: "résumé", written: "second")
        ]

        let didSave = await model.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(saveCallCount, 0)
        XCTAssertEqual(model.errorMessage, "Correction 2 duplicates correction 1.")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testEditorEnforcesTheDocumentLimitBeforeAdding() {
        let corrections = (0..<TranscriptPostProcessor.maxCorrections).map { index in
            TranscriptCorrection(heard: "heard \(index)", written: "written \(index)")
        }
        let model = CorrectionEditorModel(
            loadCorrections: { corrections },
            saveCorrections: { _ in true }
        )

        model.addCorrection()

        XCTAssertEqual(model.corrections.count, TranscriptPostProcessor.maxCorrections)
        XCTAssertFalse(model.canAddCorrection)
    }
}
