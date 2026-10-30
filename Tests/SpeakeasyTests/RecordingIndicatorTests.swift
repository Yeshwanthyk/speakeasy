import CoreGraphics
import XCTest
@testable import Speakeasy

final class RecordingIndicatorTests: XCTestCase {
    private func notched(placement: OverlayStyle = .top) -> RecordingIndicatorGeometry {
        RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
            auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38),
            placement: placement
        )
    }

    func testNotchIslandGrowsFromTheNotchWithSignalInTheWings() {
        let geometry = notched()

        XCTAssertEqual(geometry.style, .notch)
        XCTAssertTrue(geometry.isTopAttached)
        XCTAssertEqual(geometry.panelFrame, CGRect(x: 584, y: 908, width: 344, height: 74))
        // Tucked: exactly the 212 x 38 notch, centred on it.
        XCTAssertEqual(geometry.collapsed.capsule, CGRect(x: 66, y: 36, width: 212, height: 38))
        // Open: one 30 pt wing each side, no taller than the notch.
        XCTAssertEqual(geometry.compact.capsule, CGRect(x: 36, y: 36, width: 272, height: 38))
        XCTAssertEqual(geometry.expanded.capsule, CGRect(x: 12, y: 12, width: 320, height: 62))
        XCTAssertEqual(geometry.compact.capsule.maxY, geometry.panelFrame.height)

        let notch = geometry.collapsed.capsule
        XCTAssertEqual(geometry.compact.dotCenter, CGPoint(x: 51, y: 55))
        XCTAssertLessThan(geometry.compact.dotCenter.x, notch.minX)
        XCTAssertGreaterThan(geometry.compact.barsFrame.minX, notch.maxX)
        XCTAssertLessThan(geometry.compact.barsFrame.maxX, geometry.compact.capsule.maxX)
        // The text row sits under the notch, inside the expanded shape.
        XCTAssertLessThan(geometry.expanded.textFrame.maxY, notch.minY)
        XCTAssertTrue(geometry.expanded.capsule.contains(geometry.expanded.textFrame))
    }

    func testNotchCentresOnTheNotchOnASecondaryDisplay() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 1_000, y: 200, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 1_000, y: 200, width: 1_512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 1_000, y: 1_144, width: 650, height: 38),
            auxiliaryTopRightArea: CGRect(x: 1_862, y: 1_144, width: 650, height: 38)
        )
        XCTAssertEqual(geometry.style, .notch)
        XCTAssertEqual(geometry.panelFrame.midX, 1_756)
        XCTAssertEqual(geometry.panelFrame.maxY, 1_182)
    }

    func testFlatDisplayPlacesASmallPlateInsideTheMenuBar() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 875),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertEqual(geometry.style, .topPill)
        XCTAssertFalse(geometry.isTopAttached)
        XCTAssertEqual(geometry.panelFrame, CGRect(x: -892, y: 866, width: 344, height: 34))
        XCTAssertEqual(geometry.compact.capsule, CGRect(x: 145, y: 12, width: 54, height: 19))
        XCTAssertEqual(geometry.compact.cornerRadius, 9.5)
        // 3 pt clear of the screen's top, inside the 25 pt menu bar.
        XCTAssertEqual(geometry.panelFrame.minY + geometry.compact.capsule.maxY, 897)
        XCTAssertGreaterThanOrEqual(geometry.panelFrame.minY + geometry.compact.capsule.minY, 875)
    }

    func testHiddenMenuBarFallsBackToAPretendBar() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        XCTAssertEqual(geometry.style, .topPill)
        XCTAssertEqual(geometry.compact.capsule.height, 18)
        XCTAssertEqual(geometry.panelFrame.minY + geometry.compact.capsule.maxY, 897)
    }

    func testBottomPlacementSitsAboveTheDockEvenOnANotchedDisplay() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 805),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            placement: .bottom
        )
        XCTAssertEqual(geometry.style, .bottomPill)
        XCTAssertEqual(geometry.panelFrame, CGRect(x: 548, y: 72, width: 344, height: 50))
        XCTAssertEqual(geometry.panelFrame.minY + geometry.compact.capsule.minY, 84)
        XCTAssertEqual(notched(placement: .bottom).style, .bottomPill)
    }

    func testPillLayoutsKeepContentInsideAndOnlyExpandWithText() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 805),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            placement: .bottom
        )
        let compact = geometry.compact
        XCTAssertTrue(compact.capsule.contains(compact.barsFrame))
        XCTAssertTrue(compact.capsule.contains(compact.dotCenter))
        XCTAssertEqual(geometry.collapsed.dotCenter, compact.dotCenter)
        XCTAssertEqual(geometry.collapsed.capsule.width, geometry.collapsed.capsule.height)

        let expanded = geometry.expanded
        XCTAssertEqual(expanded.capsule, CGRect(x: 12, y: 12, width: 320, height: 26))
        XCTAssertTrue(expanded.capsule.contains(expanded.textFrame))
        XCTAssertGreaterThan(expanded.textFrame.minX, expanded.barsFrame.maxX)
        XCTAssertTrue(CGRect(origin: .zero, size: geometry.panelFrame.size).contains(expanded.capsule))
    }

    func testScreenSelectionPrefersTheFocusedWindowThenThePointer() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        ]
        let window = RecordingIndicatorScreenSelection.appKitRect(
            fromWindowBounds: CGRect(x: 1_500, y: 100, width: 800, height: 600),
            primaryScreenHeight: 900
        )
        XCTAssertEqual(window, CGRect(x: 1_500, y: 200, width: 800, height: 600))
        XCTAssertEqual(
            RecordingIndicatorScreenSelection.screenIndex(
                screenFrames: screens,
                windowFrame: window,
                mouseLocation: CGPoint(x: 100, y: 100)
            ),
            1
        )
        // A window straddling both screens goes to the one with more of it.
        XCTAssertEqual(
            RecordingIndicatorScreenSelection.screenIndex(
                screenFrames: screens,
                windowFrame: CGRect(x: 1_000, y: 100, width: 600, height: 400),
                mouseLocation: CGPoint(x: 2_000, y: 100)
            ),
            0
        )
        XCTAssertEqual(
            RecordingIndicatorScreenSelection.screenIndex(
                screenFrames: screens,
                windowFrame: nil,
                mouseLocation: CGPoint(x: 720, y: 900)
            ),
            0
        )
        XCTAssertNil(
            RecordingIndicatorScreenSelection.screenIndex(
                screenFrames: screens,
                windowFrame: CGRect(x: -5_000, y: 0, width: 10, height: 10),
                mouseLocation: CGPoint(x: -9_000, y: 0)
            )
        )
    }

    func testLevelNormalizerSuppressesSilenceAndBoundsSpeechLevels() {
        var normalizer = LiveAudioLevelNormalizer()

        XCTAssertEqual(normalizer.normalizedLevel(forRMS: 0), 0)
        XCTAssertEqual(normalizer.normalizedLevel(forRMS: .nan), 0)

        let quietSpeech = normalizer.normalizedLevel(forRMS: 0.004)
        XCTAssertGreaterThan(quietSpeech, 0)
        XCTAssertLessThanOrEqual(quietSpeech, 1)

        for rms in stride(from: Float(0), through: 1, by: 0.025) {
            let level = normalizer.normalizedLevel(forRMS: rms)
            XCTAssertTrue(level.isFinite)
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }
}
