import AppKit
import Combine
import SwiftUI

// MARK: - Settings page

struct MeetingsPage: View {
    @ObservedObject var controller: MeetingController
    @State private var enabled = MeetingPreferences.isEnabled()
    @State private var detectsCalls = MeetingPreferences.detectsCalls()
    @State private var capturesSystemAudio = MeetingPreferences.capturesSystemAudio()
    @State private var keepAudioDays = MeetingPreferences.keepAudioDays()
    @State private var viewing: MeetingManifest?
    @State private var confirmDelete: MeetingManifest?

    var body: some View {
        SettingsCard {
            ToggleRow(
                title: "Record meetings",
                detail: "Adds Record Meeting to the menu. Speakeasy saves the audio and a transcript of you and the other side on this Mac; nothing is uploaded.",
                isOn: $enabled
            )
            .onChange(of: enabled) { value in
                UserDefaults.standard.set(value, forKey: MeetingPreferences.enabledKey)
                controller.updateDetection()
            }
            if enabled {
                Divider()
                ToggleRow(
                    title: "Offer to record calls",
                    detail: MicrophoneClientMonitor.isSupported
                        ? "When Zoom, Teams, FaceTime, Slack, or a browser call uses the microphone, ask whether to record. Never records on its own."
                        : "Needs macOS 14.2 or later.",
                    isOn: $detectsCalls
                )
                .disabled(!MicrophoneClientMonitor.isSupported)
                .onChange(of: detectsCalls) { value in
                    UserDefaults.standard.set(value, forKey: MeetingPreferences.detectCallsKey)
                    controller.updateDetection()
                }
                Divider()
                ToggleRow(
                    title: "Include the other side",
                    detail: "Records system audio (needs Screen Recording access). Off records only your microphone.",
                    isOn: $capturesSystemAudio
                )
                .onChange(of: capturesSystemAudio) { value in
                    UserDefaults.standard.set(value, forKey: MeetingPreferences.systemAudioKey)
                }
                Divider()
                SettingsRow(
                    "Keep meeting audio",
                    detail: "About 230 MB per hour with system audio. Transcripts are always kept."
                ) {
                    Picker("Keep meeting audio", selection: $keepAudioDays) {
                        ForEach(MeetingPreferences.keepAudioChoices, id: \.self) { days in
                            Text(Self.label(forKeepDays: days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .onChange(of: keepAudioDays) { value in
                        MeetingPreferences.setKeepAudioDays(value)
                        controller.applyRetention()
                        controller.reloadMeetings()
                    }
                }
            }
        }

        if controller.meetings.isEmpty {
            if enabled {
                SettingsEmptyState(
                    symbol: "person.2",
                    title: "No meetings yet",
                    detail: "Choose Record Meeting from the menu bar."
                )
            }
        } else {
            SettingsCard(title: "Recordings") {
                ForEach(controller.meetings) { meeting in
                    if meeting.id != controller.meetings.first?.id { Divider() }
                    MeetingRow(
                        meeting: meeting,
                        isRecording: controller.recording?.id == meeting.id,
                        open: { viewing = meeting },
                        reveal: { controller.revealInFinder(meeting.id) },
                        deleteAudio: { controller.deleteAudio(meeting.id) },
                        delete: { confirmDelete = meeting }
                    )
                }
            }
            .sheet(item: $viewing) { meeting in
                MeetingTranscriptSheet(title: meeting.title, text: controller.transcript(meeting.id))
            }
            .alert(item: $confirmDelete) { meeting in
                Alert(
                    title: Text("Delete “\(meeting.title)”?"),
                    message: Text("This removes its audio and transcript from this Mac."),
                    primaryButton: .destructive(Text("Delete")) { controller.delete(meeting.id) },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    static func label(forKeepDays days: Int?) -> String {
        switch days {
        case nil: return "Forever"
        case 0: return "Delete after transcribing"
        case 1: return "1 day"
        case let days?: return "\(days) days"
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingManifest
    let isRecording: Bool
    let open: () -> Void
    let reveal: () -> Void
    let deleteAudio: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(SettingsType.rowTitleEmphasis).lineLimit(2)
                HStack(spacing: 6) {
                    Text(SettingsFormat.historyDate.string(from: meeting.startedAt))
                    if let duration = meeting.duration {
                        Text("·")
                        Text(MeetingFormat.clock(duration))
                    }
                    if !meeting.hasAudio {
                        Text("·")
                        Text("Transcript only")
                    }
                }
                .font(SettingsType.meta)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isRecording {
                StatusPill(text: "Recording", tint: .red)
            } else if meeting.state == .interrupted {
                StatusPill(text: "Interrupted", tint: .orange)
            }
            Button("Open", action: open)
            Menu {
                Button("Show in Finder", action: reveal)
                if meeting.hasAudio && !isRecording {
                    Button("Delete Audio, Keep Transcript", action: deleteAudio)
                }
                if !isRecording {
                    Divider()
                    Button("Delete Meeting…", role: .destructive, action: delete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions for \(meeting.title)")
        }
    }
}

private struct MeetingTranscriptSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(SettingsType.rowTitleEmphasis).lineLimit(1)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - Live transcript

struct MeetingLiveView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let recording = controller.recording {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Recording")
                    Text(recording.title).font(SettingsType.rowTitleEmphasis).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MeetingFormat.clock(context.date.timeIntervalSince(recording.startedAt)))
                            .font(SettingsType.meta)
                            .foregroundColor(.secondary)
                    }
                    Button("Stop") { controller.stop() }
                } else {
                    Text(controller.isFinishing ? "Finishing transcript…" : "Not recording")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Record Meeting") { controller.start() }
                        .disabled(controller.isFinishing)
                }
            }
            if controller.recording?.capturesSystemAudio == false {
                Text("Microphone only — the other side is not being recorded.")
                    .font(SettingsType.rowDetail).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(MeetingFormat.turns(controller.liveSegments).enumerated()), id: \.offset) { index, turn in
                            HStack(alignment: .top, spacing: 8) {
                                Text(turn.track.label)
                                    .font(SettingsType.rowDetail.weight(.semibold))
                                    .foregroundStyle(turn.track == .you ? Color.accentColor : Color.secondary)
                                    .frame(width: 40, alignment: .leading)
                                Text(turn.text)
                                    .font(SettingsType.rowTitle)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                            .id(index)
                        }
                    }
                }
                .onChange(of: controller.liveSegments.count) { _ in
                    let last = MeetingFormat.turns(controller.liveSegments).count - 1
                    if last >= 0 { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if controller.liveSegments.isEmpty && controller.recording != nil {
                Text("Speech appears here a few seconds after each pause.")
                    .font(SettingsType.rowDetail).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
    }
}

@MainActor
final class MeetingLiveWindowController: NSWindowController {
    init(controller: MeetingController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meeting Transcript"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeetingLiveView(controller: controller))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Call offer

private struct MeetingOfferView: View {
    let offer: MeetingOffer
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(offer.appName) call detected").font(SettingsType.rowTitleEmphasis)
                Text("Record and transcribe it on this Mac?").font(SettingsType.rowDetail).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Not Now", action: dismiss)
            Button("Record", action: record).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, SettingsMetrics.cardPaddingY)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius + 2, style: .continuous))
    }
}

/// Shows the call offer below the menu bar without taking focus from the call.
@MainActor
final class MeetingOfferPresenter {
    private let controller: MeetingController
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(controller: MeetingController) {
        self.controller = controller
        subscription = controller.$offer
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offer in
                MainActor.assumeIsolated { self?.show(offer) }
            }
    }

    private func show(_ offer: MeetingOffer?) {
        panel?.orderOut(nil)
        panel = nil
        guard let offer, let screen = NSScreen.main else { return }
        let view = MeetingOfferView(
            offer: offer,
            record: { [weak controller] in controller?.acceptOffer() },
            dismiss: { [weak controller] in controller?.declineOffer() }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 12,
                width: size.width,
                height: size.height
            ),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
