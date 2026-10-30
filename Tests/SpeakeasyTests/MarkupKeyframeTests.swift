import CoreGraphics
import XCTest
@testable import Speakeasy

final class MarkupKeyframeTests: XCTestCase {
    // MARK: - Summary instructions

    func testSummaryTellsTheAgentToOpenTheContactSheet() {
        let text = MarkupSummary.text(
            bundlePath: "/tmp/markup-1",
            contactSheetPath: "/tmp/markup-1/contact-sheet.png",
            duration: 12,
            preamble: "",
            items: [MarkupSummary.Item(number: 1, elapsed: 3, wasClick: false, targetName: "Safari", transcript: "this")],
            failedSegmentCount: 0
        )

        XCTAssertTrue(text.contains(MarkupSummary.openImagesInstruction), text)
    }

    func testSummaryOmitsTheInstructionWithoutAContactSheet() {
        let text = MarkupSummary.text(
            bundlePath: "/tmp/markup-1",
            contactSheetPath: nil,
            duration: 12,
            preamble: "",
            items: [],
            failedSegmentCount: 0
        )

        XCTAssertFalse(text.contains(MarkupSummary.openImagesInstruction))
    }

    func testSummaryNamesTheElementUnderTheMark() {
        let text = MarkupSummary.text(
            bundlePath: "/b",
            contactSheetPath: nil,
            duration: 5,
            preamble: "",
            items: [MarkupSummary.Item(
                number: 1, elapsed: 1, wasClick: true, targetName: "Safari",
                elementLabel: "“Save” button", transcript: "make this blue"
            )],
            failedSegmentCount: 0
        )

        XCTAssertTrue(text.contains("- #1 (0:01) [pin] Safari, over “Save” button: \"make this blue\""), text)
    }

    // MARK: - Element labels

    func testElementLabelUsesTitleAndReadableRole() {
        XCTAssertEqual(MarkupElementDescriber.describe(role: "AXButton", title: "Save", description: nil, value: nil), "“Save” button")
        XCTAssertEqual(MarkupElementDescriber.describe(role: "AXLink", title: nil, description: "Pricing", value: nil), "“Pricing” link")
        XCTAssertEqual(MarkupElementDescriber.describe(role: "AXStaticText", title: nil, description: nil, value: "Total: $42"), "“Total: $42” text")
    }

    func testElementLabelTruncatesLongText() {
        let long = String(repeating: "word ", count: 40)
        let label = MarkupElementDescriber.describe(role: "AXTextArea", title: nil, description: nil, value: long)
        XCTAssertNotNil(label)
        XCTAssertLessThanOrEqual(label?.count ?? 0, MarkupElementDescriber.maximumTextLength + 20)
        XCTAssertTrue(label?.contains("…") ?? false)
    }

    func testElementLabelSkipsUnnamedContainers() {
        XCTAssertNil(MarkupElementDescriber.describe(role: "AXGroup", title: nil, description: nil, value: nil))
        XCTAssertNil(MarkupElementDescriber.describe(role: "AXScrollArea", title: "", description: " ", value: nil))
        XCTAssertNil(MarkupElementDescriber.describe(role: nil, title: nil, description: nil, value: nil))
    }

    func testSecureFieldValuesAreNeverDescribed() {
        XCTAssertEqual(
            MarkupElementDescriber.describe(role: "AXTextField", subrole: "AXSecureTextField", title: nil, description: nil, value: "hunter2"),
            "password field"
        )
    }

    // MARK: - Shared stills

    func testIdenticalImagesHaveZeroDifference() throws {
        let image = try XCTUnwrap(Self.image(gray: 0.5))
        let a = try XCTUnwrap(LumaSignature(image: image))
        let b = try XCTUnwrap(LumaSignature(image: image))
        XCTAssertEqual(a.difference(to: b), 0, accuracy: 0.0001)
    }

    func testBlackAndWhiteImagesDifferCompletely() throws {
        let black = try XCTUnwrap(LumaSignature(image: XCTUnwrap(Self.image(gray: 0))))
        let white = try XCTUnwrap(LumaSignature(image: XCTUnwrap(Self.image(gray: 1))))
        XCTAssertGreaterThan(black.difference(to: white), 0.9)
    }

    func testConsecutiveMarksOnAnUnchangedScreenShareOneFrame() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let same = LumaSignature(cells: Array(repeating: 0.5, count: LumaSignature.cellCount))
        let changed = LumaSignature(cells: Array(repeating: 0.1, count: LumaSignature.cellCount))

        let groups = MarkupFrameGrouper.groups([
            .init(displayFrame: display, signature: same),
            .init(displayFrame: display, signature: same),
            .init(displayFrame: display, signature: changed),
            .init(displayFrame: CGRect(x: 1000, y: 0, width: 800, height: 600), signature: changed),
            .init(displayFrame: display, signature: nil)
        ])

        XCTAssertEqual(groups, [[0, 1], [2], [3], [4]])
    }

    func testMarksWithoutStillsNeverMerge() {
        let display = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(
            MarkupFrameGrouper.groups([.init(displayFrame: display, signature: nil), .init(displayFrame: display, signature: nil)]),
            [[0], [1]]
        )
    }

    // MARK: - Tile cap

    func testContactSheetIsCappedButKeepsTheFirstAndLastGroups() {
        let groups = (0..<30).map { [$0] }
        let kept = MarkupFrameGrouper.capped(groups)

        XCTAssertEqual(kept.count, MarkupFrameGrouper.maximumTiles)
        XCTAssertEqual(kept.first, [0])
        XCTAssertEqual(kept.last, [29])
        XCTAssertEqual(kept, kept.sorted { $0[0] < $1[0] })
    }

    func testSmallSheetsAreNotCapped() {
        let groups = [[0, 1], [2]]
        XCTAssertEqual(MarkupFrameGrouper.capped(groups), groups)
    }

    private static func image(gray: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        return context.makeImage()
    }
}
