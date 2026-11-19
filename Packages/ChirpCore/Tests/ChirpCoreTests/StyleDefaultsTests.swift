import XCTest

@testable import ChirpCore

/// The "Your style" switches are on until the user changes one, except "Say
/// punctuation aloud" (the speech model already punctuates, and "period" can be meant as a word).
final class StyleDefaultsTests: XCTestCase {
    func testEverySwitchIsOnExceptSpokenPunctuation() throws {
        let fresh = WritingProfile()
        XCTAssertTrue(fresh.removeFillers)
        XCTAssertTrue(fresh.collapseRepeats)
        XCTAssertTrue(fresh.handleSelfCorrections)
        XCTAssertTrue(fresh.spokenLineBreaks)
        XCTAssertFalse(fresh.spokenPunctuation)
        // A new library answers with the same.
        XCTAssertEqual(try PersonalLanguage(store: try ChirpStore()).profile(), fresh)
    }

    func testAProfileSavedBeforeASwitchExistedTakesItsDefault() throws {
        // Only the fields the user had when they saved: the rest come on (or stay off) as above.
        let old = try JSONDecoder().decode(WritingProfile.self, from: Data(#"{"styleNotes":"Short sentences.","removeFillers":false}"#.utf8))
        XCTAssertFalse(old.removeFillers)
        XCTAssertTrue(old.collapseRepeats)
        XCTAssertTrue(old.handleSelfCorrections)
        XCTAssertTrue(old.spokenLineBreaks)
        XCTAssertFalse(old.spokenPunctuation)
        XCTAssertEqual(old.styleNotes, "Short sentences.")
    }
}
