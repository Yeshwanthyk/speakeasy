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

        XCTAssertEqual(state.press(mode: .toggle), FunctionKeyPress())
        XCTAssertEqual(state.release(mode: .toggle), .toggle)

        XCTAssertEqual(state.press(mode: .toggle), FunctionKeyPress())
        XCTAssertNil(state.markUsedAsModifier())
        XCTAssertNil(state.release(mode: .toggle))
    }

    func testFunctionKeyHoldBeginsAndEndsPushToTalk() {
        var state = FunctionKeyGestureState()
        let generation = state.press(mode: .pushToTalk).pushToTalkGeneration

        guard let generation else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertTrue(state.beginPushToTalk(generation: generation))
        XCTAssertEqual(state.release(mode: .pushToTalk), .pushToTalkEnded)
    }

    func testFunctionKeyShortPressDoesNotStartPushToTalk() {
        var state = FunctionKeyGestureState()
        let generation = state.press(mode: .pushToTalk).pushToTalkGeneration

        XCTAssertNil(state.release(mode: .pushToTalk))
        guard let generation else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertFalse(state.beginPushToTalk(generation: generation))
    }

    func testFunctionKeyCombinationCancelsStartedPushToTalk() {
        var state = FunctionKeyGestureState()
        guard let generation = state.press(mode: .pushToTalk).pushToTalkGeneration else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertTrue(state.beginPushToTalk(generation: generation))

        XCTAssertEqual(state.markUsedAsModifier(), .cancel)
        XCTAssertNil(state.release(mode: .pushToTalk))
    }

    func testDoubleTapLatchesHandsFreeDictationInPushToTalk() {
        var state = FunctionKeyGestureState()

        _ = state.press(mode: .pushToTalk, now: 0)
        XCTAssertNil(state.release(mode: .pushToTalk, now: 0.08))
        let second = state.press(mode: .pushToTalk, now: 0.25)

        XCTAssertEqual(second, FunctionKeyPress(pushToTalkGeneration: nil, intent: .toggle))
        XCTAssertTrue(state.isLatched)
        XCTAssertNil(state.release(mode: .pushToTalk, now: 0.3), "the latching release must not stop dictation")
    }

    func testNextPressStopsLatchedDictation() {
        var state = FunctionKeyGestureState()
        _ = state.press(mode: .pushToTalk, now: 0)
        _ = state.release(mode: .pushToTalk, now: 0.05)
        _ = state.press(mode: .pushToTalk, now: 0.2)
        _ = state.release(mode: .pushToTalk, now: 0.25)

        let stop = state.press(mode: .pushToTalk, now: 5)

        XCTAssertEqual(stop, FunctionKeyPress(pushToTalkGeneration: nil, intent: .pushToTalkEnded))
        XCTAssertFalse(state.isLatched)
        XCTAssertNil(state.release(mode: .pushToTalk, now: 5.1))
    }

    func testSlowSecondTapDoesNotLatch() {
        var state = FunctionKeyGestureState()
        _ = state.press(mode: .pushToTalk, now: 0)
        _ = state.release(mode: .pushToTalk, now: 0.05)

        let second = state.press(mode: .pushToTalk, now: 0.05 + FunctionKeyGestureState.doubleTapWindow + 0.01)

        XCTAssertNil(second.intent)
        XCTAssertNotNil(second.pushToTalkGeneration)
        XCTAssertFalse(state.isLatched)
    }

    func testHoldThenTapDoesNotLatch() {
        var state = FunctionKeyGestureState()
        guard let generation = state.press(mode: .pushToTalk, now: 0).pushToTalkGeneration else {
            return XCTFail("Expected a push-to-talk generation")
        }
        XCTAssertTrue(state.beginPushToTalk(generation: generation))
        XCTAssertEqual(state.release(mode: .pushToTalk, now: 1), .pushToTalkEnded)

        XCTAssertNil(state.press(mode: .pushToTalk, now: 1.1).intent)
    }

    func testModifierChordBetweenTapsDoesNotLatch() {
        var state = FunctionKeyGestureState()
        _ = state.press(mode: .pushToTalk, now: 0)
        _ = state.markUsedAsModifier()
        _ = state.release(mode: .pushToTalk, now: 0.05)

        XCTAssertNil(state.press(mode: .pushToTalk, now: 0.2).intent)
    }

    func testDoubleTapLockCanBeDisabled() {
        var state = FunctionKeyGestureState()
        state.doubleTapLockEnabled = false
        _ = state.press(mode: .pushToTalk, now: 0)
        _ = state.release(mode: .pushToTalk, now: 0.05)

        XCTAssertNil(state.press(mode: .pushToTalk, now: 0.2).intent)
    }

    func testClearingTheLatchForgetsAPendingStop() {
        var state = FunctionKeyGestureState()
        _ = state.press(mode: .pushToTalk, now: 0)
        _ = state.release(mode: .pushToTalk, now: 0.05)
        _ = state.press(mode: .pushToTalk, now: 0.2)
        _ = state.release(mode: .pushToTalk, now: 0.25)

        state.clearLatch()

        XCTAssertFalse(state.isLatched)
        XCTAssertNil(state.press(mode: .pushToTalk, now: 3).intent)
    }

    func testToggleModeIgnoresDoubleTapTiming() {
        var state = FunctionKeyGestureState()
        _ = state.press(mode: .toggle, now: 0)
        XCTAssertEqual(state.release(mode: .toggle, now: 0.05), .toggle)
        XCTAssertNil(state.press(mode: .toggle, now: 0.1).intent)
        XCTAssertEqual(state.release(mode: .toggle, now: 0.15), .toggle)
    }

    func testChordBreakerPostsOnePressOfAnInertKeyUnderTheHeldFlags() {
        let specs = FunctionChordBreaker.eventSpecs(flags: .maskSecondaryFn)

        XCTAssertEqual(specs.map(\.keyCode), [0x44, 0x44])
        XCTAssertEqual(specs.map(\.keyDown), [true, false])
        XCTAssertTrue(specs.allSatisfy { $0.flags == .maskSecondaryFn })
    }

    func testChordBreakerDropsOnlyItsOwnMarkedEvents() {
        XCTAssertTrue(FunctionChordBreaker.isOwnEvent(userData: FunctionChordBreaker.marker, keyCode: 0x44))
        XCTAssertFalse(FunctionChordBreaker.isOwnEvent(userData: 0, keyCode: 0x44))
        XCTAssertFalse(FunctionChordBreaker.isOwnEvent(userData: FunctionChordBreaker.marker, keyCode: 9))
    }

    func testDoubleTapLockPreferenceDefaultsOn() {
        let suite = testDefaultsSuiteName("DoubleTapLock")
        defer { removeTestDefaults(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No defaults suite") }

        XCTAssertTrue(DoubleTapLockPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: DoubleTapLockPreference.key)
        XCTAssertFalse(DoubleTapLockPreference.isEnabled(defaults: defaults))
    }
}
