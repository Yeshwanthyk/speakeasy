import Foundation
import XCTest
@testable import Speakeasy

final class AppInstanceSelectorTests: XCTestCase {
    func testProceedWhenNoOtherInstancesAreRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Applications/Speakeasy.app")
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: []),
            .proceed
        )
    }

    func testInstalledCopyTerminatesNonInstalledCompetitors() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Applications/Speakeasy.app")
        )
        let other = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Documents/personal/wisp/build/Speakeasy.app")
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: [other]),
            .terminateOthers([100])
        )
    }

    func testNonInstalledCopyExitsWhenInstalledCopyIsAlreadyRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Documents/personal/wisp/build/Speakeasy.app")
        )
        let other = AppInstanceSelector.Descriptor(
            pid: 100,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Applications/Speakeasy.app")
        )

        XCTAssertEqual(
            AppInstanceSelector.decide(current: current, others: [other]),
            .terminateSelf(preferred: other)
        )
    }

    func testLaterNonInstalledCopyExitsWhenAnotherNonInstalledCopyIsRunning() {
        let current = AppInstanceSelector.Descriptor(
            pid: 200,
            bundleURL: URL(fileURLWithPath: "/Users/yesh/Documents/personal/wisp/build/Speakeasy.app")
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
