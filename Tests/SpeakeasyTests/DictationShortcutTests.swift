import AppKit
import XCTest
@testable import Speakeasy

final class DictationShortcutTests: XCTestCase {
    func testFunctionKeyIsTheDefaultShortcut() {
        let suiteName = "speakeasy-shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DictationShortcutStore.selected(defaults: defaults), .functionKey)
        XCTAssertEqual(DictationShortcut.defaultShortcut.displayName, "fn")
    }

    func testKeyCombinationFormatsModifiersInMacOrder() {
        let shortcut = DictationShortcut.keyCombination(
            keyCode: 49,
            modifiers: [.command, .control, .shift],
            keyLabel: "space"
        )

        XCTAssertEqual(shortcut.displayName, "⌃⇧⌘SPACE")
        XCTAssertTrue(shortcut.isValid)
    }

    func testShortcutPersistsAndReloads() {
        let suiteName = "speakeasy-shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = DictationShortcut.keyCombination(
            keyCode: 1,
            modifiers: [.control, .option],
            keyLabel: "s"
        )

        DictationShortcutStore.persist(shortcut, defaults: defaults)

        XCTAssertEqual(DictationShortcutStore.selected(defaults: defaults), shortcut)
    }

    func testCorruptStoredShortcutFallsBackToFunctionKey() {
        let suiteName = "speakeasy-shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("corrupt".utf8), forKey: "dictationShortcut")

        XCTAssertEqual(DictationShortcutStore.selected(defaults: defaults), .functionKey)
    }
}
