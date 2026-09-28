import Foundation
import XCTest
@testable import Speakeasy

final class AppInstanceSelectorTests: XCTestCase {
    private let installedURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Speakeasy.app")
    private let buildURL = testScratchDirectory
        .appendingPathComponent("speakeasy-build/Speakeasy.app")

    func testProceedWhenNoOtherInstancesAreRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: installedURL
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: []),
            .proceed
        )
    }

    func testInstalledCopyTerminatesNonInstalledCompetitors() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: installedURL
        )
        let other = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: buildURL
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: [other]),
            .terminateOthers([100])
        )
    }

    func testNonInstalledCopyExitsWhenInstalledCopyIsAlreadyRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: buildURL
        )
        let other = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: installedURL
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: [other]),
            .terminateSelf(preferred: other)
        )
    }

    func testLaterNonInstalledCopyExitsWhenAnotherNonInstalledCopyIsRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: buildURL
        )
        let other = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: URL(fileURLWithPath: "/tmp/Speakeasy.app")
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: [other]),
            .terminateSelf(preferred: other)
        )
    }
}
