import XCTest
@testable import Speakeasy

final class PasteKeyResolverTests: XCTestCase {
    private static let ansiV: UInt16 = 9
    private static let ansiPeriod: UInt16 = 47

    func testQwertyResolvesToAnsiV() {
        let layout = FakeLayout(plain: [Self.ansiV: "v"])

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: layout, asciiCapable: nil), Self.ansiV)
    }

    func testDvorakResolvesToThePhysicalKeyThatTypesV() {
        // Dvorak types "v" on the key that QWERTY labels ".".
        let layout = FakeLayout(plain: [Self.ansiPeriod: "v", Self.ansiV: "k"])

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: layout, asciiCapable: nil), Self.ansiPeriod)
    }

    func testCommandLayerWinsForDvorakQwertyCommand() {
        // "Dvorak - QWERTY ⌘" switches to QWERTY while Command is held.
        let layout = FakeLayout(
            plain: [Self.ansiPeriod: "v", Self.ansiV: "k"],
            command: [Self.ansiV: "v", Self.ansiPeriod: "."]
        )

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: layout, asciiCapable: nil), Self.ansiV)
    }

    func testNonLatinLayoutFallsBackToAsciiCapableLayout() {
        let russian = FakeLayout(plain: [Self.ansiV: "м"])
        let latin = FakeLayout(plain: [Self.ansiPeriod: "v"])

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: russian, asciiCapable: latin), Self.ansiPeriod)
    }

    func testUnresolvableLayoutsFallBackToAnsiV() {
        let empty = FakeLayout(plain: [:])

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: empty, asciiCapable: empty), Self.ansiV)
        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: nil, asciiCapable: nil), Self.ansiV)
    }

    func testMatchingIgnoresCaseAndPrefersTheLowestKeyCode() {
        let layout = FakeLayout(plain: [30: "V", 40: "v"])

        XCTAssertEqual(PasteKeyResolver.keyCode(for: "v", current: layout, asciiCapable: nil), 30)
    }
}

private struct FakeLayout: KeyboardLayoutTranslating {
    var plain: [UInt16: String]
    var command: [UInt16: String] = [:]

    func character(for keyCode: UInt16, command isCommand: Bool) -> String? {
        isCommand ? command[keyCode] : plain[keyCode]
    }
}
