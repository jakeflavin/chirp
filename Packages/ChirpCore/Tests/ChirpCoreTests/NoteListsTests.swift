import Foundation
import Testing

@testable import ChirpCore

/// Lists in a note behave as in Apple Notes.
@Suite struct NoteListsTests {
    @Test func returnInAPointStartsTheNextOne() {
        #expect(NoteLists.onReturn(lineBefore: "- first point") == .next("- "))
        #expect(NoteLists.onReturn(lineBefore: "* first") == .next("* "))
        #expect(NoteLists.onReturn(lineBefore: "  + nested") == .next("  + "))
        #expect(NoteLists.onReturn(lineBefore: "1. one") == .next("2. "))
        #expect(NoteLists.onReturn(lineBefore: "9) nine") == .next("10) "))
        #expect(NoteLists.onReturn(lineBefore: "Just a line") == .plain)
        #expect(NoteLists.onReturn(lineBefore: "-not a point") == .plain)
        #expect(NoteLists.onReturn(lineBefore: "") == .plain)
    }

    @Test func returnOnAnEmptyPointEndsTheList() {
        #expect(NoteLists.onReturn(lineBefore: "- ") == .endList(markerLength: 2))
        #expect(NoteLists.onReturn(lineBefore: "  -   ") == .endList(markerLength: 6))
        #expect(NoteLists.onReturn(lineBefore: "3. ") == .endList(markerLength: 3))
    }

    @Test func typingAMarkerOnAContinuedOneReplacesIt() {
        // "- " continued, then "- " typed: stays "- ", not "- - ".
        #expect(NoteLists.onType(" ", lineBefore: "- -") == "- ")
        #expect(NoteLists.onType(" ", lineBefore: "* *") == "* ")
        #expect(NoteLists.onType(" ", lineBefore: "- *") == "* ")
        // A number typed on a bullet makes it numbered, and the other way round.
        #expect(NoteLists.onType(" ", lineBefore: "- 1.") == "1. ")
        #expect(NoteLists.onType(" ", lineBefore: "2. -") == "- ")
        // Indent is kept.
        #expect(NoteLists.onType(" ", lineBefore: "  - -") == "  - ")
    }

    @Test func otherTypingIsLeftAlone() {
        #expect(NoteLists.onType(" ", lineBefore: "- ") == nil)
        #expect(NoteLists.onType(" ", lineBefore: "- word") == nil)
        #expect(NoteLists.onType("x", lineBefore: "- -") == nil)
        #expect(NoteLists.onType(" ", lineBefore: "a - -") == nil)
        #expect(NoteLists.onType(" ", lineBefore: "- --") == nil)
    }

    @Test func aNoteClosedAfterReturnInAListHasNoStrayMarker() {
        #expect(NoteLists.droppingEmptyLastPoint("Plan\n- one\n- two\n- ") == "Plan\n- one\n- two")
        #expect(NoteLists.droppingEmptyLastPoint("- one\n-") == "- one")
        #expect(NoteLists.droppingEmptyLastPoint("1. one\n2. \n") == "1. one")
        // Nothing to drop.
        #expect(NoteLists.droppingEmptyLastPoint("- one\n- two") == "- one\n- two")
        #expect(NoteLists.droppingEmptyLastPoint("A line\n-") == "A line\n-")
        #expect(NoteLists.droppingEmptyLastPoint("") == "")
    }
}

/// Deleting says what the item has.
@Suite struct DeleteWarningTests {
    @Test func aNoteSaysWhatANoteHas() {
        #expect(SavedItem(kind: .voiceNote).deleteWarning == "This note is removed from this Mac.")
        #expect(SavedItem(kind: .voiceNote, audioFile: "a.m4a", duration: 30).deleteWarning == "This note and its audio are removed from this Mac.")
        #expect(SavedItem(kind: .meeting).deleteWarning == "The notes, transcript and recording are removed from this Mac.")
        #expect(SavedItem(kind: .document).deleteWarning == "It is removed from this Mac.")
    }
}
