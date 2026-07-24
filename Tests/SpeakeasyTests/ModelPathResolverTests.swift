import Foundation
import XCTest
@testable import Speakeasy

final class ModelPathResolverTests: XCTestCase {
    private static let environmentLock = UnfairLock()

    private func createModelDirectory(kind: ASRModelKind, at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in kind.requiredFiles {
            let fileURL = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: fileURL)
        }
    }

    private func withEnvironment(_ updates: [String: String], _ body: () throws -> Void) rethrows {
        try Self.environmentLock.withLock {
            let previous = updates.keys.reduce(into: [String: String?]()) { result, key in
                result[key] = ProcessInfo.processInfo.environment[key]
            }
            for (key, value) in updates {
                setenv(key, value, 1)
            }
            defer {
                for (key, value) in previous {
                    if let value {
                        setenv(key, value, 1)
                    } else {
                        unsetenv(key)
                    }
                }
            }
            try body()
        }
    }

    func testEnvironmentOverrideReturnsExistingDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createModelDirectory(kind: .parakeetTDT, at: url)

        try withEnvironment(["PARAKEET_MODEL_DIR": url.path]) {
            XCTAssertEqual(try ModelPathResolver.parakeetV3Path(), url)
        }
    }

    func testEnvironmentOverrideThrowsForMissingDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try withEnvironment(["PARAKEET_MODEL_DIR": url.path]) {
            XCTAssertThrowsError(try ModelPathResolver.parakeetV3Path()) { error in
                guard case let ModelPathError.modelNotFound(path) = error else {
                    XCTFail("Expected modelNotFound, got \(error)")
                    return
                }
                XCTAssertEqual(path, url.path)
            }
        }
    }

    func testCanonicalBundlePathReturnsExistingModelDirectory() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app")
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
        try createModelDirectory(kind: .parakeetTDT, at: modelURL)

        let resolved = try ModelPathResolver.parakeetV3Path(
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:]
        )

        XCTAssertEqual(resolved.path, modelURL.path)
    }

    func testLegacyBundlePathFallbackKeepsExistingModelInstallsWorking() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyModelURL = appSupport
            .appendingPathComponent("com.wisp.app")
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
        try createModelDirectory(kind: .parakeetTDT, at: legacyModelURL)

        let resolved = try ModelPathResolver.parakeetV3Path(
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:]
        )

        XCTAssertEqual(resolved.path, legacyModelURL.path)
    }

    func testConfiguredASRModelDefaultsToParakeet() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app")
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
        try createModelDirectory(kind: .parakeetTDT, at: modelURL)

        let resolved = try ModelPathResolver.configuredASRModel(
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:]
        )

        XCTAssertEqual(resolved.kind, .parakeetTDT)
        XCTAssertEqual(resolved.url.path, modelURL.path)
        XCTAssertNil(resolved.language)
    }

    func testConfiguredASRModelReturnsNemotronOverrideAndLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createModelDirectory(kind: .nemotron, at: url)

        let resolved = try ModelPathResolver.configuredASRModel(
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: [
                "SPEAKEASY_ASR_MODEL": "nemotron-3.5-asr",
                "NEMOTRON_MODEL_DIR": url.path,
                "NEMOTRON_TARGET_LANG": "en-US"
            ]
        )

        XCTAssertEqual(resolved.kind, .nemotron)
        XCTAssertEqual(resolved.url.path, url.path)
        XCTAssertEqual(resolved.language, "en-US")
    }

    func testConfiguredASRModelReadsPersistentNemotronPreferences() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createModelDirectory(kind: .nemotron, at: url)

        let resolved = try ModelPathResolver.configuredASRModel(
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            preferences: [
                "ASRModel": "nemotron",
                "NemotronModelDir": url.path,
                "NemotronTargetLang": "auto"
            ]
        )

        XCTAssertEqual(resolved.kind, .nemotron)
        XCTAssertEqual(resolved.url.path, url.path)
        XCTAssertEqual(resolved.language, "auto")
    }

    func testForcedConfiguredASRModelIgnoresPersistedKind() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createModelDirectory(kind: .nemotron, at: url)

        let resolved = try ModelPathResolver.configuredASRModel(
            kind: .nemotron,
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            preferences: [
                "ASRModel": "parakeet-tdt",
                "NemotronModelDir": url.path
            ]
        )

        XCTAssertEqual(resolved.kind, .nemotron)
        XCTAssertEqual(resolved.url.path, url.path)
    }

    func testPersistSelectedModelKindWritesStablePreferenceValue() throws {
        let suiteName = "com.speakeasy.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ModelPathResolver.persistSelectedModelKind(.nemotron, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "ASRModel"), "nemotron-3.5-asr")
    }

    func testIncompleteModelDirectoryThrowsMissingFiles() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app")
            .appendingPathComponent("models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-int8")
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: modelURL.appendingPathComponent("config.json"))

        XCTAssertThrowsError(try ModelPathResolver.parakeetV3Path(
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:]
        )) { error in
            guard case let ModelPathError.modelIncomplete(path, missing) = error else {
                XCTFail("Expected modelIncomplete, got \(error)")
                return
            }
            XCTAssertEqual(path, modelURL.path)
            XCTAssertTrue(missing.contains("encoder-model.int8.onnx"))
        }
    }

    func testZeroByteRequiredFileIsNotTreatedAsInstalled() throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createModelDirectory(kind: .nemotron, at: modelURL)
        let emptyFile = modelURL.appendingPathComponent("encoder.onnx")
        try Data().write(to: emptyFile)

        XCTAssertFalse(ModelPathResolver.isModelInstalled(kind: .nemotron, at: modelURL))
        XCTAssertTrue(
            ModelPathResolver.missingRequiredFiles(kind: .nemotron, at: modelURL)
                .contains("encoder.onnx")
        )
    }

    func testConfiguredASRModelRejectsUnknownModel() {
        XCTAssertThrowsError(try ModelPathResolver.configuredASRModel(
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: ["SPEAKEASY_ASR_MODEL": "whisper"]
        )) { error in
            guard case let ModelPathError.unsupportedModel(value) = error else {
                XCTFail("Expected unsupportedModel, got \(error)")
                return
            }
            XCTAssertEqual(value, "whisper")
        }
    }
}
