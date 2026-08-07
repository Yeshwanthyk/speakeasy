import AppKit
import ApplicationServices
import Foundation

/// Collects only transient, on-device writing context for the delivery target
/// captured by the coordinator. The service has no cache or persistence.
struct AppContextService: AppContextCollecting, Sendable {
    func collect(for application: TranscriptDeliveryApplication) async -> AppContext {
        let collectionTask = Task.detached(priority: .userInitiated) {
            Self.collectSynchronously(for: application)
        }
        return await withTaskCancellationHandler {
            await collectionTask.value
        } onCancel: {
            collectionTask.cancel()
        }
    }

    private static func collectSynchronously(
        for application: TranscriptDeliveryApplication
    ) -> AppContext {
        guard !Task.isCancelled,
            let runningApplication = NSRunningApplication(
                processIdentifier: application.processIdentifier
            ),
            !runningApplication.isTerminated,
            runningApplication.bundleIdentifier == application.bundleIdentifier
        else {
            return emptyContext(for: application)
        }

        let appName = runningApplication.localizedName
        let bundleIdentifier = runningApplication.bundleIdentifier
        guard !Task.isCancelled else { return emptyContext(for: application) }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windowTitle = focusedWindowTitle(from: appElement)
        guard !Task.isCancelled else { return emptyContext(for: application) }

        guard
            let focusedElement = accessibilityElement(
                from: appElement,
                attribute: kAXFocusedUIElementAttribute as CFString
            )
        else {
            return AppContext(
                processIdentifier: application.processIdentifier,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: nil,
                textBeforeCaret: nil
            )
        }

        // Read both security attributes before any content-bearing attribute.
        // Some ordinary text controls omit AXSubrole, so a missing subrole is
        // allowed; known secure roles and subroles always stop content capture.
        guard
            let role = accessibilityRawString(
                from: focusedElement,
                attribute: kAXRoleAttribute as CFString
            ),
            !Task.isCancelled
        else {
            return AppContext(
                processIdentifier: application.processIdentifier,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: nil,
                textBeforeCaret: nil
            )
        }
        let subrole = accessibilityRawString(
            from: focusedElement,
            attribute: kAXSubroleAttribute as CFString
        )
        guard !AppContextBounds.isSecure(role: role, subrole: subrole) else {
            return AppContext(
                processIdentifier: application.processIdentifier,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: nil,
                textBeforeCaret: nil
            )
        }

        let selectedText = AppContextBounds.selectedText(
            accessibilityRawString(
                from: focusedElement,
                attribute: kAXSelectedTextAttribute as CFString
            ),
            role: role,
            subrole: subrole
        )
        guard !Task.isCancelled else { return emptyContext(for: application) }

        let value = accessibilityRawString(
            from: focusedElement,
            attribute: kAXValueAttribute as CFString
        )
        let selectedRange = accessibilityRange(
            from: focusedElement,
            attribute: kAXSelectedTextRangeAttribute as CFString
        )
        let textBeforeCaret = AppContextBounds.textBeforeCaret(
            in: value,
            selectedRange: selectedRange,
            role: role,
            subrole: subrole
        )

        guard !Task.isCancelled else { return emptyContext(for: application) }
        return AppContext(
            processIdentifier: application.processIdentifier,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            textBeforeCaret: textBeforeCaret
        )
    }

    private static func emptyContext(
        for application: TranscriptDeliveryApplication
    ) -> AppContext {
        AppContext(
            processIdentifier: application.processIdentifier,
            appName: nil,
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: nil,
            selectedText: nil,
            textBeforeCaret: nil
        )
    }

    private static func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard
            let focusedWindow = accessibilityElement(
                from: appElement,
                attribute: kAXFocusedWindowAttribute as CFString
            ),
            let title = accessibilityRawString(
                from: focusedWindow,
                attribute: kAXTitleAttribute as CFString
            )
        else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func accessibilityElement(
        from element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let rawValue = value,
            CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private static func accessibilityRawString(
        from element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let stringValue = value as? String
        else {
            return nil
        }
        return stringValue.isEmpty ? nil : stringValue
    }

    private static func accessibilityRange(
        from element: AXUIElement,
        attribute: CFString
    ) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let rawValue = value,
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
}
