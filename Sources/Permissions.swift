import AppKit
import AVFoundation
import ApplicationServices
import Foundation

enum PermissionError: Error {
    case microphoneDenied
}

/// Authorization state shown to the user; the system APIs are authoritative.
enum PermissionState: Equatable {
    case granted
    case notDetermined
    case denied
}

enum Permissions {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    // Observed System Settings anchors; not a documented API, so the UI also
    // shows the manual path.
    static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!
    static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
    static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.keyboard"
    )!

    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func accessibilityState() -> PermissionState {
        hasAccessibilityAccess() ? .granted : .denied
    }

    /// Input Monitoring lets the global keyboard monitor see the shortcut
    /// while another app is frontmost.
    static func inputMonitoringState() -> PermissionState {
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    /// Clears a stale Input Monitoring entry (for example one recorded for an
    /// older signature of the app, which System Settings still shows as on)
    /// so macOS prompts again for this build.
    static func resetInputMonitoring() async -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ListenEvent", bundleIdentifier]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    /// Shows the system prompt the first time and registers Speakeasy in the
    /// Input Monitoring list; later calls return the current grant.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func requestMicrophoneAccess() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { value in
                    continuation.resume(returning: value)
                }
            }
            if granted {
                return
            }
            throw PermissionError.microphoneDenied
        default:
            throw PermissionError.microphoneDenied
        }
    }

    static func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func ensureAccessibilityPrompted() -> Bool {
        if hasAccessibilityAccess() {
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(microphoneSettingsURL)
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(inputMonitoringSettingsURL)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(keyboardSettingsURL)
    }
}
