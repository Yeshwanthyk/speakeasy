import XCTest
@testable import Wisp

final class WordCorrectorTests: XCTestCase {
    func testReplacesWholeWordsCaseInsensitive() {
        let content = """
        foo -> bar
        # comment
        baz
        """
        let corrector = WordCorrector(dictionaryContents: content)
        let result = corrector.correct("Foo food baz BAZ.")
        XCTAssertEqual(result, "bar food baz BAZ.")
    }

    func testAppliesMultipleReplacements() {
        let content = """
        alpha -> beta
        omega -> end
        """
        let corrector = WordCorrector(dictionaryContents: content)
        let result = corrector.correct("Alpha and omega.")
        XCTAssertEqual(result, "beta and end.")
    }

    func testIgnoresInvalidLines() {
        let content = """
        -> missing
        missing ->
        # only comment
        valid -> ok
        """
        let corrector = WordCorrector(dictionaryContents: content)
        let result = corrector.correct("valid missing")
        XCTAssertEqual(result, "ok missing")
    }

    func testNoReplacementsReturnsOriginal() {
        let content = """
        word
        another
        """
        let corrector = WordCorrector(dictionaryContents: content)
        let text = "word another"
        XCTAssertEqual(corrector.correct(text), text)
    }
}
