import Carbon
import CoreGraphics
import Foundation
import os

protocol AudioCapturing {
    func start()
    func stop() -> ContiguousArray<Float>
}

protocol Transcribing {
    func transcribe(samples: ContiguousArray<Float>) throws -> String
}

protocol Pasting {
    func paste(_ text: String)
}

protocol Flashing {
    func flash(duration: TimeInterval, lineWidth: CGFloat)
}

protocol TextCorrecting {
    func correct(_ text: String) -> String
}

protocol AccessibilityChecking {
    func ensureAccessibilityPrompted() -> Bool
}

typealias KeyMonitorFactory = (_ callback: @escaping () -> Void) -> KeyComboMonitor?

extension AudioCapture: AudioCapturing {}
extension ScreenEdgeFlash: Flashing {}
extension WordCorrector: TextCorrecting {}

#if !SWIFT_PACKAGE
extension ParakeetTranscriber: Transcribing {}
#endif

struct SystemAccessibilityChecker: AccessibilityChecking {
    func ensureAccessibilityPrompted() -> Bool {
        Permissions.ensureAccessibilityPrompted()
    }
}

final class AppCoordinator {
    private enum State {
        case idle
        case recording
        case transcribing(UUID)
    }

    private enum Transition {
        case start
        case stop(UUID)
        case ignore
    }

    private static let flashDuration: TimeInterval = 0.18
    private static let flashLineWidth: CGFloat = 3
    private static let transcriptionSampleRate: Double = 16_000
    private static let minTranscriptionTimeout: TimeInterval = 30
    private static let maxTranscriptionTimeout: TimeInterval = 600

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private let audioCapture: AudioCapturing
    private let transcriber: Transcribing
    private let paster: Pasting
    private let feedback: UserFeedback
    private let textCorrector: TextCorrecting
    private let accessibilityChecker: AccessibilityChecking
    private let transcriptionTimeoutProvider: (ContiguousArray<Float>) -> TimeInterval
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private let transcriptionQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInitiated)
    private let flash: Flashing
    private var keyMonitor: KeyComboMonitor?

    init(
        audioCapture: AudioCapturing,
        transcriber: Transcribing,
        paster: Pasting,
        flash: Flashing,
        feedback: UserFeedback,
        textCorrector: TextCorrecting,
        accessibilityChecker: AccessibilityChecking,
        transcriptionTimeoutProvider: @escaping (ContiguousArray<Float>) -> TimeInterval,
        keyMonitorFactory: KeyMonitorFactory?
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.paster = paster
        self.flash = flash
        self.feedback = feedback
        self.textCorrector = textCorrector
        self.accessibilityChecker = accessibilityChecker
        self.transcriptionTimeoutProvider = transcriptionTimeoutProvider

        keyMonitor = keyMonitorFactory? { [weak self] in
            self?.toggleRecording()
        }

        logger.debug("AppCoordinator ready")
    }

    #if !SWIFT_PACKAGE
    convenience init() throws {
        let modelPath = try ModelPathResolver.parakeetV3Path()
        let feedback = SystemFeedback()
        let audioCapture = try AudioCapture(
            onLimitReached: { [feedback] in
                feedback.error("Recording limit reached (6 minutes)")
            }
        )
        let transcriber = try ParakeetTranscriber(modelPath: modelPath)
        let paster = PasteboardPaster(feedback: feedback)
        let flash = ScreenEdgeFlash()

        let keyCode = CGKeyCode(kVK_ANSI_S)
        let requiredFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let forbiddenFlags: CGEventFlags = []
        let keyMonitorFactory: KeyMonitorFactory = { callback in
            KeyComboMonitor(
                keyCode: keyCode,
                requiredFlags: requiredFlags,
                forbiddenFlags: forbiddenFlags,
                callback: callback
            )
        }

        self.init(
            audioCapture: audioCapture,
            transcriber: transcriber,
            paster: paster,
            flash: flash,
            feedback: feedback,
            textCorrector: WordCorrector.shared,
            accessibilityChecker: SystemAccessibilityChecker(),
            transcriptionTimeoutProvider: Self.defaultTranscriptionTimeout,
            keyMonitorFactory: keyMonitorFactory
        )
    }
    #endif

    func toggleRecording() {
        let transition = stateLock.withLock { () -> Transition in
            switch state {
            case .idle:
                state = .recording
                return .start
            case .recording:
                let token = UUID()
                state = .transcribing(token)
                return .stop(token)
            case .transcribing(_):
                return .ignore
            }
        }

        switch transition {
        case .start:
            audioCapture.start()
        case .stop(let token):
            DispatchQueue.main.async { [flash] in
                flash.flash(duration: Self.flashDuration, lineWidth: Self.flashLineWidth)
            }
            stopAndTranscribe(token: token)
        case .ignore:
            logger.debug("Ignoring hotkey while transcribing")
        }
    }

    private func stopAndTranscribe(token: UUID) {
        let samples = audioCapture.stop()
        guard !samples.isEmpty else {
            finishTranscription(token: token)
            return
        }

        let timeout = transcriptionTimeoutProvider(samples)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTranscriptionTimeout(token: token, timeout: timeout)
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        transcriptionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let result: Result<String, Error>
            do {
                let text = try self.transcriber.transcribe(samples: samples)
                result = .success(text)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                guard self.isCurrentTranscription(token: token) else {
                    return
                }

                timeoutWorkItem.cancel()
                self.finishTranscription(token: token)

                switch result {
                case .success(let text):
                    self.handleTranscriptionResult(text)
                case .failure(let error):
                    self.logger.error("Transcription failed: \(String(describing: error))")
                    self.feedback.error("Transcription failed")
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        let corrected = textCorrector.correct(text)
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feedback.error("No speech detected")
            return
        }

        if accessibilityChecker.ensureAccessibilityPrompted() {
            paster.paste(trimmed)
        } else {
            logger.error("Accessibility permission missing")
            feedback.error("Accessibility permission required")
        }
    }

    private func isCurrentTranscription(token: UUID) -> Bool {
        stateLock.withLock {
            if case let .transcribing(current) = state {
                return current == token
            }
            return false
        }
    }

    private func finishTranscription(token: UUID) {
        stateLock.withLock {
            if case let .transcribing(current) = state, current == token {
                state = .idle
            }
        }
    }

    private func handleTranscriptionTimeout(token: UUID, timeout: TimeInterval) {
        let shouldNotify = stateLock.withLock { () -> Bool in
            if case let .transcribing(current) = state, current == token {
                state = .idle
                return true
            }
            return false
        }

        guard shouldNotify else {
            return
        }

        logger.error("Transcription timed out after \(timeout)s")
        feedback.error("Transcription timed out")
    }

    private static func defaultTranscriptionTimeout(
        samples: ContiguousArray<Float>
    ) -> TimeInterval {
        let duration = Double(samples.count) / transcriptionSampleRate
        let scaled = max(duration * 2, minTranscriptionTimeout)
        return min(scaled, maxTranscriptionTimeout)
    }
}
