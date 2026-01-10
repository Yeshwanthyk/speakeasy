import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)
}

final class AudioCapture {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.wisp.app", category: "audio")
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let bufferLock = UnfairLock()
    private let stateLock = UnfairLock()
    private var buffer = ContiguousArray<Float>()
    private var isRecording = false

    init() throws {
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcmBuffer, _ in
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
        }

        bufferLock.withLock {
            buffer.removeAll(keepingCapacity: true)
            buffer.reserveCapacity(16000 * 30)
        }

        logger.debug("Recording started")
    }

    func stop() -> [Float] {
        stateLock.withLock {
            isRecording = false
        }

        let samples = bufferLock.withLock { () -> [Float] in
            let data = Array(buffer)
            buffer.removeAll(keepingCapacity: true)
            return data
        }

        logger.debug("Recording stopped with \(samples.count) samples")
        return samples
    }

    private func handle(buffer pcmBuffer: AVAudioPCMBuffer) {
        let shouldRecord = stateLock.withLock { isRecording }
        if !shouldRecord {
            return
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let targetCapacity = AVAudioFrameCount((Double(pcmBuffer.frameLength) * ratio).rounded(.up)) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            logger.error("Audio conversion failed: \(String(describing: error))")
            return
        }

        guard let channelData = convertedBuffer.floatChannelData else {
            return
        }

        let channel = channelData[0]
        let count = Int(convertedBuffer.frameLength)
        guard count > 0 else {
            return
        }

        bufferLock.withLock {
            buffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
    }
}
