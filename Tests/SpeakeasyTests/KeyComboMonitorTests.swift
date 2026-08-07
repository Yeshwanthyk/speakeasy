import Carbon
import CoreGraphics
import XCTest
@testable import Speakeasy

final class KeyComboMonitorTests: XCTestCase {
    func testCarbonModifiersMapsSupportedModifierFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

        XCTAssertEqual(
            KeyComboMonitor.carbonModifiers(from: flags),
            UInt32(cmdKey | controlKey | optionKey | shiftKey)
        )
    }

    func testCarbonModifiersIgnoresUnsupportedFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskSecondaryFn]

        XCTAssertEqual(KeyComboMonitor.carbonModifiers(from: flags), UInt32(cmdKey))
    }

    func testPushToTalkKeyStateIgnoresRepeatsAndDuplicateOrStaleKeyUps() {
        var state = PushToTalkKeyState()

        XCTAssertEqual(state.keyDown(isMatching: true, isRepeat: false), .pushToTalkBegan)
        XCTAssertNil(state.keyDown(isMatching: true, isRepeat: true))
        XCTAssertNil(state.keyDown(isMatching: true, isRepeat: false))
        XCTAssertEqual(state.keyUp(), .pushToTalkEnded)
        XCTAssertNil(state.keyUp())
    }

    func testPushToTalkKeyStateResetsStaleReleaseAcrossModeChanges() {
        var state = PushToTalkKeyState()

        XCTAssertEqual(state.keyDown(isMatching: true, isRepeat: false), .pushToTalkBegan)
        state.reset()

        XCTAssertNil(state.keyUp())
    }
}
