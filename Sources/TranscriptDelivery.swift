import AppKit
import Foundation

struct TranscriptDeliveryApplication: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String

    init(processIdentifier: Int32, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

enum TranscriptDeliveryTarget: Equatable, Sendable {
    case external(TranscriptDeliveryApplication)
    case unavailable
    case speakeasy
    case unsupported
}

protocol DeliveryTargetProviding {
    func currentTarget() -> TranscriptDeliveryTarget
    func isRunning(_ application: TranscriptDeliveryApplication) -> Bool
}

struct SystemDeliveryTargetProvider: DeliveryTargetProviding {
    private let processIdentifier: Int32
    private let bundleIdentifier: String?

    init(
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    func currentTarget() -> TranscriptDeliveryTarget {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .unavailable
        }

        let isSpeakeasy = application.processIdentifier == processIdentifier
            || (bundleIdentifier != nil && application.bundleIdentifier == bundleIdentifier)
        if isSpeakeasy {
            return .speakeasy
        }

        guard let applicationBundleIdentifier = application.bundleIdentifier,
              !applicationBundleIdentifier.isEmpty else {
            return .unsupported
        }

        return .external(
            TranscriptDeliveryApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: applicationBundleIdentifier
            )
        )
    }

    func isRunning(_ application: TranscriptDeliveryApplication) -> Bool {
        guard let runningApplication = NSRunningApplication(
            processIdentifier: application.processIdentifier
        ) else {
            return false
        }
        return !runningApplication.isTerminated
    }
}

struct PasteboardRepresentationSnapshot: Equatable, Sendable {
    let type: String
    let data: Data
}

struct PasteboardItemSnapshot: Equatable, Sendable {
    let representations: [PasteboardRepresentationSnapshot]
}

struct PasteboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItemSnapshot]
}

protocol PasteboardAccess {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot?
    func write(string: String) -> Bool
    func string() -> String?
    func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

final class SystemPasteboardAccess: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> PasteboardSnapshot? {
        let items = pasteboard.pasteboardItems ?? []
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(items.count)

        for item in items {
            var representations: [PasteboardRepresentationSnapshot] = []
            representations.reserveCapacity(item.types.count)
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                representations.append(
                    PasteboardRepresentationSnapshot(type: type.rawValue, data: data)
                )
            }
            snapshots.append(PasteboardItemSnapshot(representations: representations))
        }

        return PasteboardSnapshot(items: snapshots)
    }

    func write(string: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        pasteboard.clearContents()
        let items = snapshot.items.map { itemSnapshot in
            let item = NSPasteboardItem()
            for representation in itemSnapshot.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(rawValue: representation.type)
                )
            }
            return item
        }

        guard !items.isEmpty else {
            return pasteboard.pasteboardItems?.isEmpty ?? true
        }
        return pasteboard.writeObjects(items)
    }
}

/// The furthest delivery boundary reached by a clipboard or paste operation.
///
/// `eventsPosted` means that Speakeasy posted the synthetic Command-V events.
/// macOS provides no acknowledgement that the frontmost application inserted
/// the clipboard contents, so this is intentionally not named `pasted`.
enum TranscriptDeliveryOutcome: String, Equatable, Sendable {
    case clipboardWriteFailed
    case clipboardUpdated
    case eventsPosted

    var traceOutcome: TranscriptionTrace.Outcome {
        switch self {
        case .clipboardWriteFailed:
            return .clipboardWriteFailed
        case .clipboardUpdated:
            return .clipboardUpdated
        case .eventsPosted:
            return .eventsPosted
        }
    }
}
