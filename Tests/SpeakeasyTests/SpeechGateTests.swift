import Foundation
import XCTest
@testable import Speakeasy

final class SpeechGateTests: XCTestCase {
    private let frameSize = 320 // 50 Hz at 16 kHz

    // MARK: - Acceptance

    func testLoudModulatedSpeechIsAccepted() {
        let result = SpeechGate.analyze(GatedAudioFixtures.modulatedSpeech(amplitude: 0.1))
        XCTAssertTrue(result.hasSpeech)
        XCTAssertGreaterThanOrEqual(result.longestVoicedRun, 4)
        XCTAssertEqual(result.analyzedFrameCount, 25)
    }

    func testQuietSpeechNearNoiseFloorIsAccepted() {
        // -48 dBFS peak; must still clear the conservative absolute floor.
        let result = SpeechGate.analyze(GatedAudioFixtures.modulatedSpeech(amplitude: 0.004))
        XCTAssertTrue(result.hasSpeech)
    }

    func testSpeechRidingAboveAmbientNoiseIsAccepted() {
        // Bursts sit well above three times the ambient noise floor.
        let result = SpeechGate.analyze(
            GatedAudioFixtures.speechOverAmbient(ambientAmplitude: 0.008, burstAmplitude: 0.08)
        )
        XCTAssertTrue(result.hasSpeech)
        XCTAssertGreaterThan(result.noiseFloorRMS, 0.001, "floor should adapt to ambient level")
    }

    func testExactlyRequiredRunIsAccepted() {
        // Exactly four consecutive voiced frames then silence for the rest.
        var samples = ContiguousArray<Float>(repeating: 0, count: 8_000)
        for i in 0..<(4 * frameSize) {
            samples[i] = 0.1 * sin(2 * .pi * 220 * Float(i) / 16_000)
        }
        let result = SpeechGate.analyze(samples)
        XCTAssertEqual(result.longestVoicedRun, 4)
        XCTAssertTrue(result.hasSpeech)
    }

    // MARK: - Rejection

    func testSilenceIsRejected() {
        let silence = ContiguousArray<Float>(repeating: 0.0001, count: 8_000)
        let result = SpeechGate.analyze(silence)
        XCTAssertFalse(result.hasSpeech)
        XCTAssertEqual(result.voicedFrameCount, 0)
    }

    func testDigitalSilenceIsRejected() {
        let result = SpeechGate.analyze(ContiguousArray<Float>(repeating: 0, count: 8_000))
        XCTAssertFalse(result.hasSpeech)
    }

    func testQuietSteadyToneIsRejectedAsSteadyNoise() {
        // Every frame is identical, so the adaptive floor equals the signal
        // level and no frame can clear the ratio bar. This strictness is the
        // point of adaptive gating: steady tones are hum, not speech.
        let result = SpeechGate.analyze(GatedAudioFixtures.steadyTone(amplitude: 0.004))
        XCTAssertFalse(result.hasSpeech)
    }

    func testLoudSteadyToneIsRejectedAsSteadyNoise() {
        let result = SpeechGate.analyze(GatedAudioFixtures.steadyTone(amplitude: 0.1))
        XCTAssertFalse(result.hasSpeech)
    }

    func testLoudBurstyWhiteNoiseIsRejectedByZeroCrossingRate() {
        let samples = GatedAudioFixtures.modulatedNoise(amplitude: 0.3)
        let rejected = SpeechGate.analyze(samples)
        XCTAssertFalse(rejected.hasSpeech)

        // Same audio accepted once the ZCR criterion is disabled — proving
        // energy cleared the threshold and only broadband structure failed.
        var zcrDisabled = SpeechGate.Config()
        zcrDisabled.maxZeroCrossingRate = 10.0
        let energyOnly = SpeechGate.analyze(samples, config: zcrDisabled)
        XCTAssertTrue(energyOnly.hasSpeech)
    }

    func testQuietSpeechBuriedUnderLoudAmbientNoiseIsRejected() {
        // Ambient floor is high enough that three-times-floor exceeds the
        // burst level; transcribing this would yield garbage anyway.
        let result = SpeechGate.analyze(
            GatedAudioFixtures.speechOverAmbient(ambientAmplitude: 0.05, burstAmplitude: 0.06)
        )
        XCTAssertFalse(result.hasSpeech)
    }

    func testTooFewConsecutiveVoicedFramesIsRejected() {
        // Three isolated voiced bursts (under the four-frame requirement):
        // clicks must not trigger a transcription pass.
        var samples = ContiguousArray<Float>(repeating: 0, count: 8_000)
        for burst in 0..<3 {
            let start = burst * 5 * frameSize
            for i in 0..<frameSize where start + i < samples.count {
                samples[start + i] = 0.1 * sin(2 * .pi * 220 * Float(i) / 16_000)
            }
        }
        let result = SpeechGate.analyze(samples)
        XCTAssertGreaterThanOrEqual(result.longestVoicedRun, 1)
        XCTAssertLessThan(result.longestVoicedRun, 4)
        XCTAssertFalse(result.hasSpeech)
    }

    // MARK: - Edge cases

    func testEmptySamplesAreRejected() {
        let result = SpeechGate.analyze(ContiguousArray<Float>())
        XCTAssertFalse(result.hasSpeech)
        XCTAssertEqual(result.analyzedFrameCount, 0)
    }

    func testShorterThanOneFrameIsRejected() {
        let result = SpeechGate.analyze(
            GatedAudioFixtures.modulatedSpeech(amplitude: 0.1, sampleCount: 319)
        )
        XCTAssertFalse(result.hasSpeech)
        XCTAssertEqual(result.analyzedFrameCount, 0)
    }

    func testStartingAtSkipsPrerollSamples() {
        let prerollSampleCount = 1_500 // not frame-aligned on purpose
        let active = GatedAudioFixtures.modulatedSpeech(amplitude: 0.1)
        var withPreroll = ContiguousArray<Float>(repeating: 0.0001, count: prerollSampleCount)
        withPreroll.append(contentsOf: active)

        let skipped = SpeechGate.analyze(withPreroll, startingAt: prerollSampleCount)
        let unskipped = SpeechGate.analyze(withPreroll)

        XCTAssertTrue(skipped.hasSpeech)
        XCTAssertTrue(unskipped.hasSpeech, "bursts stay robust to frame misalignment")
        XCTAssertEqual(skipped.analyzedFrameCount, (withPreroll.count - prerollSampleCount) / frameSize)
        XCTAssertEqual(unskipped.analyzedFrameCount, withPreroll.count / frameSize)
    }

    func testConfigChangesBehavior() {
        let samples = GatedAudioFixtures.modulatedSpeech(amplitude: 0.1)

        var strictConfig = SpeechGate.Config()
        strictConfig.requiredConsecutiveVoicedFrames = 1_000
        XCTAssertFalse(SpeechGate.analyze(samples, config: strictConfig).hasSpeech)

        var permissiveConfig = SpeechGate.Config()
        permissiveConfig.requiredConsecutiveVoicedFrames = 1
        XCTAssertTrue(SpeechGate.analyze(samples, config: permissiveConfig).hasSpeech)
    }

    func testResultIsDeterministicAcrossRuns() {
        let samples = GatedAudioFixtures.speechOverAmbient(
            ambientAmplitude: 0.008,
            burstAmplitude: 0.08
        )
        XCTAssertEqual(SpeechGate.analyze(samples), SpeechGate.analyze(samples))
    }
}
