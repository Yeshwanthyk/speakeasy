import CoreGraphics
import XCTest
@testable import Speakeasy

final class RecordingIndicatorTests: XCTestCase {
    func testNotchedGeometryExtendsAcrossNotchAndAddsSignalWing() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944),
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
            auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38)
        )

        XCTAssertEqual(geometry.style, .notchWings)
        XCTAssertEqual(geometry.panelFrame, CGRect(x: 614, y: 944, width: 284, height: 38))
        XCTAssertEqual(geometry.signalFrame, CGRect(x: 0, y: 0, width: 36, height: 38))
        XCTAssertEqual(geometry.bottomCornerRadius, 12)
    }

    func testNonNotchedGeometryUsesCompactCenteredPill() {
        let geometry = RecordingIndicatorGeometry.resolve(
            screenFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 875),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertEqual(geometry.style, .topPill)
        XCTAssertEqual(geometry.panelFrame, CGRect(x: -766, y: 870, width: 92, height: 30))
        XCTAssertEqual(geometry.signalFrame, CGRect(x: 0, y: 0, width: 92, height: 30))
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
