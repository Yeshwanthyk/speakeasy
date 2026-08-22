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

        samples.withUnsafeBufferPointer { buffer in
            var offset = clampedStart
            while offset + frameSize <= samples.count {
                var sumSquares: Float = 0
                var crossings = 0
                var previousSignPositive = buffer[offset] >= 0
                var hasPreviousSign = false
                for index in offset..<(offset + frameSize) {
                    let sample = buffer[index]
                    sumSquares += sample * sample
                    let signPositive = sample >= 0
                    if hasPreviousSign, signPositive != previousSignPositive {
                        crossings += 1
                    }
                    hasPreviousSign = true
                    previousSignPositive = signPositive
                }
                frameRMSValues.append((sumSquares / Float(frameSize)).squareRoot())
                frameZCRValues.append(Float(crossings) / Float(frameSize - 1))
                offset += frameSize
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
}
