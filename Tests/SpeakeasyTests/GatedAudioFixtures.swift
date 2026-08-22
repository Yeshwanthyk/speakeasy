import Foundation

/// Deterministic synthetic audio fixtures shared by coordinator and
/// speech-gate tests.
///
/// Constant-amplitude audio reads as steady noise to the adaptive speech
/// gate, so acceptance fixtures use burst-modulated tones that alternate
/// four voiced 20 ms frames with two silent 20 ms frames. The silent frames
/// pull the gate's adaptive noise floor down so voiced bursts clear the
/// threshold, matching how real dictations alternate speech with pauses.
enum GatedAudioFixtures {
    /// Burst-modulated 220 Hz sine at `amplitude`.
    static func modulatedSpeech(
        amplitude: Float,
        sampleCount: Int = 8_000,
        sampleRate: Float = 16_000
    ) -> ContiguousArray<Float> {
        var samples = ContiguousArray<Float>(repeating: 0, count: sampleCount)
        let frameSize = Int((sampleRate * 0.02).rounded(.up))
        guard frameSize > 0 else { return samples }
        var frame = 0
        while frame * frameSize < sampleCount {
            if frame % 6 < 4 {
                fillFrame(
                    into: &samples,
                    frame: frame,
                    frameSize: frameSize,
                    amplitude: amplitude,
                    sampleRate: sampleRate
                )
            }
            frame += 1
        }
        return samples
    }

    /// White noise following the same burst pattern as `modulatedSpeech`, so
    /// burst frames carry ample energy but flip sign constantly.
    static func modulatedNoise(
        amplitude: Float,
        sampleCount: Int = 8_000,
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) -> ContiguousArray<Float> {
        var state = seed
        var samples = ContiguousArray<Float>(repeating: 0, count: sampleCount)
        let frameSize = 320
        var frame = 0
        while frame * frameSize < sampleCount {
            if frame % 6 < 4 {
                for i in 0..<frameSize {
                    let index = frame * frameSize + i
                    guard index < sampleCount else { break }
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let unit = Float((state >> 11) & 0xFFFF_FFFF) / Float(UInt32.max)
                    samples[index] = (unit * 2 - 1) * amplitude
                }
            }
            frame += 1
        }
        return samples
    }

    /// Continuous tone whose every frame is identical; adaptive gating
    /// correctly treats this as steady noise rather than speech.
    static func steadyTone(
        amplitude: Float,
        sampleCount: Int = 8_000,
        frequency: Float = 220
    ) -> ContiguousArray<Float> {
        var samples = ContiguousArray<Float>(repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            samples[index] = amplitude * sin(2 * .pi * frequency * Float(index) / 16_000)
        }
        return samples
    }

    /// Ambient white noise floor with speech bursts riding on top.
    static func speechOverAmbient(
        ambientAmplitude: Float,
        burstAmplitude: Float,
        sampleCount: Int = 8_000,
        seed: UInt64 = 42
    ) -> ContiguousArray<Float> {
        var combined = whiteNoise(amplitude: ambientAmplitude, sampleCount: sampleCount, seed: seed)
        let frameSize = 320
        var frame = 0
        while frame * frameSize < sampleCount {
            if frame % 6 < 4 {
                for i in 0..<frameSize {
                    let index = frame * frameSize + i
                    guard index < sampleCount else { break }
                    combined[index] += burstAmplitude * sin(2 * .pi * 220 * Float(i) / 16_000)
                }
            }
            frame += 1
        }
        return combined
    }

    /// Deterministic pseudo-random white noise from an LCG so failures
    /// reproduce exactly.
    static func whiteNoise(
        amplitude: Float,
        sampleCount: Int = 8_000,
        seed: UInt64
    ) -> ContiguousArray<Float> {
        var state = seed
        var samples = ContiguousArray<Float>(repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 11) & 0xFFFF_FFFF) / Float(UInt32.max)
            samples[index] = (unit * 2 - 1) * amplitude
        }
        return samples
    }

    private static func fillFrame(
        into samples: inout ContiguousArray<Float>,
        frame: Int,
        frameSize: Int,
        amplitude: Float,
        sampleRate: Float
    ) {
        for i in 0..<frameSize {
            let index = frame * frameSize + i
            guard index < samples.count else { break }
            samples[index] = amplitude * sin(2 * .pi * 220 * Float(i) / sampleRate)
        }
    }
}
