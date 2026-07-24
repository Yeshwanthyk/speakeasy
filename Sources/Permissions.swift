import AppKit
import AVFoundation
import ApplicationServices
import Foundation

enum PermissionError: Error {
    case microphoneDenied
}

enum Permissions {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

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
}
