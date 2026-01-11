import Foundation

enum ModelPathError: Error {
    case appSupportUnavailable
    case modelNotFound(String)
}

enum ModelPathResolver {
    static func parakeetV3Path() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PARAKEET_MODEL_DIR"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            throw ModelPathError.modelNotFound(url.path)
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelPathError.appSupportUnavailable
        }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.speakeasy.app"
        let candidateIds = bundleId == "com.wisp.app"
            ? [bundleId]
            : [bundleId, "com.wisp.app"]

        func modelURL(for candidateId: String) -> URL {
            appSupport
                .appendingPathComponent(candidateId)
                .appendingPathComponent("models")
                .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
        }

        for candidateId in candidateIds {
            let candidateURL = modelURL(for: candidateId)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        let defaultURL = modelURL(for: candidateIds[0])
        throw ModelPathError.modelNotFound(defaultURL.path)
    }
}
