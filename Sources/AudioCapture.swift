import AppKit
@preconcurrency import AVFoundation
import Foundation
import os

enum AudioCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case engineStartFailed(Error)
    case unavailable
}

enum AudioCaptureEvent: Equatable, Sendable {
    case recoveryStarted(interruptedRecording: Bool)
    case recoverySucceeded
    case recoveryFailed
}

protocol AudioInputNodeProtocol {
    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block tapBlock: @escaping AVAudioNodeTapBlock
    )
    func removeTap(onBus bus: AVAudioNodeBus)
}

protocol AudioEngineProtocol: AnyObject {
    var captureInputNode: AudioInputNodeProtocol { get }
    var isRunning: Bool { get }
    func prepare()
    func start() throws
    func stop()
}

extension AVAudioInputNode: AudioInputNodeProtocol {}

extension AVAudioEngine: AudioEngineProtocol {
    var captureInputNode: AudioInputNodeProtocol { inputNode }
}

struct AudioCaptureResult {
    let samples: ContiguousArray<Float>
    let prependedSampleCount: Int
    let graceDurationMs: Double
    let wasInterrupted: Bool

    init(
        samples: ContiguousArray<Float>,
        prependedSampleCount: Int,
        graceDurationMs: Double,
        wasInterrupted: Bool = false
    ) {
        self.samples = samples
        self.prependedSampleCount = prependedSampleCount
        self.graceDurationMs = graceDurationMs
        self.wasInterrupted = wasInterrupted
    }
}

final class AudioCapture: @unchecked Sendable {
    private final class ConversionContext {
        let generation: Int
        let inputFormat: AVAudioFormat
        let targetFormat: AVAudioFormat
        let converter: AVAudioConverter
        let sampleRateRatio: Double
        let recoveryAttempt: Int?
        let configuredRecoveryRevision: UInt64

        private let lock = UnfairLock()
        private var outputBuffer: AVAudioPCMBuffer?

        init(
            generation: Int,
            inputFormat: AVAudioFormat,
            targetFormat: AVAudioFormat,
            converter: AVAudioConverter,
            recoveryAttempt: Int?,
            configuredRecoveryRevision: UInt64
        ) {
            self.generation = generation
            self.inputFormat = inputFormat
            self.targetFormat = targetFormat
            self.converter = converter
            self.sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
            self.recoveryAttempt = recoveryAttempt
            self.configuredRecoveryRevision = configuredRecoveryRevision
        }

        func withConvertedSamples(
            from pcmBuffer: AVAudioPCMBuffer,
            _ body: (UnsafeBufferPointer<Float>) -> Void
        ) -> NSError? {
            lock.withLock {
                let requiredCapacity = AVAudioFrameCount(
                    (Double(pcmBuffer.frameLength) * sampleRateRatio).rounded(.up)
                ) + 1
                if outputBuffer == nil || (outputBuffer?.frameCapacity ?? 0) < requiredCapacity {
                    outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: targetFormat,
                        frameCapacity: requiredCapacity
                    )
                }
                guard let outputBuffer else {
                    return nil
                }
                outputBuffer.frameLength = 0

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return pcmBuffer
                }
                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
                if let error {
                    return error
                }

