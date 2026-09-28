// Desktop end-to-end driver for the installed Speakeasy.app.
//
// Drives the real app launched through LaunchServices with SPEAKEASY_E2E_AUDIO,
// the real fn shortcut (synthesized CGEvents), the real overlay (read through
// Accessibility), and a real paste into the Apple Note named "Test Audio".
//
// Usage: e2e_driver --check
//        e2e_driver <cases.json> <max-wer>
import AppKit
import ApplicationServices
import Foundation

// MARK: - Configuration

struct Case: Decodable {
    let name: String
    let audio: String
    let reference: String
    let seconds: Double
    let cancel: Bool
    let minimumSegments: Int
    let assertNoAutoStopAfter: Double?
}

let bundleID = "com.speakeasy.app"
let appURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Speakeasy.app")
let traceURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/com.speakeasy.app/logs/dictation-e2e.jsonl")
let noteName = "Test Audio"
/// The note as found: a title line and an empty body line. Restored after each case.
let noteBaseline = "<div><h1>Test Audio</h1></div><div><br></div>"
let requiredTraceFields = [
    "id", "recorded_at", "backend", "outcome", "succeeded", "utterance_ms",
    "press_to_capture_start_ms", "release_to_stop_return_ms", "stop_return_to_transcription_start_ms",
    "transcription_ms", "transcription_end_to_paste_request_ms", "release_to_paste_request_ms",
    "delivered_character_count", "segment_count", "committed_audio_seconds", "tail_seconds", "segment_wait_ms",
]

func log(_ message: String) {
    let stamp = String(format: "%7.1f", Date().timeIntervalSince(startedAt))
    FileHandle.standardError.write("[\(stamp)s] \(message)\n".data(using: .utf8)!)
}
let startedAt = Date()

struct Failure: Error, CustomStringConvertible { let description: String }
struct SetupFailure: Error, CustomStringConvertible { let description: String }

// MARK: - AppleScript (Notes)

@discardableResult
func appleScript(_ source: String) throws -> String {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { throw Failure(description: "bad AppleScript") }
    let result = script.executeAndReturnError(&error)
    if let error {
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
        throw Failure(description: "AppleScript error \(number): \(message)")
    }
    return result.stringValue ?? ""
}

func notesQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

struct Note {
    let id: String
    var ref: String { "note id \(notesQuote(id))" }

    func plaintext() throws -> String {
        try appleScript("tell application \"Notes\" to return plaintext of \(ref)")
    }

    /// Dictated text: everything after the title line.
    func dictated() throws -> String {
        let lines = try plaintext().components(separatedBy: .newlines)
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reset() throws {
        // `set body to ""` renames the note ("New Note"), because Notes derives
        // the name from the first line; the title-only baseline keeps its name.
        try appleScript("tell application \"Notes\" to set body of \(ref) to \(notesQuote(noteBaseline))")
        let name = try appleScript("tell application \"Notes\" to return name of \(ref)")
        guard name == noteName else { throw Failure(description: "note renamed to \(name)") }
    }

    func showAndActivate() throws {
        try appleScript("tell application \"Notes\"\nshow \(ref)\nactivate\nend tell")
    }
}

func findTestNote() throws -> Note {
    let ids = try appleScript("""
        tell application "Notes"
        set out to ""
        repeat with n in (every note whose name is \(notesQuote(noteName)))
        set out to out & (id of n) & linefeed
        end repeat
        return out
        end tell
        """).split(separator: "\n").map(String.init)
    guard ids.count == 1 else {
        throw Failure(description: "expected exactly one note named \"\(noteName)\", found \(ids.count)")
    }
    return Note(id: ids[0])
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else {
        return nil
    }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func descendants(_ element: AXUIElement, role: String, depth: Int = 0, into result: inout [AXUIElement]) {
    guard depth < 30 else { return }
    for child in children(element) {
        if attribute(child, kAXRoleAttribute) as? String == role { result.append(child) }
        descendants(child, role: role, depth: depth + 1, into: &result)
    }
}

struct OverlaySample {
    let time: TimeInterval
    let windowFrame: CGRect
    let text: String?
    let textFrame: CGRect?
}

/// The bottom overlay: Speakeasy's only window, a fixed-height borderless panel.
func readOverlay(pid: pid_t, at time: TimeInterval) -> OverlaySample? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.4)
    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for window in windows {
        guard let windowFrame = frame(window), windowFrame.height < 200, windowFrame.width <= 480 else { continue }
        var texts: [AXUIElement] = []
        descendants(window, role: kAXStaticTextRole, into: &texts)
        // The transcript Text spans the full row, so it is the widest one.
        let transcript = texts.compactMap { element -> (String, CGRect)? in
            guard let value = attribute(element, kAXValueAttribute) as? String ?? attribute(element, kAXDescriptionAttribute) as? String,
                  let rect = frame(element) else { return nil }
            return (value, rect)
        }.max { $0.1.width < $1.1.width }
        return OverlaySample(time: time, windowFrame: windowFrame, text: transcript?.0, textFrame: transcript?.1)
    }
    return nil
}

