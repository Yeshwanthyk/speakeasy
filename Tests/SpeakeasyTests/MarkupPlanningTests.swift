import CoreGraphics
import XCTest
@testable import Speakeasy

final class MarkupPlanningTests: XCTestCase {
    // MARK: - Transcript cutting

    func testRangesCoverEverySampleWithOneSpanPerMarkPlusPreamble() {
        let samples = ContiguousArray<Float>(repeating: 0.1, count: 64_000)
        let ranges = MarkupTranscriptCutter.ranges(cuts: [16_000, 40_000], samples: samples)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(left.upperBound, right.lowerBound)
        }
    }

    func testCutSnapsToNearbySilence() {
        var samples = ContiguousArray<Float>(repeating: 0.2, count: 48_000)
        // A 100 ms pause 300 ms after the requested cut.
        for index in 20_800..<22_400 { samples[index] = 0 }
        let snapped = MarkupTranscriptCutter.snap(16_000 + 4_000, in: samples)
        XCTAssertTrue((20_800..<22_400).contains(snapped), "snapped to \(snapped)")
    }

    func testCutsBeyondTheRecordingAndOutOfOrderStayMonotonic() {
        let samples = ContiguousArray<Float>(repeating: 0.1, count: 8_000)
        let ranges = MarkupTranscriptCutter.ranges(cuts: [6_000, 2_000, 99_000], samples: samples)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertTrue(ranges.allSatisfy { $0.lowerBound <= $0.upperBound })
        XCTAssertEqual(ranges.last?.upperBound, 8_000)
    }

    func testEmptyRecordingStillProducesOneRangePerMark() {
        let ranges = MarkupTranscriptCutter.ranges(cuts: [10, 20], samples: [])
        XCTAssertEqual(ranges, [0..<0, 0..<0, 0..<0])
    }

    // MARK: - Cropping

    func testSmallMarkGetsPaddedToMinimumSizeInsideContainer() {
        let container = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let crop = MarkupCropPlanner.crop(mark: CGRect(x: 1_000, y: 600, width: 40, height: 20), container: container)

        XCTAssertGreaterThanOrEqual(crop.width, MarkupCropPlanner.minimumSize.width)
        XCTAssertGreaterThanOrEqual(crop.height, MarkupCropPlanner.minimumSize.height)
        XCTAssertTrue(container.contains(crop))
        XCTAssertTrue(crop.contains(CGRect(x: 1_000, y: 600, width: 40, height: 20)))
    }

    func testMarkNearEdgeSlidesInsteadOfShrinking() {
        let container = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let crop = MarkupCropPlanner.crop(mark: CGRect(x: 5, y: 5, width: 30, height: 30), container: container)
        XCTAssertEqual(crop.minX, 0)
        XCTAssertEqual(crop.minY, 0)
        XCTAssertGreaterThanOrEqual(crop.width, MarkupCropPlanner.minimumSize.width)
    }

    func testLargeMarkUsesWholeContainer() {
        let container = CGRect(x: 100, y: 100, width: 900, height: 600)
        let crop = MarkupCropPlanner.crop(mark: CGRect(x: 150, y: 150, width: 700, height: 400), container: container)
        XCTAssertEqual(crop, container)
    }

    // MARK: - Contact sheet

    func testLayoutUsesTwoColumnsAndFillsShortestFirst() {
        let layout = ContactSheetLayout.make(
            tileSizes: [CGSize(width: 960, height: 600), CGSize(width: 960, height: 200), CGSize(width: 960, height: 300)],
            spacing: 10
        )
        XCTAssertEqual(layout.frames.count, 3)
        XCTAssertEqual(layout.frames[0].minX, 10)
        XCTAssertEqual(layout.frames[1].minX, 980)
        // Third tile goes under the shorter second column.
        XCTAssertEqual(layout.frames[2].minX, 980)
        XCTAssertEqual(layout.frames[2].minY, 220)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1_950, height: 620))
    }

    func testLayoutScalesWideTilesDownButNeverUp() {
        let layout = ContactSheetLayout.make(
            tileSizes: [CGSize(width: 1_920, height: 1_080), CGSize(width: 400, height: 300)],
            maxColumnWidth: 960
        )
        XCTAssertEqual(layout.frames[0].size, CGSize(width: 960, height: 540))
        XCTAssertEqual(layout.frames[1].size, CGSize(width: 400, height: 300))
    }

    func testSingleTileUsesOneTightColumn() {
        let layout = ContactSheetLayout.make(tileSizes: [CGSize(width: 500, height: 400)], spacing: 8)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 516, height: 416))
    }

    func testEmptyLayout() {
        XCTAssertEqual(ContactSheetLayout.make(tileSizes: []).canvasSize, .zero)
    }

    // MARK: - Summary

    func testSummaryListsMarksWithTimesTargetsAndSpeech() {
        let text = MarkupSummary.text(
            bundlePath: "/tmp/markup-1",
            contactSheetPath: "/tmp/markup-1/contact-sheet.png",
            duration: 83,
            preamble: "Looking at the landing page.",
            items: [
                .init(number: 1, elapsed: 5.4, wasClick: false, targetName: "Safari", transcript: "We don't need this footer."),
                .init(number: 2, elapsed: 16, wasClick: true, targetName: nil, transcript: "")
            ],
            failedSegmentCount: 0
        )
        XCTAssertEqual(text, """
        [Speakeasy markup · 1:23 · 2 marks · /tmp/markup-1]
        Contact sheet: /tmp/markup-1/contact-sheet.png (numbered marks match the list below; full frames in frames/)
        "Looking at the landing page."
        - #1 (0:05) Safari: "We don't need this footer."
        - #2 (0:16) [clicked] (no speech)
        """)
    }

    func testSummaryNotesFailedSegments() {
        let text = MarkupSummary.text(
            bundlePath: "/b", contactSheetPath: nil, duration: 1, preamble: "", items: [], failedSegmentCount: 2
        )
        XCTAssertTrue(text.hasSuffix("Note: 2 speech segments could not be transcribed."))
    }

    func testAnnotationBoundsIncludeClickRadius() {
        let click = MarkupAnnotation(
            number: 1, kind: .click, sampleOffset: 0, elapsed: 0,
            displayFrame: .zero, strokes: [[CGPoint(x: 100, y: 100)]], target: nil
        )
        XCTAssertEqual(click.bounds.width, MarkupAnnotation.clickRadius * 2)
    }
}
