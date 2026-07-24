import XCTest
@testable import Speakeasy

final class PermissionsTests: XCTestCase {
    func testAccessibilitySettingsURLTargetsAccessibilityPrivacyPane() {
        XCTAssertEqual(
            Permissions.accessibilitySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
