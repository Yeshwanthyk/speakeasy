import CryptoKit
import Foundation

enum ModelPathError: Error {
    case appSupportUnavailable
    case unsupportedModel(String)
    case modelNotFound(String)
    case modelInvalid(String, reason: String)
}

enum ModelArtifactVerificationError: Error, Equatable {
    case fileMissing(String)
    case notRegularFile(String)
    case unexpectedFileSize(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
}

struct ASRModelArtifact: Equatable, Sendable {
    let repository: String
    let revision: String
    let filename: String
    let expectedByteCount: Int64
    let sha256: String
    let license: String

    init(
        repository: String,
        revision: String,
        filename: String,
        expectedByteCount: Int64,
        sha256: String,
        license: String = "Unknown"
    ) {
        self.repository = repository
        self.revision = revision
        self.filename = filename
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
        self.license = license
    }

    var remoteURL: URL? {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")
    }
}

enum ASRModelKind: CaseIterable, Equatable, Sendable {
    case parakeet110M
    case parakeetUnified

    init(environmentValue: String?) throws {
        guard let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            self = .parakeet110M
            return
        }

        switch value.lowercased() {
        case "parakeet-110m", "parakeet-tdt-ctc-110m", "parakeet-tdt-ctc-110m-q8_0":
            self = .parakeet110M
        case "parakeet", "parakeet-unified", "parakeet-unified-en":
            self = .parakeetUnified
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
        case .parakeet110M:
            return "Parakeet TDT+CTC 110M Q8_0"
        case .parakeetUnified:
            return "Parakeet Unified EN 0.6B Q8_0"
        }
    }

    var preferenceValue: String {
        switch self {
        case .parakeet110M:
            return "parakeet-tdt-ctc-110m"
        case .parakeetUnified:
            return "parakeet-unified-en"
        }
    }

    var overrideEnvironmentKey: String {
        switch self {
        case .parakeet110M:
            return "PARAKEET_110M_GGUF_PATH"
        case .parakeetUnified:
            return "PARAKEET_UNIFIED_GGUF_PATH"
        }
    }

    var overridePreferenceKey: String {
        switch self {
        case .parakeet110M:
            return "Parakeet110MGGUFPath"
        case .parakeetUnified:
            return "ParakeetUnifiedGGUFPath"
        }
    }

