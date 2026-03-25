import Foundation

/// Tracks audio callback cadence via EMA and computes adaptive grace interval
/// for `endRecording()`. Pure value type — no `AVAudioEngine` dependency.
struct CaptureStopTiming {
    static let minGrace: TimeInterval = 0.040     // 40 ms floor
    static let maxGrace: TimeInterval = 0.200     // 200 ms ceiling
    static let fallbackGrace: TimeInterval = 0.100  // used when < 4 callbacks recorded

    private static let emaAlpha: Double = 0.2
    private static let graceMultiplier: Double = 1.5
    private static let minCallbacksForEma: Int = 4

    private var emaIntervalNs: Double = 0
    private var lastTimestampNs: UInt64 = 0
    private var callbackCount: Int = 0

    /// Call from audio callback thread on every buffer delivery.
    mutating func recordCallback(timestampNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        defer {
            lastTimestampNs = timestampNs
            callbackCount += 1
        }
        guard callbackCount > 0 else { return }
        let interval = Double(timestampNs &- lastTimestampNs)
        if emaIntervalNs == 0 {
            emaIntervalNs = interval
        } else {
            emaIntervalNs = Self.emaAlpha * interval + (1 - Self.emaAlpha) * emaIntervalNs
        }
    }

    /// Returns the computed grace interval. Deterministic given EMA state.
    func graceInterval() -> TimeInterval {
        guard callbackCount >= Self.minCallbacksForEma, emaIntervalNs > 0 else {
            return Self.fallbackGrace
        }
        let grace = emaIntervalNs * Self.graceMultiplier / 1_000_000_000
        return min(max(grace, Self.minGrace), Self.maxGrace)
    }
}
