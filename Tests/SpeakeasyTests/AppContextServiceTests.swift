import Foundation
import XCTest

@testable import Speakeasy

final class AppContextServiceTests: XCTestCase {
    func testSecureRoleOrSubroleSuppressesContentHelpers() {
        XCTAssertTrue(
            AppContextBounds.isSecure(
                role: AppContextBounds.secureTextFieldMarker,
                subrole: "AXStandardTextField"
            )
        )
        XCTAssertTrue(
            AppContextBounds.isSecure(
                role: "AXTextField",
                subrole: AppContextBounds.secureTextFieldMarker
            )
        )
        XCTAssertNil(
            AppContextBounds.selectedText(
                "password",
                role: "AXTextField",
                subrole: AppContextBounds.secureTextFieldMarker
            )
        )
        XCTAssertNil(
            AppContextBounds.textBeforeCaret(
                in: "password",
                selectedRange: CFRange(location: 8, length: 0),
                role: AppContextBounds.secureTextFieldMarker,
                subrole: "AXStandardTextField"
            )
        )
    }

    func testSelectedTextAndCaretContextAreBounded() {
        let selection = AppContextBounds.selectedText(
            "  " + String(repeating: "s", count: 350) + "  "
        )
        XCTAssertEqual(selection?.count, AppContextBounds.selectedTextCharacterLimit)

        let value = String(repeating: "c", count: 300) + " after"
        let beforeCaret = AppContextBounds.textBeforeCaret(
            in: value,
            selectedRange: CFRange(location: 300, length: 6),
            role: "AXTextArea",
            subrole: "AXStandardTextArea"
        )
        XCTAssertEqual(beforeCaret?.count, AppContextBounds.textBeforeCaretCharacterLimit)
        XCTAssertEqual(beforeCaret, String(repeating: "c", count: 240))
    }

    func testMissingSubroleDoesNotSuppressOrdinaryTextContent() {
        XCTAssertEqual(
            AppContextBounds.selectedText("selected", role: "AXTextArea", subrole: nil),
            "selected"
        )
        XCTAssertEqual(
            AppContextBounds.textBeforeCaret(
                in: "ordinary text",
                selectedRange: CFRange(location: 8, length: 0),
                role: "AXTextArea",
                subrole: nil
            ),
            "ordinary"
        )
    }

    func testCaretHelperUsesSelectionStartAndDoesNotSplitComposedText() {
        XCTAssertEqual(
            AppContextBounds.textBeforeCaret(
                in: "before SELECTED after",
                selectedRange: CFRange(location: 7, length: 8),
                role: "AXTextArea",
                subrole: "AXStandardTextArea"
            ),
            "before "
        )

        let text = "hello 👨‍👩‍👧‍👦 world" as NSString
        let insideFamilyEmoji = text.range(of: "👨‍👩‍👧‍👦").location + 1
        XCTAssertEqual(
            AppContextBounds.textBeforeCaret(
                in: text as String,
                selectedRange: CFRange(location: insideFamilyEmoji, length: 0),
                role: "AXTextArea",
                subrole: "AXStandardTextArea"
            ),
            "hello "
        )
    }

    func testServiceRejectsReusedPIDWithDifferentBundleIdentity() async {
        let requestedApplication = TranscriptDeliveryApplication(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: "com.example.not-the-test-runner"
        )

        let context = await AppContextService().collect(for: requestedApplication)

        XCTAssertEqual(context.processIdentifier, requestedApplication.processIdentifier)
        XCTAssertEqual(context.bundleIdentifier, requestedApplication.bundleIdentifier)
        XCTAssertNil(context.appName)
        XCTAssertNil(context.windowTitle)
        XCTAssertNil(context.selectedText)
        XCTAssertNil(context.textBeforeCaret)
    }
}