    var artifact: ASRModelArtifact {
        switch self {
        case .parakeet110M:
            return ASRModelArtifact(
                repository: "handy-computer/parakeet-tdt_ctc-110m-gguf",
                revision: "9d66d34f9e1594075c5dd72c90c0f4c321b29f21",
                filename: "parakeet-tdt_ctc-110m-Q8_0.gguf",
                expectedByteCount: 135_373_280,
                sha256: "7dd44c74a331d788a4e5f8b16913b3feb29ced22cf5613aad0e0f6cd30516296",
                license: "CC-BY-4.0"
            )
        case .parakeetUnified:
            return ASRModelArtifact(
                repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
                revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c",
                filename: "parakeet-unified-en-0.6b-Q8_0.gguf",
                expectedByteCount: 731_357_568,
                sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
                license: "CC-BY-4.0"
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
    let artifactVerified: Bool

    init(
        kind: ASRModelKind,
        url: URL,
        language: String? = nil,
        artifactVerified: Bool = false
    ) {
        self.kind = kind
        self.url = url
        self.language = language
        self.artifactVerified = artifactVerified
    }
}

enum ModelPathResolver {
    typealias ArtifactProvider = (ASRModelKind) -> ASRModelArtifact

    private static let canonicalBundleIdentifier = "com.speakeasy.app"
    private static let modelKindEnvironmentKey = "SPEAKEASY_ASR_MODEL"
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
        try ASRModelKind(environmentValue: environment[modelKindEnvironmentKey]
            ?? preferences[modelKindPreferenceKey])
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
        preferences: [String: String] = [:],
        artifactProvider: @escaping ArtifactProvider = { $0.artifact }
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
            preferences: preferences,
            artifactProvider: artifactProvider
        )
    }

    static func configuredASRModel(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String] = [:],
        artifactProvider: @escaping ArtifactProvider = { $0.artifact }
    ) throws -> ASRModelConfiguration {
        ASRModelConfiguration(
            kind: kind,
            url: try modelPath(
                kind: kind,
                appSupport: appSupport,
                bundleIdentifier: bundleIdentifier,
                environment: environment,
                preferences: preferences,
                artifactProvider: artifactProvider
            ),
            artifactVerified: true
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

    static func isModelInstalled(
        kind: ASRModelKind,
        at url: URL,
        artifactProvider: @escaping ArtifactProvider = { $0.artifact }
    ) -> Bool {
        (try? verifyArtifact(artifactProvider(kind), at: url)) != nil
    }

    static func verifyModelArtifact(kind: ASRModelKind, at url: URL) throws {
        try verifyArtifact(kind.artifact, at: url)
    }

    static func verifyArtifact(_ artifact: ASRModelArtifact, at url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw ModelArtifactVerificationError.fileMissing(url.path)
        }
        guard values.isRegularFile == true else {
            throw ModelArtifactVerificationError.notRegularFile(url.path)
        }

        let actualByteCount = Int64(values.fileSize ?? 0)
        guard actualByteCount == artifact.expectedByteCount else {
            throw ModelArtifactVerificationError.unexpectedFileSize(
                expected: artifact.expectedByteCount,
                actual: actualByteCount
            )
        }

        guard let stream = InputStream(url: url) else {
            throw ModelArtifactVerificationError.fileMissing(url.path)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<count]))
        }

        let actualChecksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualChecksum == artifact.sha256 else {
            throw ModelArtifactVerificationError.checksumMismatch(
                expected: artifact.sha256,
                actual: actualChecksum
            )
        }
    }

    private static func modelPath(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String],
        artifactProvider: @escaping ArtifactProvider
    ) throws -> URL {
        if let override = (environment[kind.overrideEnvironmentKey]
            ?? preferences[kind.overridePreferenceKey])?.nilIfEmpty {
            return try validateModel(
                kind: kind,
                at: URL(fileURLWithPath: override),
                artifactProvider: artifactProvider
            )
        }

        let bundleIdentifier = bundleIdentifier ?? canonicalBundleIdentifier
        let modelURL = makeModelURL(
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            kind: kind
        )
        if isModelInstalled(kind: kind, at: modelURL, artifactProvider: artifactProvider) {
            return modelURL
        }


        if FileManager.default.fileExists(atPath: modelURL.path) {
            throw ModelPathError.modelInvalid(
                modelURL.path,
                reason: validationFailureReason(
                    artifact: artifactProvider(kind),
                    at: modelURL
                )
            )
        }
        throw ModelPathError.modelNotFound(modelURL.path)
    }

    private static func validateModel(
        kind: ASRModelKind,
        at url: URL,
        artifactProvider: @escaping ArtifactProvider
    ) throws -> URL {
        if isModelInstalled(kind: kind, at: url, artifactProvider: artifactProvider) {
            return url
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw ModelPathError.modelInvalid(
                url.path,
                reason: validationFailureReason(
                    artifact: artifactProvider(kind),
                    at: url
                )
            )
        }
        throw ModelPathError.modelNotFound(url.path)
    }

    private static func validationFailureReason(
        artifact: ASRModelArtifact,
        at url: URL
    ) -> String {
        do {
            try verifyArtifact(artifact, at: url)
            return "artifact verification failed"
        } catch let error as ModelArtifactVerificationError {
            switch error {
            case .fileMissing:
                return "file is missing"
            case .notRegularFile:
                return "path is not a regular file"
            case .unexpectedFileSize(let expected, let actual):
                return "expected \(expected) bytes, found \(actual)"
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch (expected \(expected), found \(actual))"
            }
        } catch {
            return "could not read artifact: \(error)"
        }
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
