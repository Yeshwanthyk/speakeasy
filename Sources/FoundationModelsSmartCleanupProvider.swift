import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

enum SmartCleanupProviderFactory {
    static func make() -> any SmartCleanupProviding {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return FoundationModelsSmartCleanupProvider()
            }
            return UnavailableSmartCleanupProvider(reason: .unsupportedOperatingSystem)
        #else
            return UnavailableSmartCleanupProvider(reason: .frameworkUnavailable)
        #endif
    }
}

struct UnavailableSmartCleanupProvider: SmartCleanupProviding {
    let reason: SmartCleanupUnavailableReason

    func availability() async -> SmartCleanupAvailability {
        .unavailable(reason)
    }

    func prepare(sessionID: UUID) async {}

    func cancel(sessionID: UUID) async {}

    func clean(
        _ request: SmartCleanupRequest,
        sessionID: UUID?
    ) async -> SmartCleanupResult {
        .failure(SmartCleanupFailure(reason: .unavailable(reason), elapsed: 0))
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    actor FoundationModelsSmartCleanupProvider: SmartCleanupProviding {
        private static let maximumResponseTokens = 4_096

        private let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        private var preparedSessions: [UUID: LanguageModelSession] = [:]
        private var activeCancellations: [UUID: FoundationModelCancellationRelay] = [:]

        func availability() async -> SmartCleanupAvailability {
            currentAvailability()
        }

        func prepare(sessionID: UUID) async {
            guard !Task.isCancelled,
                currentAvailability() == .available,
                preparedSessions[sessionID] == nil
            else {
                return
            }
            let session = makeSession()
            preparedSessions = [sessionID: session]
            session.prewarm()
        }

        func cancel(sessionID: UUID) async {
            preparedSessions.removeValue(forKey: sessionID)
            activeCancellations.removeValue(forKey: sessionID)?.cancel()
        }

        func clean(
            _ request: SmartCleanupRequest,
            sessionID: UUID?
        ) async -> SmartCleanupResult {
            let started = ContinuousClock.now
            guard request.isWithinBounds else {
                return failure(.invalidRequest, started: started)
            }
            let availability = currentAvailability()
            guard case .available = availability else {
                let reason: SmartCleanupUnavailableReason
                if case .unavailable(let unavailableReason) = availability {
                    reason = unavailableReason
                } else {
                    reason = .modelNotReady
                }
                return failure(.unavailable(reason), started: started)
            }

            let session =
                sessionID.flatMap { preparedSessions.removeValue(forKey: $0) }
                ?? makeSession()
            let cancellation = FoundationModelCancellationRelay()
            if let sessionID {
                activeCancellations.removeValue(forKey: sessionID)?.cancel()
                activeCancellations[sessionID] = cancellation
            }
            defer {
                if let sessionID, activeCancellations[sessionID] === cancellation {
                    activeCancellations.removeValue(forKey: sessionID)
                }
            }

            let prompt = SmartCleanupPrompt.build(for: request)
            let timeout = SmartCleanupTimeout.duration(
                forTranscriptCharacterCount: request.transcript.count
            )

            do {
                let rawOutput = try await respond(
                    session: session,
                    prompt: prompt,
                    timeout: timeout,
                    cancellation: cancellation
                )
                var output = SmartCleanupOutput.normalize(rawOutput)
                if let textBeforeCaret = request.appContext.textBeforeCaret {
                    output = SmartCleanupOutput.stripRepeatedCaretPrefix(
                        output,
                        before: textBeforeCaret
                    )
                }
                output = SmartCleanupOutput.harmonizeCaseWithCaretContext(
                    output,
                    request: request
                )
                try SmartCleanupOutput.validate(output, source: request.transcript)
                return .success(
                    SmartCleanupResponse(
                        text: output,
                        elapsed: elapsed(since: started)
                    )
                )
            } catch is CancellationError {
                return failure(.cancelled, started: started)
            } catch FoundationModelProviderError.timedOut {
                return failure(.timedOut, started: started)
            } catch is SmartCleanupOutputValidationError {
                return failure(.rejectedOutput, started: started)
            } catch {
                return failure(.generationFailed, started: started)
            }
        }

        private func currentAvailability() -> SmartCleanupAvailability {
            switch model.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(.deviceNotEligible)
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(.appleIntelligenceDisabled)
            case .unavailable(.modelNotReady):
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.modelNotReady)
            }
        }

        private func makeSession() -> LanguageModelSession {
            LanguageModelSession(
                model: model,
                tools: [],
                instructions: SmartCleanupPrompt.instructions
            )
        }

        private func respond(
            session: LanguageModelSession,
            prompt: String,
            timeout: TimeInterval,
            cancellation: FoundationModelCancellationRelay
        ) async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let race = FoundationModelResponseRace(continuation: continuation)
                    let responseTask = Task {
                        do {
                            let response = try await session.respond(
                                to: prompt,
                                options: GenerationOptions(
                                    temperature: 0,
                                    maximumResponseTokens: Self.maximumResponseTokens
                                )
                            )
                            race.finish(.success(response.content))
                        } catch {
                            race.finish(.failure(error))
                        }
                    }
                    race.setResponseTask(responseTask)

                    let timeoutTask = Task {
                        do {
                            try await Task.sleep(
                                nanoseconds: UInt64(timeout * 1_000_000_000)
                            )
                            race.finish(.failure(FoundationModelProviderError.timedOut))
                        } catch {
                            // A response, explicit cancellation, or parent task won.
                        }
                    }
                    race.setTimeoutTask(timeoutTask)
                    cancellation.attach(race)
                }
            } onCancel: {
                cancellation.cancel()
            }
        }

        private func failure(
            _ reason: SmartCleanupFailureReason,
            started: ContinuousClock.Instant
        ) -> SmartCleanupResult {
            .failure(
                SmartCleanupFailure(
                    reason: reason,
                    elapsed: elapsed(since: started)
                )
            )
        }

        private func elapsed(since started: ContinuousClock.Instant) -> TimeInterval {
            let components = started.duration(to: .now).components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1e18
        }
    }

    @available(macOS 26.0, *)
    private enum FoundationModelProviderError: Error {
        case timedOut
    }

    @available(macOS 26.0, *)
    private final class FoundationModelCancellationRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var race: FoundationModelResponseRace?
        private var isCancelled = false

        func attach(_ race: FoundationModelResponseRace) {
            lock.lock()
            self.race = race
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel {
                race.finish(.failure(CancellationError()))
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let race = race
            lock.unlock()
            race?.finish(.failure(CancellationError()))
        }
    }

    @available(macOS 26.0, *)
    private final class FoundationModelResponseRace: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private let continuation: CheckedContinuation<String, Error>
        private var responseTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }

        func setResponseTask(_ task: Task<Void, Never>) {
            lock.lock()
            let shouldCancel = isCompleted
            if !shouldCancel { responseTask = task }
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            let shouldCancel = isCompleted
            if !shouldCancel { timeoutTask = task }
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            let responseTask = responseTask
            let timeoutTask = timeoutTask
            self.responseTask = nil
            self.timeoutTask = nil
            lock.unlock()

            responseTask?.cancel()
            timeoutTask?.cancel()
            continuation.resume(with: result)
        }
    }
#endif
