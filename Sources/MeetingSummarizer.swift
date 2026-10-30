import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional meeting summary from the on-device Apple Intelligence model
/// (macOS 26+). Nothing leaves the Mac; without the model, notes fall back
/// to the deterministic talk time and action items.
enum MeetingSummarizer {
    /// Roughly what fits the on-device context with room for the answer.
    static let maximumTranscriptCharacters = 9_000

    static func summary(of segments: [MeetingSegment]) async -> String? {
        let transcript = prompt(for: segments)
        guard !transcript.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: """
                You summarize meeting transcripts. "You" is the person who recorded the meeting; \
                "Them" is everyone else. Reply with a one-line title, then 3 to 6 short bullet \
                points covering decisions and open questions. Only use facts from the transcript.
                """)
            do {
                let response = try await session.respond(to: transcript)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// The transcript as speaker-labeled lines, keeping the start and end of
    /// long meetings when it must be shortened.
    static func prompt(for segments: [MeetingSegment]) -> String {
        let lines = MeetingFormat.turns(segments).map { "\($0.track.label): \($0.text)" }
        let full = lines.joined(separator: "\n")
        guard full.count > maximumTranscriptCharacters else { return full }
        let half = maximumTranscriptCharacters / 2
        return String(full.prefix(half)) + "\n[…]\n" + String(full.suffix(half))
    }

    /// The model's first line, used as the meeting title when short enough.
    static func title(from summary: String) -> String? {
        guard let first = summary.split(whereSeparator: \.isNewline).first else { return nil }
        let title = first
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-•: ").union(.whitespaces))
            .replacingOccurrences(of: "Title", with: "", options: [.anchored, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        guard !title.isEmpty, title.count <= 80 else { return nil }
        return title
    }
}