func placeCaretInNoteBody() throws {
    guard let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else {
        throw Failure(description: "Notes is not running")
    }
    let app = AXUIElementCreateApplication(notes.processIdentifier)
    guard let window = attribute(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else {
        throw Failure(description: "Notes has no focused window")
    }
    var areas: [AXUIElement] = []
    descendants(window, role: kAXTextAreaRole, into: &areas)
    guard let editor = areas.first(where: { (attribute($0, kAXValueAttribute) as? String)?.hasPrefix(noteName) == true }) else {
        throw Failure(description: "could not find the \"\(noteName)\" editor through Accessibility")
    }
    AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let length = (attribute(editor, kAXValueAttribute) as? String)?.utf16.count ?? 0
    var range = CFRange(location: length, length: 0)
    guard let value = AXValueCreate(.cfRange, &range),
          AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
        throw Failure(description: "could not place the caret in the note body")
    }
}

/// Status-item menu → "Cancel Recording" (the menu path of the real cancel intent).
func cancelThroughMenu(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let extras = attribute(app, "AXExtrasMenuBar").map({ $0 as! AXUIElement }),
          let item = children(extras).first else { return false }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    for _ in 0..<20 {
        usleep(100_000)
        var entries: [AXUIElement] = []
        descendants(item, role: kAXMenuItemRole, into: &entries)
        if let cancel = entries.first(where: { attribute($0, kAXTitleAttribute) as? String == "Cancel Recording" }) {
            return AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success
        }
    }
    postKey(53) // close the menu
    return false
}

// MARK: - Keyboard

func postFn() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: down) else { continue }
        event.type = .flagsChanged
        event.flags = down ? [.maskSecondaryFn, .maskNonCoalesced] : [.maskNonCoalesced]
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func postKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

// MARK: - OSLog stream

final class LogStream: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var lines: [(Date, String)] = []
    private var partial = ""

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--level", "info",
                             "--predicate", "subsystem == \"\(bundleID)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let chunk = String(data: handle.availableData, encoding: .utf8) else { return }
            lock.lock()
            partial += chunk
            var parts = partial.components(separatedBy: "\n")
            partial = parts.removeLast()
            let now = Date()
            lines.append(contentsOf: parts.map { (now, $0) })
            lock.unlock()
        }
        try process.run()
        Thread.sleep(forTimeInterval: 1)
    }

    func lines(since: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.0 >= since }.map(\.1)
    }

    func wait(for needle: String, since: Date, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lines(since: since).first(where: { $0.contains(needle) }) { return line }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    func stop() { process.terminate() }
}

// MARK: - Process helpers

func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func runningSpeakeasy() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

