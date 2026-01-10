import AppKit
import Foundation
import os

final class SoundPlayer {
    private let logger = Logger(subsystem: "com.wisp.app", category: "sound")
    private let startSound = SoundPlayer.loadSound(named: "Pop")
    private let stopSound = SoundPlayer.loadSound(named: "Tink")

    func playStart() {
        play(sound: startSound)
    }

    func playStop() {
        play(sound: stopSound)
    }

    private func play(sound: NSSound?) {
        if let sound {
            sound.play()
        } else {
            logger.debug("Falling back to system beep")
            NSSound.beep()
        }
    }

    private static func loadSound(named name: String) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        return NSSound(contentsOfFile: path, byReference: true)
    }
}
