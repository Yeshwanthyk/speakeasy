import Carbon
import CoreGraphics
import XCTest
@testable import Wisp

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
}