func quitSpeakeasy() {
    for app in runningSpeakeasy() { app.terminate() }
    for _ in 0..<50 where !runningSpeakeasy().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
    for app in runningSpeakeasy() { app.forceTerminate() }
    for _ in 0..<30 where !runningSpeakeasy().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
}

func launch(environment: [String: String]?) throws -> NSRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    if let environment {
        configuration.environment = environment
        configuration.createsNewApplicationInstance = true
    }
    let done = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        launched = app
        launchError = error
        done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success else { throw Failure(description: "launch timed out") }
    if let launchError { throw launchError }
    guard let launched else { throw Failure(description: "launch returned no application") }
    return launched
}

// MARK: - Traces and scoring

func traceRecords() -> [[String: Any]] {
    guard let text = try? String(contentsOf: traceURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}

func traceIDs() -> Set<String> {
    Set(traceRecords().compactMap { $0["id"] as? String })
}

func waitForNewTrace(excluding known: Set<String>, timeout: TimeInterval) -> [String: Any]? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let record = traceRecords().last(where: { !known.contains($0["id"] as? String ?? "") }) { return record }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

/// Same lexical normalization as speech-bench's `wer-en-v1`.
func words(_ text: String) -> [String] {
    let normalized = text.precomposedStringWithCompatibilityMapping
        .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    let cleaned = String(normalized.map { $0 == "'" || !$0.isPunctuation ? $0 : " " }).lowercased()
    return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
}

func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var previous = Array(0...h.count)
    for i in 1...r.count {
        var current = [i] + Array(repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return Double(previous[h.count]) / Double(r.count)
}

func number(_ record: [String: Any], _ key: String) -> Double? { (record[key] as? NSNumber)?.doubleValue }

func fmt(_ value: Double?, _ format: String = "%.0f") -> String { value.map { String(format: format, $0) } ?? "n/a" }

// MARK: - Case execution

struct Result {
    let name: String
    var failures: [String] = []
    var notes: [String] = []
    var wer: Double?
    var stopToPasteMs: Double?
    var record: [String: Any] = [:]
    var firstWordsAt: Double?
    var overlayPolls = 0
}

let placeholders: Set<String> = ["Listening…", "Transcribing…"]

func run(_ testCase: Case, pid: pid_t, note: Note, logs: LogStream, maxWER: Double) throws -> Result {
    var result = Result(name: testCase.name)
    try note.reset()
    // Setup failures abort the run: each recording consumes the next fixture.
    var setupError: Error?
    for _ in 0..<10 {
        do {
            try note.showAndActivate()
            Thread.sleep(forTimeInterval: 0.5)
            try placeCaretInNoteBody()
            Thread.sleep(forTimeInterval: 0.2)
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" else {
                throw Failure(description: "Notes is not frontmost before dictation")
            }
            setupError = nil
            break
        } catch {
            setupError = error
        }
    }
    if let setupError { throw SetupFailure(description: "setup: \(setupError)") }

    let knownTraces = traceIDs()
    let caseStart = Date()
    postFn()
    guard logs.wait(for: "E2E fixture", since: caseStart, timeout: 5)?.contains(testCase.audio) == true else {
        let evidence = logs.lines(since: caseStart).suffix(8).joined(separator: "\n    ")
        throw Failure(description: "recording did not start with \(testCase.audio); OSLog:\n    \(evidence)")
    }
    let recordStart = Date()

    // Poll the overlay at ~2 Hz while the clip (plus silence) plays.
    let playFor = testCase.cancel ? 3.0 : testCase.seconds + 1.2
    var samples: [OverlaySample] = []
    var autoStopChecked = false
    while Date().timeIntervalSince(recordStart) < playFor {
        let t = Date().timeIntervalSince(recordStart)
        if let sample = readOverlay(pid: pid, at: t) { samples.append(sample) }
        if let checkpoint = testCase.assertNoAutoStopAfter, !autoStopChecked, t >= checkpoint {
            autoStopChecked = true
            let stopped = logs.lines(since: recordStart).contains { $0.contains("disarmed") || $0.contains("Recording stopped") }
            if stopped || readOverlay(pid: pid, at: t) == nil {
                result.failures.append("recording stopped before \(Int(checkpoint)) s")
            } else {
                result.notes.append("still recording at \(Int(t)) s")
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    result.overlayPolls = samples.count

    // Overlay checks.
    if samples.isEmpty {
        result.failures.append("overlay never appeared in Accessibility")
    } else {
        let frames = Set(samples.map { "\($0.windowFrame)" })
        if frames.count > 1 { result.failures.append("overlay frame changed: \(frames.sorted().joined(separator: " → "))") }
        let worded = samples.filter { ($0.text.map { !placeholders.contains($0) && !words($0).isEmpty }) ?? false }
        result.firstWordsAt = worded.first?.time
        if testCase.seconds >= 5, !testCase.cancel, worded.isEmpty {
            result.failures.append("a \(Int(testCase.seconds)) s clip never showed words in the overlay")
        }
        for sample in worded {
            guard let text = sample.text else { continue }
            if text.hasSuffix("…") { result.failures.append("overlay tail truncated at \(fmt(sample.time, "%.1f")) s: \(text)"); break }
            if let rect = sample.textFrame, rect.maxY > sample.windowFrame.maxY + 1 || rect.maxY < sample.windowFrame.minY {
                result.failures.append("overlay text bottom \(rect.maxY) outside panel \(sample.windowFrame) at \(fmt(sample.time, "%.1f")) s")
                break
            }
        }
        result.notes.append("overlay \(samples.first!.windowFrame.integral) polls=\(samples.count)")
    }

    if testCase.cancel {
        let cancelStart = Date()
        postKey(53)
        var cancelled = waitForNewTrace(excluding: knownTraces, timeout: 2)
        if cancelled == nil {
            result.failures.append("Escape did not cancel (no trace within 2 s)")
            let ok = cancelThroughMenu(pid: pid)
            result.notes.append("menu Cancel Recording pressed=\(ok)")
            cancelled = waitForNewTrace(excluding: knownTraces, timeout: 4)
        }
        guard let record = cancelled else {
            result.failures.append("no cancelled trace")
            postFn() // stop so the next case starts idle
            return result
        }
        result.record = record
        if record["outcome"] as? String != "cancelled" { result.failures.append("outcome \(record["outcome"] ?? "nil")") }
        if !logs.lines(since: cancelStart).contains(where: { $0.contains("disarmed") }) {
            result.failures.append("fixture was not disarmed")
        }
        Thread.sleep(forTimeInterval: 2.5)
        let text = try note.dictated()
        if !text.isEmpty { result.failures.append("cancel pasted text: \(text)") }
        return result
    }

    let lastPreview = samples.last(where: { ($0.text.map { !placeholders.contains($0) } ?? false) })?.text
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes" else {
        throw Failure(description: "focus left Notes during recording")
    }
    let stopAt = Date()
    postFn()

    // Poll the note until the pasted text is stable for one second.
    var text = ""
    var firstTextAt: Date?
    var stableSince = Date()
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        let current = try note.dictated()
        if current != text { text = current; stableSince = Date() }
        if !text.isEmpty, firstTextAt == nil { firstTextAt = Date() }
        if !text.isEmpty, Date().timeIntervalSince(stableSince) >= 1 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    result.stopToPasteMs = firstTextAt.map { $0.timeIntervalSince(stopAt) * 1000 }
    if text.isEmpty { result.failures.append("nothing pasted into the note") }

    let wer = wordErrorRate(reference: testCase.reference, hypothesis: text)
    result.wer = wer
    if wer > maxWER { result.failures.append(String(format: "WER %.1f%% > %.1f%%; got: %@", wer * 100, maxWER * 100, text)) }

    if let lastPreview {
        let newest = words(lastPreview).suffix(1)
        let finalTail = words(text).suffix(8)
        if let word = newest.first, !finalTail.contains(word) {
            result.failures.append("overlay's newest word \"\(word)\" is not among the final transcript's last 8 words")
        }
    }

    guard let record = waitForNewTrace(excluding: knownTraces, timeout: 10) else {
        result.failures.append("no new trace record")
        return result
    }
    result.record = record
    let missing = requiredTraceFields.filter { record[$0] == nil || record[$0] is NSNull }
    if !missing.isEmpty { result.failures.append("trace missing \(missing.joined(separator: ","))") }
    if record["outcome"] as? String != "eventsPosted" { result.failures.append("outcome \(record["outcome"] ?? "nil")") }
    if record["succeeded"] as? Bool != true { result.failures.append("trace succeeded != true") }
    let segments = (record["segment_count"] as? Int) ?? 0
    if segments < testCase.minimumSegments { result.failures.append("segment_count \(segments) < \(testCase.minimumSegments)") }
    if let utterance = number(record, "utterance_ms"), utterance < testCase.seconds * 1000 {
        result.failures.append("utterance_ms \(Int(utterance)) shorter than clip")
    }
    if let delivered = record["delivered_character_count"] as? Int, delivered != text.count {
        result.notes.append("delivered \(delivered) chars, note has \(text.count)")
    }
    let disarm = logs.lines(since: recordStart).first { $0.contains("disarmed") }
    if let disarm, let range = disarm.range(of: #"consumed (\d+)/(\d+)"#, options: .regularExpression) {
        let parts = disarm[range].dropFirst("consumed ".count).split(separator: "/")
        if parts.count == 2, parts[0] != parts[1] { result.failures.append("fixture only partly played: \(disarm[range])") }
    } else {
        result.failures.append("no fixture disarm log")
    }
    return result
}

// MARK: - Main

func preflight() -> Bool {
    var ok = true
    if !AXIsProcessTrusted() {
        ok = false
        print("""
            FAIL: Accessibility is not granted to this process's responsible app.
              System Settings → Privacy & Security → Accessibility → enable the terminal app
              that runs this script (e.g. Ghostty, Terminal, iTerm), then run it again.
            """)
    }
    do {
        _ = try findTestNote()
    } catch let failure as Failure where failure.description.contains("-1743") {
        ok = false
        print("""
            FAIL: Automation of Notes is not authorized.
              System Settings → Privacy & Security → Automation → enable Notes under the terminal app,
              or run `osascript -e 'tell application "Notes" to count notes'` once and click OK.
            """)
    } catch {
        ok = false
        print("FAIL: \(error)")
    }
    if !FileManager.default.fileExists(atPath: appURL.path) {
        ok = false
        print("FAIL: \(appURL.path) is not installed (run ./script/build_and_run.sh install)")
    }
    return ok
}

let arguments = CommandLine.arguments
guard preflight() else { exit(2) }
if arguments.count == 2, arguments[1] == "--check" {
    print("preflight OK")
    exit(0)
}
guard arguments.count == 3, let maxWER = Double(arguments[2]),
      let data = FileManager.default.contents(atPath: arguments[1]),
      let cases = try? JSONDecoder().decode([Case].self, from: data) else {
    print("usage: e2e_driver --check | e2e_driver <cases.json> <max-wer>")
    exit(2)
}

let note = try findTestNote()
let previousFrontmost = NSWorkspace.shared.frontmostApplication
let hadUserInstance = !runningSpeakeasy().isEmpty
var results: [Result] = []
var fatal: String?
let logs = try LogStream()

func restore() {
    log("restoring: quit E2E instance, reset note, relaunch normal app")
    quitSpeakeasy()
    try? note.reset()
    do {
        _ = try launch(environment: nil)
    } catch {
        print("WARNING: could not relaunch Speakeasy: \(error)")
    }
    if let previousFrontmost, !previousFrontmost.isTerminated {
        previousFrontmost.activate()
    }
    logs.stop()
}

do {
    log("quitting user instance (running=\(hadUserInstance))")
    quitSpeakeasy()
    let launchAt = Date()
    let audio = cases.map(\.audio).joined(separator: ":")
    let app = try launch(environment: [
        "SPEAKEASY_E2E_AUDIO": audio,
    ])
    let pid = app.processIdentifier
    let ppid = parentPID(of: pid)
    log("launched pid=\(pid) ppid=\(ppid.map(String.init) ?? "?")")
    guard ppid == 1 else { throw Failure(description: "Speakeasy PPID is \(ppid.map(String.init) ?? "?"), expected 1 (launchd)") }
    guard logs.wait(for: "Model warmup completed", since: launchAt, timeout: 60) != nil else {
        throw Failure(description: "model warmup did not complete within 60 s")
    }
    // Audio readiness: startup may rebuild the graph once; wait for it to settle.
    Thread.sleep(forTimeInterval: 2)
    let startup = logs.lines(since: launchAt)
    if let problem = startup.last(where: { $0.contains("Microphone reconnecting") || $0.contains("unavailable") }),
       !startup.contains(where: { $0.contains("Microphone reconnected") || $0.contains("Audio capture recovery completed") }) {
        throw Failure(description: "audio capture not ready: \(problem)")
    }
    for testCase in cases {
        log("case \(testCase.name): \(String(format: "%.1f", testCase.seconds)) s \(testCase.cancel ? "(cancel)" : "")")
        do {
            let result = try run(testCase, pid: pid, note: note, logs: logs, maxWER: maxWER)
            results.append(result)
            log("  \(result.failures.isEmpty ? "PASS" : "FAIL: " + result.failures.joined(separator: "; "))")
        } catch let error as SetupFailure {
            throw error
        } catch {
            var failed = Result(name: testCase.name)
            failed.failures.append("\(error)")
            results.append(failed)
            log("  FAIL: \(error)")
        }
        guard runningSpeakeasy().contains(where: { $0.processIdentifier == pid }) else {
            throw Failure(description: "Speakeasy exited during \(testCase.name)")
        }
        Thread.sleep(forTimeInterval: 1)
    }
} catch {
    fatal = "\(error)"
    let evidence = logs.lines(since: startedAt).suffix(15).joined(separator: "\n    ")
    print("FATAL: \(error)\n  OSLog (\(bundleID)):\n    \(evidence)")
}
restore()

print("")
print("| case | result | WER | stop→paste ms | release→paste ms | native total/wait ms | segments | tail s | first words s | notes |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in results {
    let rec = r.record
    let native = "\(fmt(number(rec, "native_total_ms"), "%.1f"))/\(fmt(number(rec, "native_wait_ms"), "%.1f"))"
    let segments = (rec["segment_count"] as? Int).map(String.init) ?? "n/a"
    let status = r.failures.isEmpty ? "PASS" : "FAIL"
    let notes = (r.failures + r.notes).joined(separator: "; ").replacingOccurrences(of: "|", with: "/")
    print("| \(r.name) | \(status) | \(fmt(r.wer.map { $0 * 100 }, "%.1f%%")) | \(fmt(r.stopToPasteMs)) | \(fmt(number(rec, "release_to_paste_request_ms"))) | \(native) | \(segments) | \(fmt(number(rec, "tail_seconds"), "%.2f")) | \(fmt(r.firstWordsAt, "%.1f")) | \(notes) |")
}
let passed = fatal == nil && results.count == cases.count && results.allSatisfy(\.failures.isEmpty)
print("\n\(passed ? "PASS" : "FAIL"): \(results.filter(\.failures.isEmpty).count)/\(cases.count) cases passed")
exit(passed ? 0 : 1)
