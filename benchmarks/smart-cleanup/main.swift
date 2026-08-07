import CryptoKit
import Darwin
import Foundation

// The production core uses this delivery identity in its context collector protocol.
// The benchmark supplies only synthetic AppContext values, so the full app delivery
// implementation is not linked into this small process.
struct TranscriptDeliveryApplication: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
}

private struct Fixture: Decodable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String
    let selectedText: String?
    let textBeforeCaret: String?
    let transcript: String
    let requiredTerms: [String]
}

private struct ResultRow: Encodable {
    let fixture: String
    let repetition: Int
    let mode: String
    let writingContext: String
    let prewarmCallMs: Double?
    let wallMs: Double
    let providerMs: Double?
    let usedFallback: Bool
    let failure: String?
    let anchorsPreserved: Bool
    let outputHash: String
    let peakRSSBytes: Int64
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArguments
    case unavailable(SmartCleanupUnavailableReason)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: smart-cleanup-bench <fixtures.json> <exact|basic|smart> <repetitions>"
        case .unavailable(let reason):
            return "Smart Cleanup is unavailable: \(String(describing: reason))"
        }
    }
}

@main
private struct SmartCleanupBenchmark {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let mode = SmartCleanupMode(rawValue: arguments[2]),
              let repetitions = Int(arguments[3]),
              repetitions > 0 else {
            throw BenchmarkError.invalidArguments
        }

        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: fixtureData)
        let provider: (any SmartCleanupProviding)?
        if mode == .smart {
            let smartProvider = SmartCleanupProviderFactory.make()
            let availability = await smartProvider.availability()
            guard case .available = availability else {
                if case .unavailable(let reason) = availability {
                    throw BenchmarkError.unavailable(reason)
                }
                throw BenchmarkError.unavailable(.modelNotReady)
            }
            provider = smartProvider
        } else {
            provider = nil
        }

        let postProcessor = TranscriptPostProcessor()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for repetition in 1...repetitions {
            for (index, fixture) in fixtures.enumerated() {
                let context = AppContext(
                    processIdentifier: Int32(index + 100),
                    appName: fixture.appName,
                    bundleIdentifier: fixture.bundleIdentifier,
                    windowTitle: fixture.windowTitle,
                    selectedText: fixture.selectedText,
                    textBeforeCaret: fixture.textBeforeCaret
                )
                let category = AppWritingContext.classify(
                    appName: context.appName,
                    bundleIdentifier: context.bundleIdentifier,
                    windowTitle: context.windowTitle
                )
                let sessionID = UUID()
                var prewarmCallMs: Double?
                if let provider {
                    let prewarmStart = DispatchTime.now().uptimeNanoseconds
                    await provider.prepare(sessionID: sessionID)
                    prewarmCallMs = milliseconds(since: prewarmStart)
                }

                let start = DispatchTime.now().uptimeNanoseconds
                let output: String
                let providerMs: Double?
                let failure: String?
                let usedFallback: Bool
                switch mode {
                case .exact:
                    output = fixture.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    providerMs = nil
                    failure = nil
                    usedFallback = false
                case .basic:
                    output = postProcessor.process(fixture.transcript).finalText
                    providerMs = nil
                    failure = nil
                    usedFallback = false
                case .smart:
                    guard let provider else {
                        throw BenchmarkError.unavailable(.frameworkUnavailable)
                    }
                    let fallback = postProcessor.process(fixture.transcript).finalText
                    let result = await provider.clean(
                        SmartCleanupRequest(transcript: fixture.transcript, appContext: context),
                        sessionID: sessionID
                    )
                    providerMs = result.elapsed * 1_000
                    switch result {
                    case .success(let response):
                        output = postProcessor.process(response.text).finalText
                        failure = nil
                        usedFallback = false
                    case .failure(let value):
                        output = fallback
                        failure = String(describing: value.reason)
                        usedFallback = true
                    }
                }
                let wallMs = milliseconds(since: start)
                if let provider {
                    await provider.cancel(sessionID: sessionID)
                }

                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let row = ResultRow(
                    fixture: fixture.id,
                    repetition: repetition,
                    mode: mode.rawValue,
                    writingContext: category.rawValue,
                    prewarmCallMs: prewarmCallMs,
                    wallMs: wallMs,
                    providerMs: providerMs,
                    usedFallback: usedFallback,
                    failure: failure,
                    anchorsPreserved: anchors(fixture.requiredTerms, appearIn: output),
                    outputHash: sha256(output),
                    peakRSSBytes: Int64(usage.ru_maxrss)
                )
                print(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func anchors(_ anchors: [String], appearIn output: String) -> Bool {
        let normalized = output.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return anchors.allSatisfy {
            normalized.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
