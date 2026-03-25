import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)
    case notPrepared
}

final class AudioCapture {
    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let defaultMaxRecordingSamples = 16_000 * 60 * 6
    private static let flushThreshold = 8_000  // Flush back buffer every ~0.5s at 16kHz

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "audio")
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let sampleRateRatio: Double
    private let maxRecordingSamples: Int
    private let onLimitReached: (() -> Void)?

    // Double-buffering: back buffer accumulates samples from audio thread,
    // front buffer holds committed samples. Reduces lock contention.
    private let frontLock = UnfairLock()
    private let backLock = UnfairLock()
    private let stateLock = UnfairLock()

    private var frontBuffer = ContiguousArray<Float>()
    private var backBuffer = ContiguousArray<Float>()
    private var isRecording = false
    private var isPrepared = false
    private var conversionBuffer: AVAudioPCMBuffer?
    private var didReachLimit = false

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

    /// Arm the engine: install tap and start AVAudioEngine. Audio is discarded
    /// until `beginRecording()` is called. Call once at app startup.
    func prepare() throws {
        let alreadyPrepared = stateLock.withLock { () -> Bool in
            if isPrepared { return true }
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
            // Roll back prepared flag so caller can retry
            stateLock.withLock { isPrepared = false }
            inputNode.removeTap(onBus: 0)
            logger.error("Failed to start engine: \(error.localizedDescription)")
            throw AudioCaptureError.engineStartFailed(error)
        }

        logger.info("AudioCapture engine armed and running (idle)")
    }

    /// Begin capturing audio into buffers. Engine must already be prepared.
    func beginRecording() {
        stateLock.withLock {
            isRecording = true
            didReachLimit = false
        }

        frontLock.withLock {
            frontBuffer.removeAll(keepingCapacity: true)
            frontBuffer.reserveCapacity(maxRecordingSamples)
        }

        backLock.withLock {
            backBuffer.removeAll(keepingCapacity: true)
            backBuffer.reserveCapacity(Self.flushThreshold * 2)
        }

        logger.info("Recording started")
    }

    /// Stop capturing; flush and return all accumulated samples. Engine keeps running.
    func endRecording() -> ContiguousArray<Float> {
        stateLock.withLock {
            isRecording = false
        }

        // Flush any remaining samples from back buffer to front
        flushBackBuffer()

        let samples = frontLock.withLock { () -> ContiguousArray<Float> in
            var samples = ContiguousArray<Float>()
            swap(&samples, &frontBuffer)
            return samples
        }

        logger.debug("Recording stopped with \(samples.count) samples")
        return samples
    }

    /// Stop the engine and remove the tap. Call at app termination.
    func shutdown() {
        let wasPrepared = stateLock.withLock { () -> Bool in
            let was = isPrepared
            isPrepared = false
            isRecording = false
            return was
        }
        guard wasPrepared else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        logger.info("AudioCapture engine shut down")
    }

    /// Move accumulated samples from back buffer to front buffer.
    /// Called periodically from audio thread and on endRecording.
    private func flushBackBuffer() {
        let pending = backLock.withLock { () -> ContiguousArray<Float> in
            guard !backBuffer.isEmpty else { return ContiguousArray() }
            var temp = ContiguousArray<Float>()
            swap(&temp, &backBuffer)
            return temp
        }

        guard !pending.isEmpty else { return }

        frontLock.withLock {
            frontBuffer.append(contentsOf: pending)
        }
    }

    private func handle(buffer pcmBuffer: AVAudioPCMBuffer) {
        let shouldRecord = stateLock.withLock { isRecording }
        // When idle, drop incoming audio to prevent unbounded accumulation
        guard shouldRecord else { return }

        let requiredCapacity = AVAudioFrameCount(
            (Double(pcmBuffer.frameLength) * sampleRateRatio).rounded(.up)
        ) + 1

        let outputBuffer = ensureConversionBuffer(requiredCapacity: requiredCapacity)
        guard let outputBuffer else { return }
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
        else { return }

        let channel = channelData[0]
        let count = Int(outputBuffer.frameLength)
        var shouldFlush = false

        backLock.withLock {
            let samples = UnsafeBufferPointer(start: channel, count: count)
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
                if didReachLimit { return false }
                didReachLimit = true
                isRecording = false
                return true
            }

            if shouldNotify {
                onLimitReached?()
            }
        }
    }

    private func ensureConversionBuffer(
        requiredCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let conversionBuffer, conversionBuffer.frameCapacity >= requiredCapacity {
            return conversionBuffer
        }

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: requiredCapacity
        ) else { return nil }

        self.conversionBuffer = conversionBuffer
        return conversionBuffer
    }
}
