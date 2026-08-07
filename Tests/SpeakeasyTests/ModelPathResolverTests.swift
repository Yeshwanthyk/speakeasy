import Foundation
import XCTest
@testable import Speakeasy

final class ModelPathResolverTests: XCTestCase {
    private static let testArtifact = ASRModelArtifact(
        repository: "example/test",
        revision: "0123456789abcdef",
        filename: "model.gguf",
        expectedByteCount: 4,
        sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    )

    private func createModelFile(_ contents: Data, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
    }

    func testEnvironmentOverrideReturnsExistingGGUF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(ASRModelKind.parakeetUnified.artifact.filename)
        try createModelFile(Data("test".utf8), at: url)

        let resolved = try ModelPathResolver.configuredASRModel(
            kind: .parakeetUnified,
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: ["PARAKEET_UNIFIED_GGUF_PATH": url.path],
            artifactProvider: { _ in Self.testArtifact }
        )

        XCTAssertEqual(resolved.url, url)
    }

    func testEnvironmentOverrideThrowsForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ModelPathResolver.configuredASRModel(
            kind: .parakeetUnified,
            appSupport: FileManager.default.temporaryDirectory,
            bundleIdentifier: "com.speakeasy.app",
            environment: ["PARAKEET_UNIFIED_GGUF_PATH": url.path]
        )) { error in
            guard case let ModelPathError.modelNotFound(path) = error else {
                return XCTFail("Expected modelNotFound, got \(error)")
            }
            XCTAssertEqual(path, url.path)
        }
    }

    func testConfiguredModelDefaultsToUnifiedParakeet() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakeasy-model-path-tests")
            .appendingPathComponent(UUID().uuidString)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app")
            .appendingPathComponent("models")
            .appendingPathComponent(ASRModelKind.parakeetUnified.artifact.filename)
        try createModelFile(Data("test".utf8), at: modelURL)

        let resolved = try ModelPathResolver.configuredASRModel(
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            artifactProvider: { _ in Self.testArtifact }
        )

        XCTAssertEqual(resolved.kind, .parakeetUnified)
        XCTAssertEqual(resolved.url, modelURL)
        XCTAssertNil(resolved.language)
    }

    func testLegacyPreferenceAliasesResolveToGGUFKinds() throws {
        XCTAssertEqual(
            try ModelPathResolver.configuredASRModelKind(
                environment: [:],
                preferences: ["ASRModel": "parakeet-tdt"]
            ),
            .parakeetTDT
        )
        XCTAssertEqual(
            try ModelPathResolver.configuredASRModelKind(
                environment: ["WISP_ASR_MODEL": "nemotron-3.5-asr"]
            ),
            .nemotron
        )
    }

    func testCanonicalPathUsesPinnedArtifactFilename() {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = ModelPathResolver.preferredInstallURL(
            kind: .nemotron,
            appSupport: appSupport,
            environment: [:]
        )

        XCTAssertEqual(
            url.path,
            appSupport
                .appendingPathComponent("com.speakeasy.app/models")
                .appendingPathComponent(ASRModelKind.nemotron.artifact.filename)
                .path
        )
    }

    func testLegacyBundlePathFallbackFindsGGUF() throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyURL = appSupport
            .appendingPathComponent("com.wisp.app/models")
            .appendingPathComponent(ASRModelKind.parakeetTDT.artifact.filename)
        try createModelFile(Data("test".utf8), at: legacyURL)

        let resolved = try ModelPathResolver.configuredASRModel(
            kind: .parakeetTDT,
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            artifactProvider: { _ in Self.testArtifact }
        )

        XCTAssertEqual(resolved.url, legacyURL)
    }

    func testWrongSizedGGUFIsRejected() throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app/models")
            .appendingPathComponent(ASRModelKind.parakeetUnified.artifact.filename)
        try createModelFile(Data("no".utf8), at: modelURL)

        XCTAssertFalse(ModelPathResolver.isModelInstalled(
            kind: .parakeetUnified,
            at: modelURL,
            artifactProvider: { _ in Self.testArtifact }
        ))
        XCTAssertThrowsError(try ModelPathResolver.configuredASRModel(
            kind: .parakeetUnified,
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            artifactProvider: { _ in Self.testArtifact }
        )) { error in
            guard case let ModelPathError.modelInvalid(path, _) = error else {
                return XCTFail("Expected modelInvalid, got \(error)")
            }
            XCTAssertEqual(path, modelURL.path)
        }
    }

    func testSameSizedCorruptGGUFIsRejectedByChecksum() throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelURL = appSupport
            .appendingPathComponent("com.speakeasy.app/models")
            .appendingPathComponent(ASRModelKind.parakeetUnified.artifact.filename)
        try createModelFile(Data("nope".utf8), at: modelURL)

        XCTAssertFalse(ModelPathResolver.isModelInstalled(
            kind: .parakeetUnified,
            at: modelURL,
            artifactProvider: { _ in Self.testArtifact }
        ))
        XCTAssertThrowsError(try ModelPathResolver.configuredASRModel(
            kind: .parakeetUnified,
            appSupport: appSupport,
            bundleIdentifier: "com.speakeasy.app",
            environment: [:],
            artifactProvider: { _ in Self.testArtifact }
        )) { error in
            guard case let ModelPathError.modelInvalid(path, reason) = error else {
                return XCTFail("Expected modelInvalid, got \(error)")
            }
            XCTAssertEqual(path, modelURL.path)
            XCTAssertTrue(reason.contains("SHA-256 mismatch"))
        }
    }

    func testPersistSelectedModelKindWritesStablePreference() throws {
        let suiteName = "com.speakeasy.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ModelPathResolver.persistSelectedModelKind(.parakeetUnified, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "ASRModel"), "parakeet-unified-en")
    }

    func testConfiguredASRModelRejectsUnknownModel() {
        XCTAssertThrowsError(try ModelPathResolver.configuredASRModelKind(
            environment: ["SPEAKEASY_ASR_MODEL": "whisper"]
        )) { error in
            guard case let ModelPathError.unsupportedModel(value) = error else {
                return XCTFail("Expected unsupportedModel, got \(error)")
            }
            XCTAssertEqual(value, "whisper")
        }
    }
}
