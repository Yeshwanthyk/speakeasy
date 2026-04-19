import Foundation

enum ModelPathError: Error {
    case appSupportUnavailable
    case modelNotFound(String)
}

enum ModelPathResolver {
    private static let canonicalBundleIdentifier = "com.wisp.app"
    private static let legacyBundleIdentifier = "com.speakeasy.app"

    static func parakeetV3Path() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        return try parakeetV3Path(
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
        if let override = environment["PARAKEET_MODEL_DIR"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            throw ModelPathError.modelNotFound(url.path)
        }

        let bundleId = bundleIdentifier ?? canonicalBundleIdentifier
        let modelURL = makeModelURL(appSupport: appSupport, bundleIdentifier: bundleId)

        if FileManager.default.fileExists(atPath: modelURL.path) {
            return modelURL
        }

        if bundleId != legacyBundleIdentifier {
            let legacyModelURL = makeModelURL(appSupport: appSupport, bundleIdentifier: legacyBundleIdentifier)
            if FileManager.default.fileExists(atPath: legacyModelURL.path) {
                return legacyModelURL
            }
        }

        throw ModelPathError.modelNotFound(modelURL.path)
    }

    private static func makeModelURL(appSupport: URL, bundleIdentifier: String) -> URL {
        appSupport
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
    }
}
