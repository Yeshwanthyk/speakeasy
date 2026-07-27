import AppKit
import Foundation
import os

enum UserFeedbackEvent: Equatable, Sendable {
    case status(String)
    case error(String)

    var message: String {
        switch self {
        case .status(let message), .error(let message):
            return message
        }
    }
}

protocol UserFeedback {
    func notify(event: UserFeedbackEvent)
}

final class SystemFeedback: UserFeedback {
    typealias Presenter = @MainActor @Sendable (UserFeedbackEvent) -> Void

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "feedback")
    private let lock = UnfairLock()
    private var presenter: Presenter?

    func setPresenter(_ presenter: @escaping Presenter) {
        lock.withLock {
            self.presenter = presenter
        }
    }

    func notify(event: UserFeedbackEvent) {
        switch event {
        case .status(let message):
            logger.info("\(message, privacy: .public)")
        case .error(let message):
            logger.error("\(message, privacy: .public)")
        }

        let currentPresenter: Presenter? = lock.withLock { self.presenter }
        DispatchQueue.main.async {
            currentPresenter?(event)
            if case .error = event {
                NSSound.beep()
            }
        }
    }
}
