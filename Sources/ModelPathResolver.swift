import Foundation

enum ModelPathError: Error {
    case appSupportUnavailable
    case unsupportedModel(String)
    case modelNotFound(String)
    case modelIncomplete(String, missing: [String])
}

enum ASRModelKind: CaseIterable, Equatable, Sendable {
    case parakeetTDT
    case nemotron

    init(environmentValue: String?) throws {
        guard let environmentValue = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentValue.isEmpty else {
            self = .parakeetTDT
            return
        }

        switch environmentValue.lowercased() {
        case "parakeet", "parakeet-tdt", "parakeet-v3":
            self = .parakeetTDT
        case "nemotron", "nemotron-3", "nemotron-3.5", "nemotron-3.5-asr":
            self = .nemotron
        default:
            throw ModelPathError.unsupportedModel(environmentValue)
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
        case .parakeetTDT:
            return "Parakeet TDT"
        case .nemotron:
            return "Nemotron 3.5 ASR"
        }
    }

    var preferenceValue: String {
        switch self {
        case .parakeetTDT:
            return "parakeet-tdt"
        case .nemotron:
            return "nemotron-3.5-asr"
        }
    }

    var defaultDirectoryName: String {
        switch self {
        case .parakeetTDT:
            return "parakeet-tdt-0.6b-v3-int8"
        case .nemotron:
            return "nemotron-3.5-asr-streaming-0.6b-int8"
        }
    }

    var overrideEnvironmentKey: String {
        switch self {
        case .parakeetTDT:
            return "PARAKEET_MODEL_DIR"
        case .nemotron:
            return "NEMOTRON_MODEL_DIR"
        }
    }

    var overridePreferenceKey: String {
        switch self {
        case .parakeetTDT:
            return "ParakeetModelDir"
        case .nemotron:
            return "NemotronModelDir"
        }
    }

    var requiredFiles: [String] {
        switch self {
        case .parakeetTDT:
            return [
                "config.json",
                "decoder_joint-model.int8.onnx",
                "encoder-model.int8.onnx",
                "nemo128.onnx",
                "vocab.txt"
            ]
        case .nemotron:
            return [
                "decoder_joint.onnx",
                "encoder.onnx",
                "encoder.onnx.data",
                "tokenizer.model"
            ]
        }
    }
}

struct ASRModelConfiguration: Equatable, Sendable {
    let kind: ASRModelKind
    let url: URL
    let language: String?
}

enum ModelPathResolver {
    private static let canonicalBundleIdentifier = "com.speakeasy.app"
    private static let legacyBundleIdentifier = "com.wisp.app"
    private static let modelKindEnvironmentKey = "SPEAKEASY_ASR_MODEL"
    private static let legacyModelKindEnvironmentKey = "WISP_ASR_MODEL"
    private static let modelKindPreferenceKey = "ASRModel"
    private static let languageEnvironmentKey = "NEMOTRON_TARGET_LANG"
    private static let languagePreferenceKey = "NemotronTargetLang"

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
        let kindValue = environment[modelKindEnvironmentKey]
            ?? environment[legacyModelKindEnvironmentKey]
            ?? preferences[modelKindPreferenceKey]
            ?? preferences[legacyModelKindEnvironmentKey]
        let kind = try ASRModelKind(environmentValue: kindValue)
        let url = try modelPath(
            kind: kind,
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            preferences: preferences
        )
        let language = kind == .nemotron
            ? (environment[languageEnvironmentKey] ?? preferences[languagePreferenceKey])?.nilIfEmpty
            : nil
        return ASRModelConfiguration(kind: kind, url: url, language: language)
    }

    static func configuredASRModel(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String] = [:]
    ) throws -> ASRModelConfiguration {
        let url = try modelPath(
            kind: kind,
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            preferences: preferences
        )
        let language = kind == .nemotron
            ? (environment[languageEnvironmentKey] ?? preferences[languagePreferenceKey])?.nilIfEmpty
            : nil
        return ASRModelConfiguration(kind: kind, url: url, language: language)
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
        if let override = (environment[kind.overrideEnvironmentKey] ?? preferences[kind.overridePreferenceKey])?.nilIfEmpty {
            return URL(fileURLWithPath: override)
        }

        return makeModelURL(
            appSupport: appSupport,
            bundleIdentifier: canonicalBundleIdentifier,
            kind: kind
        )
    }

    static func isModelInstalled(kind: ASRModelKind, at url: URL) -> Bool {
        missingRequiredFiles(kind: kind, at: url).isEmpty
    }

    static func missingRequiredFiles(kind: ASRModelKind, at url: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return kind.requiredFiles
        }

        return kind.requiredFiles.filter { file in
            let fileURL = url.appendingPathComponent(file)
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return true
            }
            return values.isRegularFile != true || (values.fileSize ?? 0) == 0
        }
    }

    static func parakeetV3Path() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        return try modelPath(
            kind: .parakeetTDT,
            appSupport: appSupport,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func parakeetV3Path(
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String]
    ) throws -> URL {
        try modelPath(
            kind: .parakeetTDT,
            appSupport: appSupport,
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
    }

    private static func modelPath(
        kind: ASRModelKind,
        appSupport: URL,
        bundleIdentifier: String?,
        environment: [String: String],
        preferences: [String: String] = [:]
    ) throws -> URL {
        if let override = (environment[kind.overrideEnvironmentKey] ?? preferences[kind.overridePreferenceKey])?.nilIfEmpty {
            let url = URL(fileURLWithPath: override)
            if isModelInstalled(kind: kind, at: url) {
                return url
            }
            if FileManager.default.fileExists(atPath: url.path) {
                throw ModelPathError.modelIncomplete(
                    url.path,
                    missing: missingRequiredFiles(kind: kind, at: url)
                )
            }
            throw ModelPathError.modelNotFound(url.path)
        }

        let bundleId = bundleIdentifier ?? canonicalBundleIdentifier
        let modelURL = makeModelURL(appSupport: appSupport, bundleIdentifier: bundleId, kind: kind)

        if isModelInstalled(kind: kind, at: modelURL) {
            return modelURL
        }

        if bundleId != legacyBundleIdentifier {
            let legacyModelURL = makeModelURL(
                appSupport: appSupport,
                bundleIdentifier: legacyBundleIdentifier,
                kind: kind
            )
            if isModelInstalled(kind: kind, at: legacyModelURL) {
                return legacyModelURL
            }
        }

        if FileManager.default.fileExists(atPath: modelURL.path) {
            throw ModelPathError.modelIncomplete(
                modelURL.path,
                missing: missingRequiredFiles(kind: kind, at: modelURL)
            )
        }

        throw ModelPathError.modelNotFound(modelURL.path)
    }

    private static func makeModelURL(appSupport: URL, bundleIdentifier: String, kind: ASRModelKind) -> URL {
        appSupport
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("models")
            .appendingPathComponent(kind.defaultDirectoryName)
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
