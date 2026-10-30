import AppKit
import CoreAudio
import Foundation

/// A process that holds the microphone, attributed to its app.
struct MicrophoneClient: Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
}

/// Apps whose microphone use means a call.
enum MeetingApps {
    enum Kind: Equatable, Sendable {
        /// A dedicated call app: offer quickly.
        case callApp
        /// A browser may be on a call or recording a voice note: wait longer.
        case browser
    }

    private static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.skype.skype": "Skype",
        "com.around.Around": "Around",
        "co.teamtailor.tuple": "Tuple",
        "app.tuple.app": "Tuple",
        "com.loom.desktop": "Loom",
        "com.gather.Gather": "Gather"
    ]

    private static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera"
    ]

    /// Helper processes (e.g. "com.google.Chrome.helper") count as their app.
    static func classify(_ bundleIdentifier: String) -> (kind: Kind, appBundleIdentifier: String, name: String)? {
        for (table, kind) in [(callApps, Kind.callApp), (browsers, Kind.browser)] {
            for (identifier, name) in table
            where bundleIdentifier == identifier || bundleIdentifier.hasPrefix(identifier + ".") {
                return (kind, identifier, name)
            }
        }
        return nil
    }
}

/// Decides when to offer a meeting recording and when a recorded call ended.
///
/// - A call app must hold the microphone for 2 s, a browser for 20 s (voice
///   notes and dictation fields in a browser are not calls).
/// - Once offered, the same app is snoozed until it has been off the
///   microphone for 60 s.
/// - While recording a call, the app leaving the microphone for 3 s ends it.
/// - Observations more than 10 s apart (sleep, a stalled loop) restart the
///   stability run instead of counting the gap.
struct MeetingDetector {
    struct Timing: Equatable {
        var callAppStability: TimeInterval = 2
        var browserStability: TimeInterval = 20
        var snoozeAfterAbsence: TimeInterval = 60
        var endAfterAbsence: TimeInterval = 3
        var maximumObservationGap: TimeInterval = 10
    }

    enum Event: Equatable, Sendable {
        case offer(bundleIdentifier: String, name: String)
        case ended(bundleIdentifier: String)
    }

    var timing = Timing()
    private var firstSeen: [String: TimeInterval] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    private var snoozed: Set<String> = []
    private var lastObservation: TimeInterval?
    private var endedRecordingApp: String?

    /// `recordingApp` is the app a running recording belongs to, if any.
    mutating func observe(
        now: TimeInterval,
        clients: Set<MicrophoneClient>,
        isRecording: Bool,
        recordingApp: String?
    ) -> Event? {
        if let lastObservation, now - lastObservation > timing.maximumObservationGap {
            firstSeen = [:]
        }
        lastObservation = now

        var present: [String: (MeetingApps.Kind, String)] = [:]
        for client in clients {
            guard let match = MeetingApps.classify(client.bundleIdentifier) else { continue }
            present[match.appBundleIdentifier] = (match.kind, match.name)
        }
        for identifier in present.keys {
            if firstSeen[identifier] == nil { firstSeen[identifier] = now }
            lastSeen[identifier] = now
        }
        for identifier in Array(firstSeen.keys) where present[identifier] == nil {
            firstSeen[identifier] = nil
        }
        for identifier in snoozed {
            if let seen = lastSeen[identifier], present[identifier] == nil, now - seen >= timing.snoozeAfterAbsence {
                snoozed.remove(identifier)
            }
        }

        if isRecording, let recordingApp {
            if present[recordingApp] == nil,
               let seen = lastSeen[recordingApp],
               now - seen >= timing.endAfterAbsence,
               endedRecordingApp != recordingApp {
                endedRecordingApp = recordingApp
                return .ended(bundleIdentifier: recordingApp)
            }
            return nil
        }
        endedRecordingApp = nil
        guard !isRecording else { return nil }

        let ready = present
            .filter { identifier, entry in
                guard !snoozed.contains(identifier), let start = firstSeen[identifier] else { return false }
                let needed = entry.0 == .callApp ? timing.callAppStability : timing.browserStability
                return now - start >= needed
            }
            .sorted { lhs, rhs in
                // Prefer dedicated call apps over browsers, then a stable order.
                (lhs.value.0 == .callApp ? 0 : 1, lhs.key) < (rhs.value.0 == .callApp ? 0 : 1, rhs.key)
            }
        guard let (identifier, entry) = ready.first else { return nil }
        snoozed.insert(identifier)
        return .offer(bundleIdentifier: identifier, name: entry.1)
    }

    /// The user declined: keep the app snoozed for this call.
    mutating func snooze(_ bundleIdentifier: String) {
        snoozed.insert(bundleIdentifier)
    }
}

/// Lists apps currently reading the microphone through CoreAudio's process
/// objects (macOS 14.2+). Speakeasy itself is excluded, which matters
/// because its own capture engine runs while idle.
enum MicrophoneClientMonitor {
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func currentClients() -> Set<MicrophoneClient> {
        guard #available(macOS 14.2, *) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var clients: Set<MicrophoneClient> = []
        for process in processObjects() {
            guard isRunningInput(process),
                  let pid = pid(of: process), pid != ownPID else {
                continue
            }
            let bundleIdentifier = bundleID(of: process)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleIdentifier
            clients.insert(MicrophoneClient(bundleIdentifier: bundleIdentifier, name: name))
        }
        return clients
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    @available(macOS 14.2, *)
    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }
}
