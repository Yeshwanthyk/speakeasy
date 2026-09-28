import Foundation

/// A unique UserDefaults suite name for one test.
///
/// CFPreferences treats an absolute-path suite name as the plist location, so
/// test suites live in the temporary directory rather than piling up in
/// ~/Library/Preferences (cfprefsd recreates an empty plist there even after
/// `removePersistentDomain(forName:)`).
func testDefaultsSuiteName(_ prefix: String) -> String {
    testScratchDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .path
}

/// Removes a throwaway UserDefaults suite created with `testDefaultsSuiteName`.
func removeTestDefaults(_ suiteName: String) {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(atPath: suiteName + ".plist")
}
