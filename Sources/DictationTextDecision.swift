import Foundation

/// What one finished native pass should deliver. Evaluating it is pure, so
/// the coordinator runs it on the transcription queue and the single
/// main-actor hop that follows only applies the result.
enum DictationTextDecision: Equatable, Sendable {
    /// Nothing left to deliver, before or after corrections.
    case empty
    case hallucination(HallucinationFilterReason)
    case accepted(ProcessedTranscript)

    static func evaluate(
        _ text: String,
        filter: HallucinationFilter,
        postProcessor: TranscriptPostProcessor,
        activeDurationSeconds: TimeInterval?,
        activeRMS: Float?
    ) -> DictationTextDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let verdict = filter.verdict(
            for: trimmed,
            activeDurationSeconds: activeDurationSeconds,
            activeRMS: activeRMS
        )
        if case .rejected(let reason) = verdict {
            return .hallucination(reason)
        }

        let processed = postProcessor.process(trimmed)
        let finalText = processed.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return .empty }
        return .accepted(
            ProcessedTranscript(
                rawText: processed.rawText,
                finalText: finalText,
                stageChanges: processed.stageChanges
            )
        )
    }
}
