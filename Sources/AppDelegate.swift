import AppKit
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            do {
                try await Permissions.requestMicrophoneAccess()
            } catch {
                await MainActor.run { self?.presentError("Microphone access is required") }
                return
            }

            do {
                self?.coordinator = try AppCoordinator()
            } catch {
                await MainActor.run { self?.presentError("Failed to start: \(String(describing: error))") }
                return
            }
        }
    }

    @MainActor private func presentError(_ message: String) {
        logger.error("\(message)")

        let alert = NSAlert()
        alert.messageText = "Speakeasy"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
