import XCTest
@testable import Speakeasy

@MainActor
final class OnboardingModelTests: XCTestCase {
    private final class Grants {
        var microphone: PermissionState = .notDetermined
        var accessibility: PermissionState = .denied
        var inputMonitoring: PermissionState = .denied

        func grantAll() {
            microphone = .granted
            accessibility = .granted
            inputMonitoring = .granted
        }
    }

    private func makeModel(_ grants: Grants, opened: @escaping (OnboardingPermission) -> Void = { _ in },
                           closed: @escaping () -> Void = {}) -> OnboardingModel {
        var actions = OnboardingModel.Actions(
            startEngine: { true },
            latestTranscript: { nil },
            currentShortcut: { .functionKey },
            changeShortcut: {},
            finish: {},
            relaunch: {}
        )
        actions.openPermissionSettings = opened
        actions.closePermissionGuide = closed
        let client = OnboardingPermissionClient(
            microphone: { grants.microphone },
            accessibility: { grants.accessibility },
            inputMonitoring: { grants.inputMonitoring }
        )
        let model = OnboardingModel(actions: actions, initialModel: .parakeet110M,
                                    permissionClient: client, isLive: false)
        model.refresh()
        return model
    }

    func testCannotLeavePermissionsUntilEveryGrantIsOn() {
        let grants = Grants()
        let model = makeModel(grants)
        model.step = .permissions

        model.advance()
        XCTAssertEqual(model.step, .permissions)

        grants.microphone = .granted
        grants.accessibility = .granted
        model.refresh()
        model.advance()
        XCTAssertEqual(model.step, .permissions, "Input Monitoring is still off")

        grants.inputMonitoring = .granted
        model.refresh()
        model.advance()
        XCTAssertEqual(model.step, .tryIt)
    }

    func testNextPermissionIsTheFirstUnmetRow() {
        let grants = Grants()
        let model = makeModel(grants)
        XCTAssertEqual(model.nextPermission, .microphone)

        grants.microphone = .granted
        model.refresh()
        XCTAssertEqual(model.nextPermission, .accessibility)

        grants.grantAll()
        model.refresh()
        XCTAssertNil(model.nextPermission)
    }

    func testRequestingAListPermissionOpensSettingsAndWaits() {
        let grants = Grants()
        grants.microphone = .granted
        var opened: [OnboardingPermission] = []
        let model = makeModel(grants, opened: { opened.append($0) })
        model.step = .permissions

        model.request(.accessibility)
        XCTAssertEqual(opened, [.accessibility])
        XCTAssertEqual(model.status(of: .accessibility), .waiting)
        XCTAssertTrue(model.visitedSystemSettings)

        grants.accessibility = .granted
        model.refresh()
        XCTAssertEqual(model.status(of: .accessibility), .allowed)
    }

    func testGuideClosesOnlyWhenItsOwnPermissionIsGranted() {
        let grants = Grants()
        grants.microphone = .granted
        grants.accessibility = .granted
        var closes = 0
        let model = makeModel(grants, closed: { closes += 1 })
        model.step = .permissions

        model.request(.inputMonitoring)
        let before = closes
        model.refresh()
        XCTAssertEqual(closes, before, "An unrelated grant must not close the Input Monitoring guide")

        grants.inputMonitoring = .granted
        model.refresh()
        XCTAssertEqual(closes, before + 1)
    }

    func testBackWalksOneStep() {
        let model = makeModel(Grants())
        model.step = .model
        model.goBack()
        XCTAssertEqual(model.step, .welcome)
        model.goBack()
        XCTAssertEqual(model.step, .welcome)
    }
}
