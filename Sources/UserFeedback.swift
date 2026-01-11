import AppKit
import Foundation

protocol UserFeedback {
    func error(_ message: String)
}

final class SystemFeedback: UserFeedback {
    func error(_ message: String) {
        DispatchQueue.main.async {
            NSSound.beep()
        }
    }
}
