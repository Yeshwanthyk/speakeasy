import Foundation

enum ModelPathError: Error {
    case appSupportUnavailable
    case unsupportedModel(String)
    case modelNotFound(String)
    case modelInvalid(String, reason: String)
}

struct ASRModelArtifact: Equatable, Sendable {
    let repository: String
    let revision: String
    let filename: String
    let expectedByteCount: Int64
    let sha256: String

    var remoteURL: URL? {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")
    }
}

enum ASRModelKind: CaseIterable, Equatable, Sendable {
    case parakeetUnified
    case parakeetTDT
    case nemotron

    init(environmentValue: String?) throws {
        guard let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            self = .parakeetUnified
            return
        }

        switch value.lowercased() {
        case "parakeet", "parakeet-unified", "parakeet-unified-en":
            self = .parakeetUnified
        case "parakeet-tdt", "parakeet-v3", "parakeet-tdt-v3":
            self = .parakeetTDT
        case "nemotron", "nemotron-3", "nemotron-3.5", "nemotron-3.5-asr":
            self = .nemotron
        default:
            throw ModelPathError.unsupportedModel(value)
        }
    }

    init?(preferenceValue: String) {
        guard let kind = try? ASRModelKind(environmentValue: preferenceValue) else {
            return nil
        }
        self = kind
    }

    var displayName: String {
        switch self {
        case .parakeetUnified:
            return "Parakeet Unified EN"
        case .parakeetTDT:
            return "Parakeet TDT v3"
        case .nemotron:
            return "Nemotron Streaming 3.5"
        }
    }

    var preferenceValue: String {
        switch self {
        case .parakeetUnified:
            return "parakeet-unified-en"
        case .parakeetTDT:
            return "parakeet-tdt-v3"
        case .nemotron:
            return "nemotron-3.5-asr"
        }
    }

    var overrideEnvironmentKey: String {
        switch self {
        case .parakeetUnified:
            return "PARAKEET_UNIFIED_GGUF_PATH"
        case .parakeetTDT:
            return "PARAKEET_TDT_GGUF_PATH"
        case .nemotron:
            return "NEMOTRON_GGUF_PATH"
        }
    }

    var overridePreferenceKey: String {
        switch self {
        case .parakeetUnified:
            return "ParakeetUnifiedGGUFPath"
        case .parakeetTDT:
            return "ParakeetTDTGGUFPath"
        case .nemotron:
            return "NemotronGGUFPath"
        }
    }

    var artifact: ASRModelArtifact {
        switch self {
        case .parakeetUnified:
            return ASRModelArtifact(
                repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
                revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c",
                filename: "parakeet-unified-en-0.6b-Q8_0.gguf",
                expectedByteCount: 731_357_568,
                sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
            )
        case .parakeetTDT:
            return ASRModelArtifact(
                repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
                revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
                filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
                expectedByteCount: 739_508_576,
                sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"
            )
        case .nemotron:
            return ASRModelArtifact(
                repository: "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf",
                revision: "6d44e540bc31b0de1dbe174a3cea87f53a7f22fb",
                filename: "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
                expectedByteCount: 751_094_240,
                sha256: "b94545b313b3223fda7b2857a52681da813935c2127643d1e9ff0c23d988089c"
            )
        }
    }
}

struct ASRModelConfiguration: Equatable, Sendable {
    let kind: ASRModelKind
    let url: URL
    // Reserved for a future capability-aware run-options ABI. Current GGUF
    // models use their own language detection/default behavior.
    let language: String?

    init(kind: ASRModelKind, url: URL, language: String? = nil) {
        self.kind = kind
        self.url = url
        self.language = language
    }
}

enum ModelPathResolver {
    private static let canonicalBundleIdentifier = "com.speakeasy.app"
    private static let legacyBundleIdentifier = "com.wisp.app"
    private static let modelKindEnvironmentKey = "SPEAKEASY_ASR_MODEL"
    private static let legacyModelKindEnvironmentKey = "WISP_ASR_MODEL"
    private static let modelKindPreferenceKey = "ASRModel"

    static func configuredASRModelKind() throws -> ASRModelKind {
        try configuredASRModelKind(
            environment: ProcessInfo.processInfo.environment,
            preferences: stringPreferences()
        )
    }

