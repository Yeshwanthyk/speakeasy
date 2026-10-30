import Carbon
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

final class PasteKeyCodeCacheTests: XCTestCase {
    func testMainThreadMissResolvesOnceThenServesTheCachedKey() {
        var resolved: [Character] = []
        let cache = PasteKeyCodeCache { character, fallback in
            resolved.append(character)
            return character == "v" ? 47 : fallback
        }

        XCTAssertEqual(cache.current(), 47)
        XCTAssertEqual(cache.current(), 47)
        XCTAssertEqual(resolved, ["v"])
    }

    func testRefreshPrewarmsPasteAndUndoAndPicksUpLayoutChanges() {
        var layoutV: CGKeyCode = 9
        var resolutionCount = 0
        let cache = PasteKeyCodeCache { character, fallback in
            resolutionCount += 1
            return character == "v" ? layoutV : fallback
        }

        cache.refresh()
        XCTAssertEqual(resolutionCount, PasteKeyCodeCache.prewarmedKeys.count)
        XCTAssertEqual(cache.current(), 9)
        XCTAssertEqual(
            cache.keyCode(for: "z", fallback: PasteKeyResolver.undoFallbackKeyCode),
            PasteKeyResolver.undoFallbackKeyCode
        )
        XCTAssertEqual(resolutionCount, PasteKeyCodeCache.prewarmedKeys.count)

        layoutV = 47
        cache.refresh()
        XCTAssertEqual(cache.current(), 47)
    }

    func testOffMainMissFallsBackWithoutReadingInputSourcesAndIsResolvedOnRefresh() {
        let lock = NSLock()
        var resolved: [Character] = []
        let cache = PasteKeyCodeCache { character, _ in
            lock.withLock { resolved.append(character) }
            return 31
        }

        let offMain = expectation(description: "off-main lookup")
        var offMainKey: CGKeyCode?
        DispatchQueue.global().async {
            offMainKey = cache.keyCode(for: "q", fallback: 12)
            offMain.fulfill()
        }
        wait(for: [offMain], timeout: 1)

        XCTAssertEqual(offMainKey, 12)
        XCTAssertEqual(lock.withLock { resolved }, [])

        cache.refresh()
        XCTAssertTrue(lock.withLock { resolved.contains("q") })

        let afterRefresh = expectation(description: "off-main lookup after refresh")
        DispatchQueue.global().async {
            offMainKey = cache.keyCode(for: "q", fallback: 12)
            afterRefresh.fulfill()
        }
        wait(for: [afterRefresh], timeout: 1)
        XCTAssertEqual(offMainKey, 31)
    }

    func testStartMonitoringPrewarmsTheCache() {
        var resolutionCount = 0
        let cache = PasteKeyCodeCache { _, fallback in
            resolutionCount += 1
            return fallback
        }

        cache.startMonitoring()
        XCTAssertEqual(resolutionCount, PasteKeyCodeCache.prewarmedKeys.count)
        _ = cache.current()
        XCTAssertEqual(resolutionCount, PasteKeyCodeCache.prewarmedKeys.count)
    }

    func testObserverListensForLayoutSelectionChanges() {
        XCTAssertTrue(
            InputSourceChangeObserver.notificationNames.contains(
                Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
            )
        )
    }
}

private struct FakeLayout: KeyboardLayoutTranslating {
    var plain: [UInt16: String]
    var command: [UInt16: String] = [:]

    func character(for keyCode: UInt16, command isCommand: Bool) -> String? {
        isCommand ? command[keyCode] : plain[keyCode]
    }
}
