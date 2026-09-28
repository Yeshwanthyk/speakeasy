import XCTest
@testable import Speakeasy

final class OnboardingStoreTests: XCTestCase {
    func testNeedsOnboardingUntilCompletedWithAllPermissions() {
        XCTAssertTrue(OnboardingStore.needsOnboarding(
            isComplete: false, microphone: .granted, accessibility: .granted, inputMonitoring: .granted
        ))
        XCTAssertFalse(OnboardingStore.needsOnboarding(
            isComplete: true, microphone: .granted, accessibility: .granted, inputMonitoring: .granted
        ))
    }

    func testRevokedPermissionReopensOnboarding() {
        XCTAssertTrue(OnboardingStore.needsOnboarding(
            isComplete: true, microphone: .denied, accessibility: .granted, inputMonitoring: .granted
        ))
        XCTAssertTrue(OnboardingStore.needsOnboarding(
            isComplete: true, microphone: .granted, accessibility: .granted, inputMonitoring: .denied
        ))
    }

    func testCompletionFlagPersists() throws {
        let suite = "OnboardingStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(OnboardingStore.isComplete(defaults: defaults))
        OnboardingStore.markComplete(defaults: defaults)
        XCTAssertTrue(OnboardingStore.isComplete(defaults: defaults))
    }
}
