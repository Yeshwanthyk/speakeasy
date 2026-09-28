import AppKit
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let legacyBundleIdentifier = "com.wisp.app"

    private let logger = Logger(subsystem: "com.speakeasy.app", category: "app")
    private var coordinator: AppCoordinator?
    private var menuBarController: MenuBarController?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard await resolveDuplicateInstances() else {
                return
            }

            let needsOnboarding = OnboardingStore.needsOnboarding(
                isComplete: OnboardingStore.isComplete(),
                microphone: Permissions.microphoneState(),
                accessibility: Permissions.accessibilityState(),
                inputMonitoring: Permissions.inputMonitoringState()
            )
            if needsOnboarding {
                showOnboarding()
                return
            }

            do {
                let coordinator = try await startEngine()
                Task(priority: .utility) {
                    await coordinator.warmUpModel()
                }
            } catch {
                // A missing or corrupt model is recoverable from setup.
                logger.error("Startup failed; opening setup: \(String(describing: error))")
                showOnboarding()
            }
        }
    }

    /// Builds the dictation engine and menu bar item once. Onboarding and
    /// normal launch share this path.
    @MainActor
    private func startEngine() async throws -> AppCoordinator {
        if let coordinator { return coordinator }

        let feedback = SystemFeedback()
        let coordinator = try await AppCoordinator(feedback: feedback)
        try coordinator.prepareCapture()
        self.coordinator = coordinator
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in coordinator?.rewarmIfIdle() }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak coordinator] _ in coordinator?.rewarmIfIdle() }

            if let store = coordinator.transcriptStore {
                let menuBarController = MenuBarController(
                    store: store,
                    diagnosticsStore: coordinator.diagnosticsStore,
                    pasteTranscript: { [weak coordinator] text in
                        _ = coordinator?.pasteTranscript(text)
                    },
                    currentASRModelKind: { [weak coordinator] in
                        coordinator?.selectedASRModelKind() ?? .parakeet110M
                    },
                    selectASRModel: { [weak coordinator] kind in
                        coordinator?.switchASRModel(to: kind)
                    },
                    copyLastTranscript: { [weak coordinator] in
                        _ = coordinator?.copyLastTranscript()
                    },
                    pasteLastTranscript: { [weak coordinator] in
                        _ = coordinator?.pasteLastTranscript()
                    },
                    loadCorrections: { [weak coordinator] in
                        coordinator?.transcriptCorrections() ?? []
                    },
                    saveCorrections: { [weak coordinator] corrections in
                        guard let coordinator else { return false }
                        return try await coordinator.replaceTranscriptCorrections(corrections).value
                    },
                    currentInvocationMode: { [weak coordinator] in
                        coordinator?.selectedInvocationMode() ?? .toggle
                    },
                    selectInvocationMode: { [weak coordinator] mode in
                        coordinator?.setInvocationMode(mode)
                    },
                    currentDictationShortcut: { [weak coordinator] in
                        coordinator?.selectedDictationShortcut() ?? .defaultShortcut
                    },
                    setDictationShortcut: { [weak coordinator] shortcut in
                        coordinator?.setDictationShortcut(shortcut)
                            ?? .failure("Speakeasy is not ready to change shortcuts")
                    },
                    setShortcutCaptureActive: { [weak coordinator] isActive in
                        coordinator?.setShortcutCaptureActive(isActive)
                    },
                    canChangeDictationShortcut: { [weak coordinator] in
                        coordinator?.canChangeDictationShortcut() ?? false
                    },
                    cancelDictation: { [weak coordinator] in
                        coordinator?.handle(.cancel)
                    },
                    canCancelDictation: { [weak coordinator] in
                        coordinator?.canCancelDictation() ?? false
                    },
                    isRecording: { [weak coordinator] in
                        coordinator?.isRecording ?? false
                    },
                    retryLastFailedCapture: { [weak coordinator] in
                        coordinator?.retryLastFailedCapture()
                    },
                    discardFailedCapture: { [weak coordinator] in
                        coordinator?.discardFailedCapture()
                    },
                    canRetryFailedCapture: { [weak coordinator] in
                        coordinator?.canRetryFailedCapture() ?? false
                    },
                    canDiscardFailedCapture: { [weak coordinator] in
                        coordinator?.canDiscardFailedCapture() ?? false
                    },
                    availableInputDevices: { [weak coordinator] in
                        coordinator?.availableInputDevices() ?? []
                    },
                    selectedInputDeviceUID: {
                        MicrophoneSelectionStore.selectedUID()
                    },
                    selectInputDevice: { [weak coordinator] uid in
                        coordinator?.selectInputDevice(uid: uid)
                    },
                    canSelectInputDevice: { [weak coordinator] in
                        coordinator?.canSelectInputDevice() ?? false
                    },
                    microphoneLevelSnapshot: { [weak coordinator] in
                        coordinator?.microphoneLevelSnapshot() ?? MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0)
                    }
                )
                feedback.setPresenter { [weak menuBarController] event in
                    menuBarController?.showFeedback(event)
                }
                menuBarController.openSetupGuide = { [weak self] in self?.showOnboarding() }
                self.menuBarController = menuBarController
            }
        return coordinator
    }

    @MainActor
    private func showOnboarding() {
        if let onboardingController {
            onboardingController.present()
            return
        }

        let model = OnboardingModel(actions: .init(
            startEngine: { [weak self] in
                guard let self else { return false }
                return try await self.startEngine().warmUpModel()
            },
            latestTranscript: { [weak self] in
                self?.coordinator?.transcriptStore?.allRecords().last
            },
            currentShortcut: { [weak self] in
                self?.coordinator?.selectedDictationShortcut() ?? DictationShortcutStore.selected()
            },
            changeShortcut: { [weak self] in
                self?.menuBarController?.changeShortcut()
            },
            finish: { [weak self] in
                self?.onboardingController?.close()
            },
            relaunch: { [weak self] in
                self?.relaunch()
            }
        ))
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self] in
            guard let self else { return }
            model.stop()
            self.onboardingController = nil
            // Without an engine there is no menu bar item to return to.
            if self.coordinator == nil {
                NSApplication.shared.terminate(nil)
            }
        }
        onboardingController = controller
        model.start()
        controller.present()
    }

    /// Relaunch so macOS applies permission grants that only take effect for
    /// new processes.
    @MainActor
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            logger.error("Relaunch failed: \(String(describing: error))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        coordinator?.shutdown()
    }

    @MainActor
    private func resolveDuplicateInstances() async -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let current = AppInstanceSelector.Descriptor(
            pid: currentPID,
            bundleURL: Bundle.main.bundleURL
        )
        let bundleIdentifiers = [bundleIdentifier, Self.legacyBundleIdentifier]
        let othersByPID = bundleIdentifiers
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != currentPID }
            .reduce(into: [Int32: AppInstanceSelector.Descriptor]()) { result, application in
                result[application.processIdentifier] = AppInstanceSelector.Descriptor(
                    pid: application.processIdentifier,
                    bundleURL: application.bundleURL
                )
            }
        let others = Array(othersByPID.values)

        switch AppInstanceSelector.decide(current: current, others: others) {
        case .proceed:
            return true

        case .terminateSelf(let preferred):
            let path = preferred.bundleURL?.path ?? "another location"
            presentAndTerminate(message: "Speakeasy is already running from \(path). Quit that copy before launching another.")
            return false

        case .terminateOthers(let pids):
            for pid in pids {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }

            guard await waitForTermination(of: pids) else {
                presentAndTerminate(message: "Another Speakeasy copy is still running. Quit it, then relaunch Speakeasy from ~/Applications.")
                return false
            }

            return true
        }
    }

    private func waitForTermination(of pids: [Int32]) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let remaining = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            if remaining.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return pids.allSatisfy { NSRunningApplication(processIdentifier: $0) == nil }
    }

    @MainActor private func presentAndTerminate(message: String) {
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
