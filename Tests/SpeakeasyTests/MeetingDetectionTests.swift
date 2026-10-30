import XCTest
@testable import Speakeasy

final class MeetingDetectionTests: XCTestCase {
    private let zoom = MicrophoneClient(bundleIdentifier: "us.zoom.xos", name: "zoom.us")
    private let chromeHelper = MicrophoneClient(bundleIdentifier: "com.google.Chrome.helper", name: "Google Chrome Helper")
    private let recorder = MicrophoneClient(bundleIdentifier: "com.example.voice-memos", name: "Voice")

    func testHelpersAreAttributedToTheirApp() {
        XCTAssertEqual(MeetingApps.classify("com.google.Chrome.helper")?.appBundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(MeetingApps.classify("com.google.Chrome.helper")?.kind, .browser)
        XCTAssertEqual(MeetingApps.classify("us.zoom.xos")?.kind, .callApp)
        XCTAssertNil(MeetingApps.classify("com.example.voice-memos"))
        XCTAssertNil(MeetingApps.classify("us.zoom.xosother"), "prefix must end at a dot")
    }

    func testCallAppIsOfferedAfterTwoSecondsOnTheMicrophone() {
        var detector = MeetingDetector()

        XCTAssertNil(observe(&detector, at: 0, [zoom]))
        XCTAssertNil(observe(&detector, at: 1, [zoom]))
        XCTAssertEqual(observe(&detector, at: 2, [zoom]), .offer(bundleIdentifier: "us.zoom.xos", name: "Zoom"))
        XCTAssertNil(observe(&detector, at: 3, [zoom]), "offered once per call")
    }

    func testBrowsersNeedTwentySeconds() {
        var detector = MeetingDetector()
        for second in stride(from: 0, to: 20, by: 1) {
            XCTAssertNil(observe(&detector, at: TimeInterval(second), [chromeHelper]))
        }
        XCTAssertEqual(observe(&detector, at: 20, [chromeHelper]), .offer(bundleIdentifier: "com.google.Chrome", name: "Google Chrome"))
    }

    func testUnrelatedMicrophoneUseIsIgnored() {
        var detector = MeetingDetector()
        for second in 0..<60 {
            XCTAssertNil(observe(&detector, at: TimeInterval(second), [recorder]))
        }
    }

    func testBriefMicrophoneUseResetsStability() {
        var detector = MeetingDetector()
        XCTAssertNil(observe(&detector, at: 0, [zoom]))
        XCTAssertNil(observe(&detector, at: 1, []))
        XCTAssertNil(observe(&detector, at: 2, [zoom]))
        XCTAssertNil(observe(&detector, at: 3, [zoom]))
        XCTAssertNotNil(observe(&detector, at: 4, [zoom]))
    }

    func testSnoozeLiftsOnlyAfterSixtySecondsOffTheMicrophone() {
        var detector = MeetingDetector()
        _ = observe(&detector, at: 0, [zoom])
        XCTAssertNotNil(observe(&detector, at: 2, [zoom]))

        XCTAssertNil(observe(&detector, at: 10, []))
        XCTAssertNil(observe(&detector, at: 12, [zoom]))
        XCTAssertNil(observe(&detector, at: 15, [zoom]), "rejoining within a minute is the same call")

        for second in stride(from: 16, through: 76, by: 5) {
            _ = observe(&detector, at: TimeInterval(second), [])
        }
        XCTAssertNil(observe(&detector, at: 78, [zoom]))
        XCTAssertNotNil(observe(&detector, at: 80, [zoom]), "a new call after a minute away is offered")
    }

    func testLongGapsRestartStability() {
        var detector = MeetingDetector()
        XCTAssertNil(observe(&detector, at: 0, [zoom]))
        // The Mac slept; the first observation after waking must not offer.
        XCTAssertNil(observe(&detector, at: 30, [zoom]))
        XCTAssertNotNil(observe(&detector, at: 32, [zoom]))
    }

    func testRecordedCallEndsAfterTheAppLeavesTheMicrophone() {
        var detector = MeetingDetector()
        _ = observe(&detector, at: 0, [zoom], recording: true, app: "us.zoom.xos")
        XCTAssertNil(observe(&detector, at: 1, [], recording: true, app: "us.zoom.xos"))
        XCTAssertNil(observe(&detector, at: 2, [], recording: true, app: "us.zoom.xos"))
        XCTAssertEqual(
            observe(&detector, at: 3, [], recording: true, app: "us.zoom.xos"),
            .ended(bundleIdentifier: "us.zoom.xos")
        )
        XCTAssertNil(observe(&detector, at: 4, [], recording: true, app: "us.zoom.xos"), "ended once")
    }

    func testNothingIsOfferedWhileRecording() {
        var detector = MeetingDetector()
        for second in 0..<10 {
            XCTAssertNil(observe(&detector, at: TimeInterval(second), [zoom], recording: true, app: nil))
        }
    }

    func testDeclinedOfferStaysSnoozed() {
        var detector = MeetingDetector()
        detector.snooze("us.zoom.xos")
        for second in 0..<10 {
            XCTAssertNil(observe(&detector, at: TimeInterval(second), [zoom]))
        }
    }

    func testCallAppsWinOverBrowsersWhenBothAreReady() {
        var detector = MeetingDetector()
        for second in 0...20 {
            if let event = observe(&detector, at: TimeInterval(second), [zoom, chromeHelper]) {
                XCTAssertEqual(event, .offer(bundleIdentifier: "us.zoom.xos", name: "Zoom"))
                return
            }
        }
        XCTFail("expected an offer")
    }

    private func observe(
        _ detector: inout MeetingDetector,
        at time: TimeInterval,
        _ clients: [MicrophoneClient],
        recording: Bool = false,
        app: String? = nil
    ) -> MeetingDetector.Event? {
        detector.observe(now: time, clients: Set(clients), isRecording: recording, recordingApp: app)
    }
}
