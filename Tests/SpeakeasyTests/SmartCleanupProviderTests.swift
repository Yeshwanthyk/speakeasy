import Foundation
import XCTest

@testable import Speakeasy

final class SmartCleanupProviderTests: XCTestCase {
    func testUnavailableProviderReturnsTypedFailureWithoutThrowing() async {
        let provider = UnavailableSmartCleanupProvider(reason: .unsupportedOperatingSystem)
        let request = SmartCleanupRequest(
            transcript: "hello",
            appContext: AppContext(
                processIdentifier: 1,
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                textBeforeCaret: nil
            )
        )

        let availability = await provider.availability()
        XCTAssertEqual(availability, .unavailable(.unsupportedOperatingSystem))
        await provider.prepare(sessionID: UUID())
        await provider.cancel(sessionID: UUID())

        let result = await provider.clean(request, sessionID: UUID())
        XCTAssertEqual(
            result,
            .failure(
                SmartCleanupFailure(
                    reason: .unavailable(.unsupportedOperatingSystem),
                    elapsed: 0
                )
            )
        )
    }
}
