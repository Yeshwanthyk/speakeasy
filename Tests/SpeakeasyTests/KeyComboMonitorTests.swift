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

    func testFunctionKeyTapTogglesOnlyWhenUsedAlone() {
        var state = FunctionKeyGestureState()

        XCTAssertNil(state.press(mode: .toggle))
        XCTAssertEqual(state.release(mode: .toggle), .toggle)

        XCTAssertNil(state.press(mode: .toggle))
        XCTAssertNil(state.markUsedAsModifier())
        XCTAssertNil(state.release(mode: .toggle))
    }

    func testFunctionKeyHoldBeginsAndEndsPushToTalk() {
        var state = FunctionKeyGestureState()
        let generation = state.press(mode: .pushToTalk)

        guard let generation else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertTrue(state.beginPushToTalk(generation: generation))
        XCTAssertEqual(state.release(mode: .pushToTalk), .pushToTalkEnded)
    }

    func testFunctionKeyShortPressDoesNotStartPushToTalk() {
        var state = FunctionKeyGestureState()
        let generation = state.press(mode: .pushToTalk)

        XCTAssertNil(state.release(mode: .pushToTalk))
        guard let generation else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertFalse(state.beginPushToTalk(generation: generation))
    }

    func testFunctionKeyCombinationCancelsStartedPushToTalk() {
        var state = FunctionKeyGestureState()
        guard let generation = state.press(mode: .pushToTalk) else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertTrue(state.beginPushToTalk(generation: generation))

        XCTAssertEqual(state.markUsedAsModifier(), .cancel)
        XCTAssertNil(state.release(mode: .pushToTalk))
    }
}
