import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)
}

struct AudioCaptureResult {
    let samples: ContiguousArray<Float>
    let prependedSampleCount: Int
    let graceDurationMs: Double
}

final class AudioCapture {
    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let defaultMaxRecordingSamples = 16_000 * 60 * 6
    private static let flushThreshold = 8_000
    private static let ringBufferCapacity = 16_000
    private static let preRollSampleCount = 6_400
    private static let graceTimeoutPadding: TimeInterval = 0.020

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "audio")
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let sampleRateRatio: Double
    private let maxRecordingSamples: Int
    private let onLimitReached: (() -> Void)?
    private let ringBuffer = FloatRingBuffer(capacity: AudioCapture.ringBufferCapacity)
    private let graceSemaphore = DispatchSemaphore(value: 0)

    private let frontLock = UnfairLock()
    private let backLock = UnfairLock()
    private let stateLock = UnfairLock()
    private let stopTimingLock = UnfairLock()

    private var frontBuffer = ContiguousArray<Float>()
    private var backBuffer = ContiguousArray<Float>()
    private var isRecording = false
    private var isPrepared = false
    private var conversionBuffer: AVAudioPCMBuffer?
    private var didReachLimit = false
    private var stopTiming = CaptureStopTiming()
    private var graceDeadlineNs: UInt64?
    private var awaitingGraceSignal = false
    private var prependedSampleCount = 0

    init(
        maxRecordingSamples: Int = AudioCapture.defaultMaxRecordingSamples,
        onLimitReached: (() -> Void)? = nil
    ) throws {
        self.maxRecordingSamples = maxRecordingSamples
        self.onLimitReached = onLimitReached

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate

        logger.debug("AudioCapture initialized (engine idle)")
    }

    func prepare() throws {
        let alreadyPrepared = stateLock.withLock { () -> Bool in
            if isPrepared {
                return true
            }
            isPrepared = true
            return false
        }
        guard !alreadyPrepared else {
            logger.debug("AudioCapture.prepare() called again — no-op")
            return
        }

        let inputNode = engine.inputNode
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: inputFormat
        ) { [weak self] pcmBuffer, _ in
            self?.handle(buffer: pcmBuffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stateLock.withLock { isPrepared = false }
            inputNode.removeTap(onBus: 0)
            logger.error("Failed to start engine: \(error.localizedDescription)")
            throw AudioCaptureError.engineStartFailed(error)
        }

        logger.info("AudioCapture engine armed and running (idle)")
    }

    func beginRecording() {
        drainGraceSignal()

        let preRoll = ringBuffer.readLast(Self.preRollSampleCount)

        stateLock.withLock {
            isRecording = true
            didReachLimit = false
            graceDeadlineNs = nil
            awaitingGraceSignal = false
            prependedSampleCount = preRoll.count
        }

        frontLock.withLock {
            frontBuffer.removeAll(keepingCapacity: true)
            frontBuffer.reserveCapacity(maxRecordingSamples)
            if !preRoll.isEmpty {
                frontBuffer.append(contentsOf: preRoll)
            }
        }

        backLock.withLock {
            backBuffer.removeAll(keepingCapacity: true)
            backBuffer.reserveCapacity(Self.flushThreshold * 2)
        }

        logger.info("Recording started with \(preRoll.count) preroll samples")
    }

    func endRecording() -> AudioCaptureResult {
        let grace = stopTimingLock.withLock { stopTiming.graceInterval() }
        let waitStartedAtNs = TranscriptionTrace.timestamp()
        let deadlineNs = waitStartedAtNs + UInt64(grace * 1_000_000_000)

        stateLock.withLock {
            isRecording = false
            graceDeadlineNs = deadlineNs
            awaitingGraceSignal = true
        }

        _ = graceSemaphore.wait(timeout: .now() + grace + Self.graceTimeoutPadding)

        let waitEndedAtNs = TranscriptionTrace.timestamp()
        let graceDurationMs = Double(waitEndedAtNs - waitStartedAtNs) / 1_000_000

        stateLock.withLock {
            graceDeadlineNs = nil
            awaitingGraceSignal = false
        }

        flushBackBuffer()

        let samples = frontLock.withLock { () -> ContiguousArray<Float> in
            var result = ContiguousArray<Float>()
            swap(&result, &frontBuffer)
            return result
        }

        let prependedCount = stateLock.withLock { () -> Int in
            let count = prependedSampleCount
            prependedSampleCount = 0
            return count
        }

        logger.debug(
            "Recording stopped with \(samples.count) samples (preroll=\(prependedCount), grace=\(graceDurationMs, format: .fixed(precision: 1))ms)"
        )

        return AudioCaptureResult(
            samples: samples,
            prependedSampleCount: prependedCount,
            graceDurationMs: graceDurationMs
        )
    }

    func shutdown() {
        let wasPrepared = stateLock.withLock { () -> Bool in
            let wasPrepared = isPrepared
            isPrepared = false
            isRecording = false
            graceDeadlineNs = nil
            awaitingGraceSignal = false
            prependedSampleCount = 0
            return wasPrepared
        }
        guard wasPrepared else {
            return
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        ringBuffer.clear()
        logger.info("AudioCapture engine shut down")
    }

    private func flushBackBuffer() {
        let pending = backLock.withLock { () -> ContiguousArray<Float> in
            guard !backBuffer.isEmpty else {
                return ContiguousArray()
            }
            var temp = ContiguousArray<Float>()
            swap(&temp, &backBuffer)
            return temp
        }

        guard !pending.isEmpty else {
            return
        }

        frontLock.withLock {
            frontBuffer.append(contentsOf: pending)
        }
    }

    private func handle(buffer pcmBuffer: AVAudioPCMBuffer) {
        stopTimingLock.withLock {
            stopTiming.recordCallback()
        }

        let requiredCapacity = AVAudioFrameCount(
            (Double(pcmBuffer.frameLength) * sampleRateRatio).rounded(.up)
        ) + 1

        guard let outputBuffer = ensureConversionBuffer(requiredCapacity: requiredCapacity) else {
            return
        }
        outputBuffer.frameLength = 0

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            logger.error("Audio conversion failed: \(String(describing: error))")
            return
        }

        guard
            let channelData = outputBuffer.floatChannelData,
            outputBuffer.frameLength > 0
        else {
            return
        }

        let channel = channelData[0]
        let count = Int(outputBuffer.frameLength)
        let samples = UnsafeBufferPointer(start: channel, count: count)
        ringBuffer.write(samples)

        let now = TranscriptionTrace.timestamp()
        var shouldAppend = false
        var shouldSignalGrace = false

        stateLock.withLock {
            if isRecording {
                shouldAppend = true
                return
            }

            if let graceDeadlineNs, awaitingGraceSignal {
                if now < graceDeadlineNs {
                    shouldAppend = true
                } else {
                    awaitingGraceSignal = false
                    self.graceDeadlineNs = nil
                    shouldSignalGrace = true
                }
            }
        }

        if shouldSignalGrace {
            graceSemaphore.signal()
        }

        guard shouldAppend else {
            return
        }

        var shouldFlush = false
        backLock.withLock {
            backBuffer.append(contentsOf: samples)
            shouldFlush = backBuffer.count >= Self.flushThreshold
        }

        var reachedLimit = false
        if shouldFlush {
            flushBackBuffer()
            let frontCount = frontLock.withLock { frontBuffer.count }
            reachedLimit = frontCount >= maxRecordingSamples
        }

        if reachedLimit {
            let shouldNotify = stateLock.withLock { () -> Bool in
                if didReachLimit {
                    return false
                }
                didReachLimit = true
                isRecording = false
                awaitingGraceSignal = false
                graceDeadlineNs = nil
                return true
            }

            if shouldNotify {
                graceSemaphore.signal()
                onLimitReached?()
            }
        }
    }

    private func ensureConversionBuffer(requiredCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let conversionBuffer, conversionBuffer.frameCapacity >= requiredCapacity {
            return conversionBuffer
        }

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: requiredCapacity
        ) else {
            return nil
        }

        self.conversionBuffer = conversionBuffer
        return conversionBuffer
    }

    private func drainGraceSignal() {
        while graceSemaphore.wait(timeout: .now()) == .success {}
    }
}
