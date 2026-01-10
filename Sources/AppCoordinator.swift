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

    private let logger = Logger(subsystem: "com.wisp.app", category: "app")
    private let audioCapture: AudioCapture
    private let transcriber: ParakeetTranscriber
    private let paster = PasteboardPaster()
    private let stateLock = UnfairLock()
    private var state: State = .idle
    private let transcriptionQueue = DispatchQueue(label: "com.wisp.app.transcription", qos: .userInitiated)
    private let soundPlayer = SoundPlayer()
    private var keyMonitor: KeyComboMonitor?

    init() throws {
        let modelPath = try ModelPathResolver.parakeetV3Path()
        self.transcriber = try ParakeetTranscriber(modelPath: modelPath)
        self.audioCapture = try AudioCapture()

        let keyCode = CGKeyCode(kVK_ANSI_D)
        let requiredFlags: CGEventFlags = .maskAlternate
        let forbiddenFlags: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
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
            soundPlayer.playStart()
            audioCapture.start()
        case .stop:
            soundPlayer.playStop()
            stopAndTranscribe()
        case .ignore:
            logger.debug("Ignoring hotkey while transcribing")
        }
    }

    private func stopAndTranscribe() {
        let samples = audioCapture.stop()
        if samples.isEmpty {
            stateLock.withLock { state = .idle }
            return
        }

        transcriptionQueue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                let text = try self.transcriber.transcribe(samples: samples)
                if !text.isEmpty {
                    DispatchQueue.main.async {
                        if Permissions.ensureAccessibilityPrompted() {
                            self.paster.paste(text)
                        } else {
                            self.logger.error("Accessibility permission missing")
                        }
                    }
                }
            } catch {
                self.logger.error("Transcription failed: \(String(describing: error))")
            }

            self.stateLock.withLock { self.state = .idle }
        }
    }
}
