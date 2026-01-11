import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)
}

final class AudioCapture {
    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let defaultMaxRecordingSamples = 16_000 * 60 * 6

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "audio")
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let sampleRateRatio: Double
    private let maxRecordingSamples: Int
    private let onLimitReached: (() -> Void)?

    private let bufferLock = UnfairLock()
    private let stateLock = UnfairLock()

    private var buffer = ContiguousArray<Float>()
    private var isRecording = false
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
            throw AudioCaptureError.engineStartFailed(error)
        }

        logger.debug("Audio engine started")
    }

    func start() {
        stateLock.withLock {
            isRecording = true
            didReachLimit = false
        }

        bufferLock.withLock {
            buffer.removeAll(keepingCapacity: true)
            buffer.reserveCapacity(maxRecordingSamples)
        }

        logger.debug("Recording started")
    }

    func stop() -> ContiguousArray<Float> {
        stateLock.withLock {
            isRecording = false
        }

        let samples = bufferLock.withLock { () -> ContiguousArray<Float> in
            var samples = ContiguousArray<Float>()
            swap(&samples, &buffer)
            return samples
        }

        logger.debug("Recording stopped with \(samples.count) samples")
        return samples
    }

    private func handle(buffer pcmBuffer: AVAudioPCMBuffer) {
        let shouldRecord = stateLock.withLock { isRecording }
        guard shouldRecord else {
            return
        }

        let requiredCapacity = AVAudioFrameCount(
            (Double(pcmBuffer.frameLength) * sampleRateRatio).rounded(.up)
        ) + 1

        let outputBuffer = ensureConversionBuffer(requiredCapacity: requiredCapacity)
        guard let outputBuffer else {
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
        var reachedLimit = false

        bufferLock.withLock {
            let samples = UnsafeBufferPointer(start: channel, count: count)
            reachedLimit = Self.appendSamples(
                buffer: &buffer,
                newSamples: samples,
                maxSamples: maxRecordingSamples
            )
        }

        if reachedLimit {
            let shouldNotify = stateLock.withLock { () -> Bool in
                if didReachLimit {
                    return false
                }
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
        ) else {
            return nil
        }

        self.conversionBuffer = conversionBuffer
        return conversionBuffer
    }

    @discardableResult
    static func appendSamples(
        buffer: inout ContiguousArray<Float>,
        newSamples: UnsafeBufferPointer<Float>,
        maxSamples: Int
    ) -> Bool {
        guard maxSamples > 0 else {
            return true
        }

        let remaining = maxSamples - buffer.count
        if remaining <= 0 {
            return true
        }

        let appendCount = min(remaining, newSamples.count)
        if appendCount > 0, let base = newSamples.baseAddress {
            buffer.append(contentsOf: UnsafeBufferPointer(start: base, count: appendCount))
        }

        return appendCount < newSamples.count
    }
}
