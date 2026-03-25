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
                let coordinator = try AppCoordinator()
                self?.coordinator = coordinator

                // Arm audio engine immediately so it's hot before first hotkey
                coordinator.prepareCapture()

                // Warm up model in background; blocks hotkey until complete
                Task.detached(priority: .utility) {
                    await coordinator.warmUpModel()
                }
            } catch {
                await MainActor.run { self?.presentError("Failed to start: \(String(describing: error))") }
                return
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
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
