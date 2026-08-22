import Accelerate
import Foundation

/// Result of analyzing a dictation recording for speech presence.
struct SpeechGateResult: Equatable, Sendable {
    /// Whether the recording contains speech worth transcribing.
    let hasSpeech: Bool
    /// Adaptive noise floor: the 20th-percentile frame RMS.
    let noiseFloorRMS: Float
    /// Number of frames that met the voiced criteria.
    let voicedFrameCount: Int
    /// Total number of full frames analyzed.
    let analyzedFrameCount: Int
    /// Longest run of consecutive voiced frames.
    let longestVoicedRun: Int
}

/// Energy-based speech presence detector applied after capture stops and
/// before dispatching audio to the transcriber.
///
/// Replaces a single global RMS threshold, which cannot distinguish quiet
/// speech in a quiet room from steady broadband noise in a loud one. Frames
/// are 50 Hz windows of mono 16 kHz PCM. A frame is voiced when its RMS beats
/// both an adaptive bar (`noiseFloorRatio` times the recording's 20th-percentile
/// frame RMS) and a fixed conservative floor, and its zero-crossing rate is
/// below `maxZeroCrossingRate` to reject broadband hiss, fans, and keyboard
/// clatter that carry energy but lack voiced-signal structure. Speech is
/// present only when at least `requiredConsecutiveVoicedFrames` run together,
/// so isolated clicks do not trigger a transcription pass.
enum SpeechGate {
    /// Conservative absolute RMS floor matching the previous fixed gate;
    /// microphone gain can put valid speech near -48 dBFS.
    private static let absoluteRMSFloor: Float = 0.002

    /// Tunable analysis parameters; defaults model mono 16 kHz dictation audio.
    struct Config: Sendable {
        var sampleRate: Float = 16_000
        /// Analysis window; 20 ms frames (a 50 Hz frame rate) match the
        /// reference implementation.
        var frameDuration: Double = 0.02
        /// Percentile of frame RMS used as the adaptive noise floor.
        var noiseFloorPercentile: Float = 0.20
        /// Voiced frames must exceed this multiple of the noise floor.
        var noiseFloorRatio: Float = 3.0
        /// Zero-crossing rate above this marks a frame as broadband noise.
        var maxZeroCrossingRate: Float = 0.20
        /// Consecutive voiced frames required to consider speech present.
        var requiredConsecutiveVoicedFrames: Int = 4
    }

    /// Analyzes active (non-preroll) samples starting at `startingAt`.
    static func analyze(
        _ samples: ContiguousArray<Float>,
        startingAt start: Int = 0,
        config: Config = Config()
    ) -> SpeechGateResult {
        let clampedStart = min(max(start, 0), samples.count)
        let sampleCount = samples.count - clampedStart
        // Rounded, not truncated: binary floats can't represent most decimal
        // durations exactly and truncation shifts every frame boundary.
        let frameSize = Int((config.sampleRate * Float(config.frameDuration)).rounded(.up))
        guard frameSize > 0, sampleCount >= frameSize else {
            return SpeechGateResult(
                hasSpeech: false,
                noiseFloorRMS: 0,
                voicedFrameCount: 0,
                analyzedFrameCount: 0,
                longestVoicedRun: 0
            )
        }

        var frameRMSValues: [Float] = []
        var frameZCRValues: [Float] = []
        frameRMSValues.reserveCapacity(sampleCount / frameSize)
        frameZCRValues.reserveCapacity(sampleCount / frameSize)

        // Frame energy runs through vDSP (SIMD) because this scan is the
        // dominant constant cost between capture stop and dispatch. Zero
        // crossings are computed only for frames whose energy already clears
        // a coarse pre-scan threshold, so silence-heavy recordings skip most
        // of the sign-flip pass.
        let coarseThreshold = max(
            config.noiseFloorRatio * Self.coarseNoiseFloor(
                samples: samples,
                start: clampedStart,
                frameSize: frameSize
            ),
            absoluteRMSFloor * 0.9
        )

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = clampedStart
            while offset + frameSize <= samples.count {
                defer { offset += frameSize }

                let rms = vDSP.meanSquare(
                    UnsafeBufferPointer(start: base + offset, count: frameSize)
                ).squareRoot()
                guard rms > coarseThreshold else {
                    // Energy alone disqualifies this frame from voicing;
                    // recording zero crossings here keeps arrays aligned
                    // while skipping the sign-flip pass entirely.
                    frameRMSValues.append(rms)
                    frameZCRValues.append(0)
                    continue
                }

                var crossings = 0
                var previousSignPositive = (base + offset).pointee >= 0
                var hasPreviousSign = false
                for step in 0..<frameSize {
                    let sample = (base + offset + step).pointee
                    let signPositive = sample >= 0
                    if hasPreviousSign, signPositive != previousSignPositive {
                        crossings += 1
                    }
                    hasPreviousSign = true
                    previousSignPositive = signPositive
                }
                frameRMSValues.append(rms)
                frameZCRValues.append(Float(crossings) / Float(frameSize - 1))
            }
        }

        let frameCount = frameRMSValues.count
        guard frameCount > 0 else {
            return SpeechGateResult(
                hasSpeech: false,
                noiseFloorRMS: 0,
                voicedFrameCount: 0,
                analyzedFrameCount: 0,
                longestVoicedRun: 0
            )
        }

        let sortedRMS = frameRMSValues.sorted()
        let floorIndex = min(
            Int(Float(frameCount - 1) * config.noiseFloorPercentile),
            frameCount - 1
        )
        let noiseFloor = sortedRMS[floorIndex]
        let voicingThreshold = max(
            config.noiseFloorRatio * noiseFloor,
            absoluteRMSFloor
        )

        var voicedFrameCount = 0
        var longestRun = 0
        var currentRun = 0
        for index in 0..<frameCount {
            let isVoiced = frameRMSValues[index] > voicingThreshold
                && frameZCRValues[index] < config.maxZeroCrossingRate
            if isVoiced {
                voicedFrameCount += 1
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        return SpeechGateResult(
            hasSpeech: longestRun >= config.requiredConsecutiveVoicedFrames,
            noiseFloorRMS: noiseFloor,
            voicedFrameCount: voicedFrameCount,
            analyzedFrameCount: frameCount,
            longestVoicedRun: longestRun
        )
    }
    /// Cheap pre-pass floor estimate over a coarse sample of frames (~16).
    /// Only gates whether the zero-crossing pass runs for a frame; exact
    /// voicing decisions always use the full per-frame RMS list below.
    private static func coarseNoiseFloor(
        samples: ContiguousArray<Float>,
        start: Int,
        frameSize: Int
    ) -> Float {
        let availableSamples = max(samples.count - start, 0)
        let totalFrames = availableSamples / frameSize
        guard totalFrames > 0 else { return 0 }
        let strideFrames = max(totalFrames / 16, 1)
        var estimates: [Float] = []
        estimates.reserveCapacity(totalFrames / strideFrames + 1)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var frameIndex = 0
            while frameIndex < totalFrames {
                estimates.append(vDSP.meanSquare(
                    UnsafeBufferPointer(
                        start: base + start + frameIndex * frameSize,
                        count: frameSize
                    )
                ).squareRoot())
                frameIndex += strideFrames
            }
        }
        guard !estimates.isEmpty else { return 0 }
        estimates.sort()
        return estimates[estimates.count / 4]
    }

}
