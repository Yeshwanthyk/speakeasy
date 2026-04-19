import AppKit
import Foundation

enum UserFeedbackEvent: Equatable {
    case error(String)
}

protocol UserFeedback {
    func notify(event: UserFeedbackEvent)
}

final class SystemFeedback: UserFeedback {
    func notify(event: UserFeedbackEvent) {
        DispatchQueue.main.async {
            NSSound.beep()
        }
    }
}
