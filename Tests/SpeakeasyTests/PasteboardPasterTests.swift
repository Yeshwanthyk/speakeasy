import XCTest
@testable import Speakeasy

final class PasteboardPasterTests: XCTestCase {
    func testCopyReportsClipboardWriteFailure() {
        let paster = PasteboardPaster(writeClipboard: { _ in false })

        XCTAssertEqual(paster.copy("text"), .clipboardWriteFailed)
    }

    func testCopyReportsClipboardUpdated() {
        let paster = PasteboardPaster(writeClipboard: { _ in true })

        XCTAssertEqual(paster.copy("text"), .clipboardUpdated)
    }

    func testPasteStopsAtClipboardWriteFailure() {
        var posted = false
        let paster = PasteboardPaster(
            writeClipboard: { _ in false },
            postPasteEvents: {
                posted = true
                return true
            }
        )

        XCTAssertEqual(paster.paste("text"), .clipboardWriteFailed)
        XCTAssertFalse(posted)
    }

    func testPasteReportsClipboardUpdatedWhenEventsCannotBePosted() {
        let paster = PasteboardPaster(
            writeClipboard: { _ in true },
            postPasteEvents: { false }
        )

        XCTAssertEqual(paster.paste("text"), .clipboardUpdated)
    }

    func testPasteReportsEventsPostedOnlyAfterBothBoundariesSucceed() {
        let paster = PasteboardPaster(
            writeClipboard: { _ in true },
            postPasteEvents: { true }
        )

        XCTAssertEqual(paster.paste("text"), .eventsPosted)
    }

