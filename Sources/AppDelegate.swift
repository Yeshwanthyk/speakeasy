import AppKit
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private var coordinator: AppCoordinator?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Permissions.requestMicrophoneAccess()
            } catch {
                presentError("Microphone access is required")
                return
            }

            do {
                let coordinator = try AppCoordinator()
                try coordinator.prepareCapture()
                self.coordinator = coordinator

                if let store = coordinator.transcriptStore {
                    self.menuBarController = MenuBarController(store: store, paster: coordinator.paster)
                }

                Task(priority: .utility) {
                    await coordinator.warmUpModel()
                }
            } catch {
                presentError("Failed to start: \(String(describing: error))")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    @MainActor private func presentError(_ message: String) {
        logger.error("\(message)")
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Speakeasy"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
