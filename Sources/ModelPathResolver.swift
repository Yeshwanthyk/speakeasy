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

        let modelURL = appSupport
            .appendingPathComponent("com.wisp.app")
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")

        if FileManager.default.fileExists(atPath: modelURL.path) {
            return modelURL
        }

        throw ModelPathError.modelNotFound(modelURL.path)
    }
}
