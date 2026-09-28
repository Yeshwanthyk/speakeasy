import AppKit
import SwiftUI

@MainActor
final class CorrectionEditorModel: ObservableObject {
    typealias Loader = @MainActor () -> [TranscriptCorrection]
    typealias Saver = @MainActor ([TranscriptCorrection]) async throws -> Bool

    @Published var corrections: [TranscriptCorrection] = []
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    private let loadCorrections: Loader
    private let saveCorrections: Saver
    private var savedCorrections: [TranscriptCorrection] = []

    init(
        loadCorrections: @escaping Loader,
        saveCorrections: @escaping Saver
    ) {
        self.loadCorrections = loadCorrections
        self.saveCorrections = saveCorrections
        reload()
    }

    var hasUnsavedChanges: Bool {
        corrections != savedCorrections
    }

    var canAddCorrection: Bool {
        corrections.count < TranscriptPostProcessor.maxCorrections && !isSaving
    }

    var canSave: Bool {
        hasUnsavedChanges && !isSaving
    }

    func reload() {
        let loaded = loadCorrections()
        corrections = loaded
        savedCorrections = loaded
        errorMessage = nil
    }

    func addCorrection() {
        guard canAddCorrection else { return }
        corrections.append(TranscriptCorrection(heard: "", written: ""))
        errorMessage = nil
    }

    func removeCorrection(id: UUID) {
        guard !isSaving else { return }
        corrections.removeAll { $0.id == id }
        errorMessage = nil
    }

    func save() async -> Bool {
        guard canSave else { return false }

        do {
            _ = try TranscriptPostProcessor(corrections: corrections)
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            guard try await saveCorrections(corrections) else {
                errorMessage = "Corrections could not be saved. Your previous corrections are still active."
                return false
            }
            savedCorrections = corrections
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? TranscriptPostProcessorError else {
            return "Corrections could not be saved. Your previous corrections are still active."
        }

        switch error {
        case .tooManyCorrections:
            return "You can save up to \(TranscriptPostProcessor.maxCorrections) corrections."
        case .tooManyEnabledCorrections:
            return "Enable no more than \(TranscriptPostProcessor.maxEnabledCorrections) corrections."
        case .heardIsEmpty(let index):
            return "Enter what Speakeasy hears for correction \(index + 1)."
        case .heardIsTooLong(let index, _):
            return "The heard phrase in correction \(index + 1) is too long."
        case .writtenIsTooLong(let index, _):
            return "The replacement in correction \(index + 1) is too long."
        case .duplicateHeard(let index, let duplicateOf):
            return "Correction \(index + 1) duplicates correction \(duplicateOf + 1)."
        }
    }
}

struct CorrectionEditorView: View {
    @ObservedObject var model: CorrectionEditorModel
    let cancel: () -> Void
    let saved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Personal corrections")
                    .font(.title2.weight(.semibold))
                Text("Replace exact words or phrases after local transcription. Rules stay on this Mac and do not change speech-model inference.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            if model.corrections.isEmpty {
                emptyState
            } else {
                correctionList
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(errorMessage)")
                }

                HStack(spacing: 10) {
                    Button {
                        model.addCorrection()
                    } label: {
                        Label("Add Correction", systemImage: "plus")
                    }
                    .disabled(!model.canAddCorrection)

                    Text("\(model.corrections.count) of \(TranscriptPostProcessor.maxCorrections)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isSaving)

                    Button {
                        Task {
                            if await model.save() {
                                saved()
                            }
                        }
                    } label: {
                        if model.isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 44)
                        } else {
                            Text("Save")
                                .frame(width: 44)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 500)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No personal corrections yet")
                .font(.headline)
            Text("Add the phrase Speakeasy hears and the text you want written instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Your First Correction") {
                model.addCorrection()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var correctionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("ON")
                    .frame(width: 28)
                Text("WHEN SPEAKEASY HEARS")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("WRITE")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($model.corrections) { $correction in
                        HStack(spacing: 10) {
                            Toggle("Enabled", isOn: $correction.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .frame(width: 28)

                            TextField("What was heard", text: $correction.heard)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("What Speakeasy hears")

                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)

                            TextField("What should be written", text: $correction.written)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("What Speakeasy should write")

                            Button {
                                model.removeCorrection(id: correction.id)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove correction")
                            .accessibilityLabel("Remove correction")
                        }
                        .disabled(model.isSaving)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider()
                            .padding(.leading, 54)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
final class CorrectionEditorWindowController: NSWindowController, NSWindowDelegate {
    private let model: CorrectionEditorModel
    private var discardConfirmed = false

    init(
        loadCorrections: @escaping CorrectionEditorModel.Loader,
        saveCorrections: @escaping CorrectionEditorModel.Saver
    ) {
        let model = CorrectionEditorModel(
            loadCorrections: loadCorrections,
            saveCorrections: saveCorrections
        )
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Corrections"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: CorrectionEditorView(
                model: model,
                cancel: { [weak self] in self?.discardAndClose() },
                saved: { [weak self] in self?.window?.close() }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        if window?.isVisible != true {
            model.reload()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges, !discardConfirmed else { return true }

        let alert = NSAlert()
        alert.messageText = "Discard unsaved corrections?"
        alert.informativeText = "Your saved corrections will remain active."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func discardAndClose() {
        discardConfirmed = true
        window?.close()
        discardConfirmed = false
    }
}
