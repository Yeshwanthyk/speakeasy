import Foundation
import XCTest
@testable import Speakeasy

/// Performance guards over the per-dictation constant-cost path.
///
/// These assert generous ceilings so they stay stable across machines and
/// CI load while catching accidental order-of-magnitude regressions (the
/// "hidden 100 ms property accessor" class of bug). Measured medians are
/// printed so audits can record real numbers per machine.
final class HotPathPerformanceTests: XCTestCase {
    private func medianOf(_ iterations: Int, _ body: () -> Void) -> Duration {
        var samples: [Duration] = []
        for index in 0..<iterations {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            // Warm up: discard the first few iterations' timings.
            if index >= 3 { samples.append(elapsed) }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func assertUnder(
        _ limit: Duration,
        _ measured: Duration,
        _ label: String
    ) {
        print("PERF \(label): \(measured)")
        XCTAssertLessThan(measured, limit, "\(label) exceeded budget")
    }

    func testSpeechGateOnThirtySecondUtterance() {
        let samples = GatedAudioFixtures.modulatedSpeech(amplitude: 0.1, sampleCount: 480_000)
        let measured = medianOf(9) { _ = SpeechGate.analyze(samples) }
        assertUnder(.milliseconds(10), measured, "speech_gate_30s_audio_median")
    }

    func testPhoneticCorrectionOnTypicalSentence() throws {
        let terms = (0..<64).map { index in
            PhoneticTerm(
                canonical: "Term\(index)",
                spokenForms: ["term \(index)", "turm \(index)"]
            )
        }
        let corrector = try PhoneticCorrector(terms: terms)
        let text = "please deploy term 12 and term 33 to the cluster today"
        let measured = medianOf(51) { _ = corrector.correct(text) }
        assertUnder(.milliseconds(2), measured, "phonetic_correct_typical_median")
    }

    func testPhoneticCorrectionOnLongUtterance() throws {
        let terms = (0..<128).map { index in
            PhoneticTerm(canonical: "API\(index)", spokenForms: ["api \(index)"])
        }
        let corrector = try PhoneticCorrector(terms: terms)
        let words = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let measured = medianOf(21) { _ = corrector.correct(words) }
        assertUnder(.milliseconds(20), measured, "phonetic_correct_300words_median")
    }

    func testPostProcessorPipelineOnTypicalSentence() throws {
        let processor = try TranscriptPostProcessor(
            corrections: [
                TranscriptCorrection(heard: "hello wisp", written: "Hello, Wisp"),
                TranscriptCorrection(heard: "new paragraph please", written: "\n\n"),
            ],
            phoneticTerms: [PhoneticTerm(canonical: "CUDA", spokenForms: ["kudo"])]
        )
        let text = "hello wisp run the kudo kernel new paragraph please ship it"
        let measured = medianOf(51) { _ = processor.process(text) }
        assertUnder(.milliseconds(2), measured, "post_processor_pipeline_median")
    }

    func testHallucinationFilterVerdictOnTypicalText() {
        let filter = HallucinationFilter()
        let text = "the deployment finished successfully and logs look clean"
        let measured = medianOf(51) {
            _ = filter.verdict(for: text, activeDurationSeconds: 3.0, activeRMS: 0.05)
        }
        assertUnder(.milliseconds(1), measured, "hallucination_filter_median")
    }

    func testRingBufferPreRollRead() {
        let buffer = FloatRingBuffer(capacity: 16_000 * 120)
        let chunk = ContiguousArray<Float>(repeating: 0.1, count: 4_096)
        for _ in 0..<(16_000 * 60 / 4_096) {
            chunk.withUnsafeBufferPointer { pointer in
                buffer.write(pointer)
            }
        }
        let measured = medianOf(51) { _ = buffer.readLast(4_800) }
        assertUnder(.milliseconds(2), measured, "ring_buffer_preroll_read_median")
    }
}
