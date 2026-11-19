import XCTest

@testable import ChirpCore

final class ShortcutKeysTests: XCTestCase {
    func testARightOptionShortcutIsWrittenWithItsSide() {
        XCTAssertEqual(ShortcutKeys.label(keys: "⌥N", rightOption: true, short: false), "right ⌥ N")
        XCTAssertEqual(ShortcutKeys.label(keys: "⌥N", rightOption: true, short: true), "⌥N")
        // A shortcut the user changed to something else is shown as macOS writes it.
        XCTAssertEqual(ShortcutKeys.label(keys: "⌃⌥M", rightOption: false, short: false), "⌃⌥M")
        XCTAssertEqual(ShortcutKeys.label(keys: "⌥Space", rightOption: false, short: false), "⌥Space")
    }

    func testALetterIsAShortcutOnlyAtTheStartOfAHoldThatDictates() {
        XCTAssertTrue(ShortcutKeys.answers(heldFor: 0.2, holdDictates: true))
        XCTAssertFalse(ShortcutKeys.answers(heldFor: 1.0, holdDictates: true))
        XCTAssertFalse(ShortcutKeys.answers(heldFor: 6, holdDictates: true))
        // With another hold key (or none), right Option is only ever the shortcuts' key.
        XCTAssertTrue(ShortcutKeys.answers(heldFor: 6, holdDictates: false))
    }

    func testTheDictateTileNamesTheHoldKey() {
        XCTAssertEqual(ShortcutKeys.holdLabel("rightOption"), "hold ⌥")
        XCTAssertEqual(ShortcutKeys.holdLabel("fn"), "hold fn")
        XCTAssertEqual(ShortcutKeys.holdLabel("rightCommand"), "hold ⌘")
        XCTAssertNil(ShortcutKeys.holdLabel("none"))
    }

    func testTheShortcutsAnswerOnlyWhileRightOptionIsDown() {
        var window = ShortcutWindow()
        XCTAssertFalse(window.isOpen, "Left Option types its symbols: nothing is registered at rest")
        window.optionDown()
        XCTAssertTrue(window.isOpen)
        window.letterDown("recordNote")
        window.letterUp("recordNote")
        XCTAssertTrue(window.isOpen, "a second letter can follow while the key is still down")
        window.optionUp()
        XCTAssertFalse(window.isOpen)
    }

    func testOptionLetGoBeforeTheLetterStillLetsTheShortcutFinish() {
        // Most of the shortcuts act as the letter comes up; the key must still be registered then.
        var window = ShortcutWindow()
        window.optionDown()
        window.letterDown("summarize")
        window.optionUp()
        XCTAssertTrue(window.isOpen)
        window.letterUp("summarize")
        XCTAssertFalse(window.isOpen)
        // Pressed again before the letter came up: open again, and it does not close under the new press.
        window.optionDown()
        window.letterDown("summarize")
        window.optionUp()
        window.optionDown()
        window.letterUp("summarize")
        XCTAssertTrue(window.isOpen)
        window.optionUp()
        XCTAssertFalse(window.isOpen)
    }

    func testALetterThatNeverComesUpDoesNotKeepTheShortcutsForEver() {
        var window = ShortcutWindow()
        window.optionDown()
        window.letterDown("openLibrary")
        window.optionUp()
        window.giveUp()
        XCTAssertFalse(window.isOpen)
        // Giving up while the key is still held changes nothing.
        window.optionDown()
        window.giveUp()
        XCTAssertTrue(window.isOpen)
    }
}
