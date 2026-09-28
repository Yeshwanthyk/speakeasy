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

    // MARK: - State machine
    //
    // clean --edit--> dirty --save--> saving --true--> clean
    //                   ^                 |--false/throw--> dirty + error
    //                   |--invalid save--> dirty + error (saver not called)
    // reload returns any state (except saving) to clean with no error.

    func testCleanModelCannotSaveAndDoesNotCallSaver() async {
        var saveCallCount = 0
        let model = CorrectionEditorModel(
            loadCorrections: { [TranscriptCorrection(heard: "a", written: "b")] },
            saveCorrections: { _ in
                saveCallCount += 1
                return true
            }
        )

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canSave)
        let didSave = await model.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(saveCallCount, 0)
    }

    func testRejectedPersistenceKeepsChangesAndExplains() async {
        let model = CorrectionEditorModel(loadCorrections: { [] }, saveCorrections: { _ in false })
        model.corrections = [TranscriptCorrection(heard: "a", written: "b")]

        let didSave = await model.save()

        XCTAssertFalse(didSave)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(
            model.errorMessage,
            "Corrections could not be saved. Your previous corrections are still active."
        )
    }

    func testThrowingSaverKeepsChangesAndExplains() async {
        struct Failure: Error {}
        let model = CorrectionEditorModel(loadCorrections: { [] }, saveCorrections: { _ in throw Failure() })
        model.corrections = [TranscriptCorrection(heard: "a", written: "b")]

        let didSave = await model.save()

        XCTAssertFalse(didSave)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNotNil(model.errorMessage)
    }

    func testEditsAreLockedWhileSavingAndReentrantSaveIsRejected() async {
        var release: CheckedContinuation<Bool, Never>?
        let model = CorrectionEditorModel(
            loadCorrections: { [] },
            saveCorrections: { _ in
                await withCheckedContinuation { release = $0 }
            }
        )
        model.corrections = [TranscriptCorrection(heard: "a", written: "b")]
        let id = model.corrections[0].id

        let firstSave = Task { await model.save() }
        while release == nil {
            await Task.yield()
        }

        XCTAssertTrue(model.isSaving)
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canAddCorrection)
        model.addCorrection()
        model.removeCorrection(id: id)
        XCTAssertEqual(model.corrections.map(\.id), [id])
        let reentrantSave = await model.save()
        XCTAssertFalse(reentrantSave)

        release?.resume(returning: true)
        let didSave = await firstSave.value
        XCTAssertTrue(didSave)
        XCTAssertFalse(model.isSaving)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testReloadDiscardsEditsAndClearsErrors() async {
        let stored = [TranscriptCorrection(heard: "a", written: "b")]
        let model = CorrectionEditorModel(loadCorrections: { stored }, saveCorrections: { _ in true })
        model.corrections.append(TranscriptCorrection(heard: "a", written: "c"))
        _ = await model.save()
        XCTAssertNotNil(model.errorMessage)

        model.reload()

        XCTAssertEqual(model.corrections, stored)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.errorMessage)
    }

    func testRemovingTheOnlyAddedRowReturnsToClean() {
        let model = CorrectionEditorModel(loadCorrections: { [] }, saveCorrections: { _ in true })

        model.addCorrection()
        XCTAssertTrue(model.hasUnsavedChanges)
        model.removeCorrection(id: model.corrections[0].id)

        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testValidationMessagesNameTheOffendingRow() async {
        let cases: [([TranscriptCorrection], String)] = [
            (
                [TranscriptCorrection(heard: "ok", written: "a"), TranscriptCorrection(heard: " ", written: "b")],
                "Enter what Speakeasy hears for correction 2."
            ),
            (
                [TranscriptCorrection(heard: String(repeating: "h", count: 129), written: "a")],
                "The heard phrase in correction 1 is too long."
            ),
            (
                [TranscriptCorrection(heard: "h", written: String(repeating: "w", count: 129))],
                "The replacement in correction 1 is too long."
            ),
        ]
        for (corrections, message) in cases {
            let model = CorrectionEditorModel(loadCorrections: { [] }, saveCorrections: { _ in true })
            model.corrections = corrections
            let didSave = await model.save()
            XCTAssertFalse(didSave)
            XCTAssertEqual(model.errorMessage, message)
        }
    }
}