    func testPasteRestoresEverySnapshotRepresentationAfterEventsPost() {
        let access = FakePasteboardAccess(
            snapshot: PasteboardSnapshot(items: [
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentationSnapshot(type: "public.utf8-plain-text", data: Data("old".utf8)),
                    PasteboardRepresentationSnapshot(type: "com.example.custom", data: Data([1, 2, 3]))
                ]),
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentationSnapshot(type: "public.png", data: Data([4, 5]))
                ])
            ])
        )
        let target = TestDeliveryTargetProvider(target: .external(Self.application))
        let paster = PasteboardPaster(
            pasteboard: access,
            targetProvider: target,
            settleDelay: 0,
            createPasteEvents: { PasteEvents {} }
        )

        XCTAssertEqual(
            paster.paste("new", target: .external(Self.application)),
            .eventsPosted
        )
        XCTAssertTrue(waitUntil { access.restoredSnapshot != nil })
        XCTAssertEqual(access.restoredSnapshot, access.initialSnapshot)
    }

    func testPasteSkipsRestoreWhenClipboardChangesAfterEvents() {
        let access = FakePasteboardAccess(
            snapshot: PasteboardSnapshot(items: [
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentationSnapshot(type: "public.utf8-plain-text", data: Data("old".utf8))
                ])
            ])
        )
        let target = TestDeliveryTargetProvider(target: .external(Self.application))
        let paster = PasteboardPaster(
            pasteboard: access,
            targetProvider: target,
            settleDelay: 0,
            createPasteEvents: {
                PasteEvents { access.externalChange() }
            }
        )

        XCTAssertEqual(
            paster.paste("new", target: .external(Self.application)),
            .eventsPosted
        )
        XCTAssertTrue(waitUntil { access.changeCountReadCount >= 2 })
        XCTAssertEqual(access.restoreAttemptCount, 0)
        XCTAssertNil(access.restoredSnapshot)
    }

    func testPasteConstructsBothEventsBeforePostingEither() {
        let access = FakePasteboardAccess(snapshot: PasteboardSnapshot(items: []))
        let target = TestDeliveryTargetProvider(target: .external(Self.application))
        var phases: [String] = []
        let paster = PasteboardPaster(
            pasteboard: access,
            targetProvider: target,
            settleDelay: 0,
            createPasteEvents: {
                phases.append("keyDown created")
                phases.append("keyUp created")
                return PasteEvents {
                    phases.append("keyDown posted")
                    phases.append("keyUp posted")
                }
            }
        )

        XCTAssertEqual(
            paster.paste("text", target: .external(Self.application)),
            .eventsPosted
        )
        XCTAssertEqual(
            phases,
            ["keyDown created", "keyUp created", "keyDown posted", "keyUp posted"]
        )
    }

    func testPasteFallsBackToClipboardWhenTargetIsUnavailable() {
        let access = FakePasteboardAccess(snapshot: PasteboardSnapshot(items: []))
        var posted = false
        let paster = PasteboardPaster(
            pasteboard: access,
            targetProvider: TestDeliveryTargetProvider(target: .unavailable),
            createPasteEvents: { posted = true; return PasteEvents {} }
        )

        XCTAssertEqual(paster.paste("text", target: .unavailable), .clipboardUpdated)
        XCTAssertEqual(access.writtenString, "text")
        XCTAssertFalse(posted)
    }

    func testPasteFallsBackWhenTargetChangesOrTerminates() {
        let cases: [(TranscriptDeliveryTarget, TestDeliveryTargetProvider)] = [
            (.external(Self.application), TestDeliveryTargetProvider(
                target: .external(Self.otherApplication),
                running: true
            )),
            (.external(Self.application), TestDeliveryTargetProvider(
                target: .external(Self.application),
                running: false
            )),
            (.unsupported, TestDeliveryTargetProvider(target: .unsupported))
        ]

        for (requestedTarget, provider) in cases {
            let access = FakePasteboardAccess(snapshot: PasteboardSnapshot(items: []))
            var posted = false
            let paster = PasteboardPaster(
                pasteboard: access,
                targetProvider: provider,
                createPasteEvents: { posted = true; return PasteEvents {} }
            )

            XCTAssertEqual(
                paster.paste("text", target: requestedTarget),
                .clipboardUpdated
            )
            XCTAssertFalse(posted)
        }
    }

    func testPasteRejectsWriteThatCannotBeVerified() {
        let access = FakePasteboardAccess(
            snapshot: PasteboardSnapshot(items: []),
            verifiedString: "different"
        )
        let paster = PasteboardPaster(pasteboard: access)

        XCTAssertEqual(
            paster.paste("text", target: .unavailable),
            .clipboardWriteFailed
        )
        XCTAssertEqual(access.restoredSnapshot, access.initialSnapshot)
        XCTAssertEqual(access.restoreAttemptCount, 1)
    }

    private static let application = TranscriptDeliveryApplication(
        processIdentifier: 101,
        bundleIdentifier: "com.example.editor"
    )
    private static let otherApplication = TranscriptDeliveryApplication(
        processIdentifier: 202,
        bundleIdentifier: "com.example.other-editor"
    )

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class FakePasteboardAccess: PasteboardAccess {
    let initialSnapshot: PasteboardSnapshot
    private(set) var restoredSnapshot: PasteboardSnapshot?
    private(set) var writtenString: String?
    private(set) var restoreAttemptCount = 0
    private(set) var changeCountReadCount = 0
    private var currentChangeCount = 10
    private let verifiedString: String?

    init(snapshot: PasteboardSnapshot, verifiedString: String? = nil) {
        self.initialSnapshot = snapshot
        self.verifiedString = verifiedString
    }

    var changeCount: Int {
        changeCountReadCount += 1
        return currentChangeCount
    }

    func snapshot() -> PasteboardSnapshot? { initialSnapshot }

    func write(string: String) -> Bool {
        writtenString = string
        currentChangeCount += 1
        return true
    }

    func string() -> String? {
        verifiedString ?? writtenString
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        restoreAttemptCount += 1
        guard changeCount == 11 else { return false }
        restoredSnapshot = snapshot
        currentChangeCount += 1
        return true
    }

    func externalChange() {
        currentChangeCount += 1
    }
}

private struct TestDeliveryTargetProvider: DeliveryTargetProviding {
    var target: TranscriptDeliveryTarget
    var running = true

    func currentTarget() -> TranscriptDeliveryTarget { target }

    func isRunning(_ application: TranscriptDeliveryApplication) -> Bool { running }
}