                guard let channelData = outputBuffer.floatChannelData,
                      outputBuffer.frameLength > 0 else {
                    return nil
                }
                body(UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(outputBuffer.frameLength)
                ))
                return nil
            }
        }
    }

    private enum LifecycleState {
        case stopped
        case starting(Int)
        case running(Int)
        case recovering(Int)
        case failed(Int)

        var generation: Int? {
            switch self {
            case .stopped:
                return nil
            case .starting(let generation),
                 .running(let generation),
                 .recovering(let generation),
                 .failed(let generation):
                return generation
            }
        }
    }

    private enum RecoveryTrigger: String, Sendable {
        case configurationChange = "configuration-change"
        case wake
        case staleCapture = "stale-capture"
    }

    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let defaultMaxRecordingSamples = 16_000 * 60 * 6
    private static let defaultCallbackFreshnessNs: UInt64 = 1_000_000_000
    private static let defaultFirstCallbackTimeout: TimeInterval = 2
    private static let maxAutomaticRecoveryAttempts = 3
    private static let recoveryRetryDelay: TimeInterval = 0.1
    private static let flushThreshold = 8_000
    private static let ringBufferCapacity = 16_000
    private static let preRollSampleCount = 6_400
    private static let graceTimeoutPadding: TimeInterval = 0.020

    private let engine: AudioEngineProtocol
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "audio")
    private let maxRecordingSamples: Int
    private let onLimitReached: (() -> Void)?
    private let onAwaitingGrace: (() -> Void)?
    private let lifecycleQueue: DispatchQueue
    private let notificationCenter: NotificationCenter
    private let wakeNotificationCenter: NotificationCenter
    private let clock: () -> UInt64
    private let callbackFreshnessNs: UInt64
    private let firstCallbackTimeout: TimeInterval
    private let ringBuffer = FloatRingBuffer(capacity: AudioCapture.ringBufferCapacity)
    private let graceSemaphore = DispatchSemaphore(value: 0)

    private let frontLock = UnfairLock()
    private let backLock = UnfairLock()
    private let stateLock = UnfairLock()
    private let stopTimingLock = UnfairLock()

    private var frontBuffer = ContiguousArray<Float>()
    private var backBuffer = ContiguousArray<Float>()
    private var isRecording = false
    private var recordingWasInterrupted = false
    private var lifecycleState: LifecycleState = .stopped
    private var nextGeneration = 0
    private var recoveryEnabled = false
    private var isShutdown = false
    private var recoveryWorkerScheduled = false
    private var pendingRecoveryTrigger: RecoveryTrigger?
    private var recoveryRequestRevision: UInt64 = 0
    private var lastSuccessfulCallbackNs: UInt64?
    private var captureEventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    private var didReachLimit = false
    private var stopTiming = CaptureStopTiming()
    private var graceDeadlineNs: UInt64?
    private var awaitingGraceSignal = false
    private var prependedSampleCount = 0

    // Accessed only from lifecycleQueue.
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        maxRecordingSamples: Int = AudioCapture.defaultMaxRecordingSamples,
        onLimitReached: (() -> Void)? = nil,
        engine: AudioEngineProtocol = AVAudioEngine(),
        onAwaitingGrace: (() -> Void)? = nil,
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.speakeasy.app.audio-lifecycle", qos: .userInitiated),
        notificationCenter: NotificationCenter = .default,
        wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        clock: @escaping () -> UInt64 = TranscriptionTrace.timestamp,
        callbackFreshnessNs: UInt64 = AudioCapture.defaultCallbackFreshnessNs,
        firstCallbackTimeout: TimeInterval = AudioCapture.defaultFirstCallbackTimeout
    ) throws {
        self.maxRecordingSamples = maxRecordingSamples
        self.onLimitReached = onLimitReached
        self.engine = engine
        self.onAwaitingGrace = onAwaitingGrace
        self.lifecycleQueue = lifecycleQueue
        self.notificationCenter = notificationCenter
        self.wakeNotificationCenter = wakeNotificationCenter
        self.clock = clock
        self.callbackFreshnessNs = callbackFreshnessNs
        self.firstCallbackTimeout = firstCallbackTimeout

        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.requestRecovery(trigger: .configurationChange)
        }
        wakeObserver = wakeNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.revalidateAfterWake()
        }

        logger.debug("AudioCapture initialized (engine idle)")
    }

    deinit {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        if let wakeObserver {
            wakeNotificationCenter.removeObserver(wakeObserver)
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioCaptureEvent) -> Void) {
        stateLock.withLock {
            captureEventHandler = handler
        }
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let shouldPrepare = stateLock.withLock { () -> Bool in
                guard !isShutdown else {
                    return false
                }
                recoveryEnabled = true
                switch lifecycleState {
                case .starting, .running, .recovering:
                    return false
                case .stopped, .failed:
                    return true
                }
            }

            guard shouldPrepare else {
                logger.debug("AudioCapture.prepare() called while capture is already active")
                return
            }

            let generation = nextLifecycleGeneration(recovering: false)
            do {
                try configureAndStartGraph(
                    generation: generation,
                    recoveryTrigger: nil,
                    recoveryAttempt: nil
                )
            } catch {
                logger.error("Failed to start engine: \(String(describing: error))")
                throw error
            }
        }
    }

    func beginRecording() throws {
        drainGraceSignal()

        let preRoll = ringBuffer.readLast(Self.preRollSampleCount)

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

        let now = clock()
        let callbackAgeNs = stateLock.withLock { () -> UInt64? in
            guard let lastSuccessfulCallbackNs, now >= lastSuccessfulCallbackNs else {
                return nil
            }
            return now - lastSuccessfulCallbackNs
        }
        let didBegin = stateLock.withLock { () -> Bool in
            guard case .running = lifecycleState,
                  !recoveryWorkerScheduled,
                  let callbackAgeNs,
                  callbackAgeNs <= callbackFreshnessNs else {
                return false
            }

            isRecording = true
            recordingWasInterrupted = false
            didReachLimit = false
            graceDeadlineNs = nil
            awaitingGraceSignal = false
            prependedSampleCount = preRoll.count
            return true
        }

        guard didBegin, engine.isRunning else {
            stateLock.withLock { isRecording = false }
            requestRecovery(trigger: .staleCapture)
            throw AudioCaptureError.unavailable
        }

        let callbackAgeMs = Double(callbackAgeNs ?? 0) / 1_000_000
        logger.info(
            "Recording started with \(preRoll.count) preroll samples; callback_age_ms=\(callbackAgeMs, format: .fixed(precision: 1))"
        )
    }

    func endRecording() -> AudioCaptureResult {
        let grace = stopTimingLock.withLock { stopTiming.graceInterval() }
        let waitStartedAtNs = clock()
        let deadlineNs = waitStartedAtNs + UInt64(grace * 1_000_000_000)

        stateLock.withLock {
            isRecording = false
            graceDeadlineNs = deadlineNs
            awaitingGraceSignal = true
        }

        onAwaitingGrace?()
        _ = graceSemaphore.wait(timeout: .now() + grace + Self.graceTimeoutPadding)

        let waitEndedAtNs = clock()
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

        let recordingMetadata = stateLock.withLock { () -> (prependedCount: Int, wasInterrupted: Bool) in
            let metadata = (prependedSampleCount, recordingWasInterrupted)
            prependedSampleCount = 0
            recordingWasInterrupted = false
            return metadata
        }

        logger.debug(
            "Recording stopped with \(samples.count) samples (preroll=\(recordingMetadata.prependedCount), grace=\(graceDurationMs, format: .fixed(precision: 1))ms, interrupted=\(recordingMetadata.wasInterrupted))"
        )

        return AudioCaptureResult(
            samples: samples,
            prependedSampleCount: recordingMetadata.prependedCount,
            graceDurationMs: graceDurationMs,
            wasInterrupted: recordingMetadata.wasInterrupted
        )
    }

    func shutdown() {
        var shouldSignalGrace = false
        let shouldShutdown = stateLock.withLock { () -> Bool in
            guard !isShutdown else {
                return false
            }

            isShutdown = true
            recoveryEnabled = false
            lifecycleState = .stopped
            recoveryWorkerScheduled = false
            pendingRecoveryTrigger = nil
            isRecording = false
            recordingWasInterrupted = false
            shouldSignalGrace = awaitingGraceSignal
            graceDeadlineNs = nil
            awaitingGraceSignal = false
            prependedSampleCount = 0
            return true
        }
        guard shouldShutdown else {
            return
        }

        if shouldSignalGrace {
            graceSemaphore.signal()
        }

        lifecycleQueue.sync {
            teardownGraph()
        }
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

    private func handle(buffer pcmBuffer: AVAudioPCMBuffer, context: ConversionContext) {
        let acceptsGeneration = stateLock.withLock {
            lifecycleState.generation == context.generation && !isShutdown
        }
        guard acceptsGeneration else {
            return
        }

        let conversionError = context.withConvertedSamples(from: pcmBuffer) { [weak self] samples in
            self?.consume(samples: samples, context: context)
        }
        if let conversionError {
            logger.error("Audio conversion failed: \(String(describing: conversionError))")
        }
    }

    private func consume(
        samples: UnsafeBufferPointer<Float>,
        context: ConversionContext
    ) {
        let now = clock()
        var becameReadyAfterRecovery = false
        var followUpRecovery: (generation: Int, trigger: RecoveryTrigger, attempt: Int)?
        var exhaustedRecoveryTrigger: RecoveryTrigger?

        let stillAcceptsGeneration = stateLock.withLock { () -> Bool in
            guard lifecycleState.generation == context.generation, !isShutdown else {
                return false
            }

            lastSuccessfulCallbackNs = now
            switch lifecycleState {
            case .starting:
                lifecycleState = .running(context.generation)

            case .recovering:
                if let pendingRecoveryTrigger,
                   context.configuredRecoveryRevision < recoveryRequestRevision {
                    let attempt = context.recoveryAttempt ?? 1
                    if attempt < Self.maxAutomaticRecoveryAttempts {
                        nextGeneration += 1
                        let followUpGeneration = nextGeneration
                        lifecycleState = .recovering(followUpGeneration)
                        lastSuccessfulCallbackNs = nil
                        self.pendingRecoveryTrigger = nil
                        followUpRecovery = (
                            generation: followUpGeneration,
                            trigger: pendingRecoveryTrigger,
                            attempt: attempt + 1
                        )
                    } else {
                        lifecycleState = .failed(context.generation)
                        lastSuccessfulCallbackNs = nil
                        exhaustedRecoveryTrigger = pendingRecoveryTrigger
                    }
                    return false
                }

                lifecycleState = .running(context.generation)
                becameReadyAfterRecovery = true

            case .running:
                break

            case .stopped, .failed:
                return false
            }
            return true
        }

        if let followUpRecovery {
            lifecycleQueue.async { [weak self] in
                self?.runRecoveryLoop(
                    initialGeneration: followUpRecovery.generation,
                    trigger: followUpRecovery.trigger,
                    attempt: followUpRecovery.attempt
                )
            }
            return
        }

        if let exhaustedRecoveryTrigger {
            let exhaustedGeneration = context.generation
            lifecycleQueue.async { [weak self] in
                guard let self else { return }
                self.teardownGraph()
                self.handleRecoveryAttemptFailure(
                    generation: exhaustedGeneration,
                    trigger: exhaustedRecoveryTrigger,
                    attempt: Self.maxAutomaticRecoveryAttempts
                )
            }
            return
        }

        guard stillAcceptsGeneration else {
            return
        }

        if becameReadyAfterRecovery {
            let generation = context.generation
            let recoveryAttempt = context.recoveryAttempt ?? 1
            let configuredRecoveryRevision = context.configuredRecoveryRevision
            lifecycleQueue.async { [weak self] in
                self?.completeRecoveryAfterCallback(
                    generation: generation,
                    attempt: recoveryAttempt,
                    configuredRecoveryRevision: configuredRecoveryRevision
                )
            }
        }

        stopTimingLock.withLock {
            stopTiming.recordCallback(timestampNs: now)
        }
        ringBuffer.write(samples)

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

    private func completeRecoveryAfterCallback(
        generation: Int,
        attempt: Int,
        configuredRecoveryRevision: UInt64
    ) {
        let engineStillRunning = engine.isRunning
        var retry: (generation: Int, trigger: RecoveryTrigger, attempt: Int, delay: TimeInterval)?
        var shouldEmitSuccess = false
        var shouldEmitFailure = false

        stateLock.withLock {
            guard case .running(let currentGeneration) = lifecycleState,
                  currentGeneration == generation,
                  recoveryWorkerScheduled,
                  recoveryEnabled,
                  !isShutdown else {
                return
            }

            let newerTrigger = pendingRecoveryTrigger
            let wasInvalidated = newerTrigger != nil
                && configuredRecoveryRevision < recoveryRequestRevision

            if wasInvalidated || !engineStillRunning {
                if attempt < Self.maxAutomaticRecoveryAttempts {
                    nextGeneration += 1
                    let retryGeneration = nextGeneration
                    let retryTrigger = newerTrigger ?? .staleCapture
                    lifecycleState = .recovering(retryGeneration)
                    lastSuccessfulCallbackNs = nil
                    pendingRecoveryTrigger = nil
                    retry = (
                        generation: retryGeneration,
                        trigger: retryTrigger,
                        attempt: attempt + 1,
                        delay: wasInvalidated ? 0 : Self.recoveryRetryDelay * Double(attempt)
                    )
                } else {
                    lifecycleState = .failed(generation)
                    lastSuccessfulCallbackNs = nil
                    pendingRecoveryTrigger = nil
                    recoveryWorkerScheduled = false
                    shouldEmitFailure = true
                }
            } else {
                pendingRecoveryTrigger = nil
                recoveryWorkerScheduled = false
                shouldEmitSuccess = true
            }
        }

        if let retry {
            logger.info(
                "Revalidating audio capture; trigger=\(retry.trigger.rawValue, privacy: .public), next_attempt=\(retry.attempt)"
            )
            if retry.delay == 0 {
                runRecoveryLoop(
                    initialGeneration: retry.generation,
                    trigger: retry.trigger,
                    attempt: retry.attempt
                )
            } else {
                lifecycleQueue.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
                    self?.runRecoveryLoop(
                        initialGeneration: retry.generation,
                        trigger: retry.trigger,
                        attempt: retry.attempt
                    )
                }
            }
        } else if shouldEmitFailure {
            logger.error("Audio capture recovery exhausted automatic retries after callback validation")
            emit(event: .recoveryFailed)
        } else if shouldEmitSuccess {
            logger.info("Audio capture recovery completed")
            emit(event: .recoverySucceeded)
        }
    }

    private func revalidateAfterWake() {
        let now = clock()
        let isHealthy = stateLock.withLock { () -> Bool in
            guard case .running = lifecycleState,
                  let lastSuccessfulCallbackNs,
                  now >= lastSuccessfulCallbackNs else {
                return false
            }
            return now - lastSuccessfulCallbackNs <= callbackFreshnessNs
        }

        guard isHealthy, engine.isRunning else {
            requestRecovery(trigger: .wake)
            return
        }

        logger.debug("Audio capture remained healthy after wake")
    }

    private func requestRecovery(trigger: RecoveryTrigger) {
        var shouldSchedule = false
        var interruptedRecording = false
        var shouldSignalGrace = false
        var generation = 0

        stateLock.withLock {
            guard recoveryEnabled, !isShutdown else {
                return
            }

            recoveryRequestRevision &+= 1
            interruptedRecording = isRecording || awaitingGraceSignal
            if interruptedRecording {
                recordingWasInterrupted = true
                isRecording = false
                shouldSignalGrace = awaitingGraceSignal
                awaitingGraceSignal = false
                graceDeadlineNs = nil
            }

            if recoveryWorkerScheduled {
                pendingRecoveryTrigger = trigger
                return
            }

            nextGeneration += 1
            generation = nextGeneration
            lifecycleState = .recovering(generation)
            lastSuccessfulCallbackNs = nil
            pendingRecoveryTrigger = nil
            recoveryWorkerScheduled = true
            shouldSchedule = true
        }

        if shouldSignalGrace {
            graceSemaphore.signal()
        }

        guard shouldSchedule else {
            return
        }

        let scheduledGeneration = generation
        let didInterruptRecording = interruptedRecording
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.emit(event: .recoveryStarted(interruptedRecording: didInterruptRecording))
            self.runRecoveryLoop(
                initialGeneration: scheduledGeneration,
                trigger: trigger,
                attempt: 1
            )
        }
    }

    private func runRecoveryLoop(
        initialGeneration: Int,
        trigger: RecoveryTrigger,
        attempt: Int
    ) {
        let shouldRun = stateLock.withLock {
            lifecycleState.generation == initialGeneration
                && recoveryWorkerScheduled
                && recoveryEnabled
                && !isShutdown
        }
        guard shouldRun else {
            return
        }

        logger.info(
            "Rebuilding audio capture graph; trigger=\(trigger.rawValue, privacy: .public), generation=\(initialGeneration), attempt=\(attempt)"
        )
        do {
            teardownGraph()
            clearCaptureBuffersForRecovery()
            try configureAndStartGraph(
                generation: initialGeneration,
                recoveryTrigger: trigger,
                recoveryAttempt: attempt
            )
        } catch {
            logger.error("Audio capture recovery attempt failed: \(String(describing: error), privacy: .public)")
            handleRecoveryAttemptFailure(
                generation: initialGeneration,
                trigger: trigger,
                attempt: attempt
            )
        }
    }

    private func handleRecoveryAttemptFailure(
        generation: Int,
        trigger: RecoveryTrigger,
        attempt: Int
    ) {
        var retry: (generation: Int, trigger: RecoveryTrigger, attempt: Int)?
        var shouldEmitFailure = false

        stateLock.withLock {
            guard lifecycleState.generation == generation,
                  recoveryWorkerScheduled,
                  recoveryEnabled,
                  !isShutdown else {
                return
            }

            if attempt < Self.maxAutomaticRecoveryAttempts {
                nextGeneration += 1
                let retryGeneration = nextGeneration
                let nextTrigger = pendingRecoveryTrigger ?? trigger
                lifecycleState = .recovering(retryGeneration)
                lastSuccessfulCallbackNs = nil
                pendingRecoveryTrigger = nil
                retry = (
                    generation: retryGeneration,
                    trigger: nextTrigger,
                    attempt: attempt + 1
                )
            } else {
                lifecycleState = .failed(generation)
                lastSuccessfulCallbackNs = nil
                pendingRecoveryTrigger = nil
                recoveryWorkerScheduled = false
                shouldEmitFailure = true
            }
        }

        if let retry {
            let delay = Self.recoveryRetryDelay * Double(attempt)
            logger.info(
                "Retrying audio capture recovery in \(delay, format: .fixed(precision: 1))s; next_attempt=\(retry.attempt)"
            )
            lifecycleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runRecoveryLoop(
                    initialGeneration: retry.generation,
                    trigger: retry.trigger,
                    attempt: retry.attempt
                )
            }
        } else if shouldEmitFailure {
            logger.error("Audio capture recovery exhausted automatic retries")
            emit(event: .recoveryFailed)
        }
    }

    private func nextLifecycleGeneration(recovering: Bool) -> Int {
        stateLock.withLock {
            nextGeneration += 1
            let generation = nextGeneration
            lifecycleState = recovering ? .recovering(generation) : .starting(generation)
            lastSuccessfulCallbackNs = nil
            return generation
        }
    }

    private func configureAndStartGraph(
        generation: Int,
        recoveryTrigger: RecoveryTrigger?,
        recoveryAttempt: Int?
    ) throws {
        let configuredRecoveryRevision = stateLock.withLock { () -> UInt64? in
            guard lifecycleState.generation == generation else {
                return nil
            }
            lifecycleState = recoveryTrigger == nil ? .starting(generation) : .recovering(generation)
            lastSuccessfulCallbackNs = nil
            return recoveryRequestRevision
        }
        guard let configuredRecoveryRevision else {
            return
        }

        let inputNode = engine.captureInputNode
        let newInputFormat = inputNode.inputFormat(forBus: 0)
        guard newInputFormat.sampleRate > 0, newInputFormat.channelCount > 0 else {
            markStartFailed(generation: generation)
            throw AudioCaptureError.formatUnavailable
        }
        guard let newTargetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            markStartFailed(generation: generation)
            throw AudioCaptureError.formatUnavailable
        }

        guard let newConverter = AVAudioConverter(from: newInputFormat, to: newTargetFormat) else {
            markStartFailed(generation: generation)
            throw AudioCaptureError.converterUnavailable
        }

        let context = ConversionContext(
            generation: generation,
            inputFormat: newInputFormat,
            targetFormat: newTargetFormat,
            converter: newConverter,
            recoveryAttempt: recoveryAttempt,
            configuredRecoveryRevision: configuredRecoveryRevision
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: newInputFormat
        ) { [weak self, context] pcmBuffer, _ in
            self?.handle(buffer: pcmBuffer, context: context)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownGraph()
            markStartFailed(generation: generation)
            throw AudioCaptureError.engineStartFailed(error)
        }

        logger.info(
            "Audio engine started; awaiting input callback generation=\(generation), sample_rate=\(newInputFormat.sampleRate, format: .fixed(precision: 0)), channels=\(newInputFormat.channelCount)"
        )
        scheduleFirstCallbackTimeout(
            generation: generation,
            recoveryTrigger: recoveryTrigger,
            recoveryAttempt: recoveryAttempt
        )
    }

    private func scheduleFirstCallbackTimeout(
        generation: Int,
        recoveryTrigger: RecoveryTrigger?,
        recoveryAttempt: Int?
    ) {
        lifecycleQueue.asyncAfter(deadline: .now() + firstCallbackTimeout) { [weak self] in
            guard let self else { return }

            let didTimeOut = self.stateLock.withLock { () -> Bool in
                guard self.lifecycleState.generation == generation else {
                    return false
                }
                switch self.lifecycleState {
                case .starting, .recovering:
                    self.lifecycleState = .failed(generation)
                    self.lastSuccessfulCallbackNs = nil
                    return true
                case .stopped, .running, .failed:
                    return false
                }
            }
            guard didTimeOut else {
                return
            }

            self.logger.error("Audio engine produced no input callback after start")
            self.teardownGraph()

            if let recoveryTrigger, let recoveryAttempt {
                self.handleRecoveryAttemptFailure(
                    generation: generation,
                    trigger: recoveryTrigger,
                    attempt: recoveryAttempt
                )
            } else {
                self.emit(event: .recoveryFailed)
            }
        }
    }

    private func markStartFailed(generation: Int) {
        stateLock.withLock {
            guard lifecycleState.generation == generation else {
                return
            }
            lifecycleState = .failed(generation)
            lastSuccessfulCallbackNs = nil
        }
    }

    private func teardownGraph() {
        engine.stop()
        if tapInstalled {
            engine.captureInputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func clearCaptureBuffersForRecovery() {
        ringBuffer.clear()
        frontLock.withLock {
            frontBuffer.removeAll(keepingCapacity: true)
        }
        backLock.withLock {
            backBuffer.removeAll(keepingCapacity: true)
        }
        stateLock.withLock {
            prependedSampleCount = 0
        }
    }

    private func emit(event: AudioCaptureEvent) {
        let handler = stateLock.withLock { captureEventHandler }
        handler?(event)
    }

    private func drainGraceSignal() {
        while graceSemaphore.wait(timeout: .now()) == .success {}
    }
}
