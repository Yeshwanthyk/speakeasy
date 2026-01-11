import Carbon
import CoreGraphics
import Foundation
import os

final class AppCoordinator {
    private enum State {
        case idle
        case recording
        case transcribing
    }

    private enum Transition {
        case start
        case stop
        case ignore
    }

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private let audioCapture: AudioCapture
    private let transcriber: ParakeetTranscriber
    private let paster = PasteboardPaster()
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private let transcriptionQueue = DispatchQueue(label: "com.speakeasy.app.transcription", qos: .userInitiated)
    private let flash = ScreenEdgeFlash()
    private var keyMonitor: KeyComboMonitor?

    init() throws {
        let modelPath = try ModelPathResolver.parakeetV3Path()
        self.transcriber = try ParakeetTranscriber(modelPath: modelPath)
        self.audioCapture = try AudioCapture()

        let keyCode = CGKeyCode(kVK_ANSI_S)
        let requiredFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let forbiddenFlags: CGEventFlags = []
        keyMonitor = KeyComboMonitor(
            keyCode: keyCode,
            requiredFlags: requiredFlags,
            forbiddenFlags: forbiddenFlags
        ) { [weak self] in
            self?.toggleRecording()
        }

        logger.debug("AppCoordinator ready")
    }

    func toggleRecording() {
        let transition = stateLock.withLock { () -> Transition in
            switch state {
            case .idle:
                state = .recording
                return .start
            case .recording:
                state = .transcribing
                return .stop
            case .transcribing:
                return .ignore
            }
        }

        switch transition {
        case .start:
            audioCapture.start()
        case .stop:
            DispatchQueue.main.async { [flash] in
                flash.flash()
            }
            stopAndTranscribe()
        case .ignore:
            logger.debug("Ignoring hotkey while transcribing")
        }
    }

    private func stopAndTranscribe() {
        let samples = audioCapture.stop()
        guard !samples.isEmpty else {
            stateLock.withLock { state = .idle }
            return
        }

        transcriptionQueue.async { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.stateLock.withLock { self.state = .idle }
            }

            let text: String
            do {
                text = try self.transcriber.transcribe(samples: samples)
            } catch {
                self.logger.error("Transcription failed: \(String(describing: error))")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                guard !text.isEmpty else {
                    return
                }

                if Permissions.ensureAccessibilityPrompted() {
                    self.paster.paste(text)
                } else {
                    self.logger.error("Accessibility permission missing")
                }
            }
        }
    }
}