    static func configuredASRModelKind(
        environment: [String: String],
        preferences: [String: String] = [:]
    ) throws -> ASRModelKind {
        let value = environment[modelKindEnvironmentKey]
            ?? environment[legacyModelKindEnvironmentKey]
            ?? preferences[modelKindPreferenceKey]
            ?? preferences[legacyModelKindEnvironmentKey]
        return try ASRModelKind(environmentValue: value)
    }

    static func configuredASRModel() throws -> ASRModelConfiguration {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        return try configuredASRModel(
            appSupport: appSupport,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            preferences: stringPreferences()
        )
    }

    static func configuredASRModel(kind: ASRModelKind) throws -> ASRModelConfiguration {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        return try configuredASRModel(
            kind: kind,
            appSupport: appSupport,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            preferences: stringPreferences()
        )
    }

    static func configuredASRModel(
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String] = [:]
    ) throws -> ASRModelConfiguration {
        let kind = try configuredASRModelKind(
            environment: environment,
            preferences: preferences
        )
        return try configuredASRModel(
            kind: kind,
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            preferences: preferences
        )
    }

    static func configuredASRModel(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String] = [:]
    ) throws -> ASRModelConfiguration {
        ASRModelConfiguration(
            kind: kind,
            url: try modelPath(
                kind: kind,
                appSupport: appSupport,
                bundleIdentifier: bundleIdentifier,
                environment: environment,
                preferences: preferences
            )
        )
    }

    static func persistSelectedModelKind(_ kind: ASRModelKind, defaults: UserDefaults = .standard) {
        defaults.set(kind.preferenceValue, forKey: modelKindPreferenceKey)
    }

    static func preferredInstallURL(kind: ASRModelKind) throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        return preferredInstallURL(
            kind: kind,
            appSupport: appSupport,
            environment: ProcessInfo.processInfo.environment,
            preferences: stringPreferences()
        )
    }

    static func preferredInstallURL(
        kind: ASRModelKind,
        appSupport: URL,
        environment: [String: String],
        preferences: [String: String] = [:]
    ) -> URL {
        if let override = (environment[kind.overrideEnvironmentKey]
            ?? preferences[kind.overridePreferenceKey])?.nilIfEmpty {
            return URL(fileURLWithPath: override)
        }

        return makeModelURL(
            appSupport: appSupport,
            bundleIdentifier: canonicalBundleIdentifier,
            kind: kind
        )
    }

    static func isModelInstalled(kind: ASRModelKind, at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true
            && Int64(values.fileSize ?? 0) == kind.artifact.expectedByteCount
    }

    private static func modelPath(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String]
    ) throws -> URL {
        if let override = (environment[kind.overrideEnvironmentKey]
            ?? preferences[kind.overridePreferenceKey])?.nilIfEmpty {
            return try validateModel(kind: kind, at: URL(fileURLWithPath: override))
        }

        let bundleIdentifier = bundleIdentifier ?? canonicalBundleIdentifier
        let modelURL = makeModelURL(
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            kind: kind
        )
        if isModelInstalled(kind: kind, at: modelURL) {
            return modelURL
        }

        if bundleIdentifier != legacyBundleIdentifier {
            let legacyURL = makeModelURL(
                appSupport: appSupport,
                bundleIdentifier: legacyBundleIdentifier,
                kind: kind
            )
            if isModelInstalled(kind: kind, at: legacyURL) {
                return legacyURL
            }
        }

        if FileManager.default.fileExists(atPath: modelURL.path) {
            throw ModelPathError.modelInvalid(
                modelURL.path,
                reason: "expected \(kind.artifact.expectedByteCount) bytes"
            )
        }
        throw ModelPathError.modelNotFound(modelURL.path)
    }

    private static func validateModel(kind: ASRModelKind, at url: URL) throws -> URL {
        if isModelInstalled(kind: kind, at: url) {
            return url
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw ModelPathError.modelInvalid(
                url.path,
                reason: "expected \(kind.artifact.expectedByteCount) bytes"
            )
        }
        throw ModelPathError.modelNotFound(url.path)
    }

    private static func makeModelURL(
        appSupport: URL,
        bundleIdentifier: String,
        kind: ASRModelKind
    ) -> URL {
        appSupport
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("models")
            .appendingPathComponent(kind.artifact.filename)
    }

    private static func stringPreferences() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation().reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
