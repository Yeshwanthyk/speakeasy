import XCTest
@testable import Speakeasy

final class DictationAttemptTests: XCTestCase {
    func testDigitalSilenceIsReportedAsASilentMicrophone() {
        XCTAssertEqual(DictationAttemptResult.rejectedSpeech(rms: 0), .silentMicrophone)
        XCTAssertEqual(DictationAttemptResult.rejectedSpeech(rms: 0.00005), .silentMicrophone)
    }

    func testQuietRoomNoiseIsReportedAsNoSpeech() {
        XCTAssertEqual(DictationAttemptResult.rejectedSpeech(rms: 0.003), .noSpeech)
        XCTAssertEqual(DictationAttemptResult.rejectedSpeech(rms: .nan), .noSpeech)
    }

    func testEveryFailureHasDistinctActionableCopy() {
        let failures: [DictationAttemptResult] = [
            .tooShort, .silentMicrophone, .noSpeech, .interrupted, .failed, .accessibilityDenied
        ]
        let messages = failures.compactMap { PracticeHint.message(for: $0, microphoneName: "USB Mic") }

        XCTAssertEqual(messages.count, failures.count)
        XCTAssertEqual(Set(messages).count, failures.count)
        XCTAssertTrue(messages[1].contains("“USB Mic”"))
    }

    func testSuccessAndCancelHaveNoHint() {
        XCTAssertNil(PracticeHint.message(for: .delivered, microphoneName: nil))
        XCTAssertNil(PracticeHint.message(for: .cancelled, microphoneName: nil))
    }
}
