import Testing
@testable import ChirpCore

@Suite struct InsertionTests {
    @Test func unknownSurroundingsKeepTheOldBehaviour() {
        #expect(Insertion.adapt("Hello there.", before: nil, after: nil) == "Hello there. ")
    }

    @Test func emptyFieldGetsNoLeadingSpace() {
        #expect(Insertion.adapt("Hello there.", before: "", after: "") == "Hello there. ")
    }

    @Test func addsASpaceAfterExistingText() {
        #expect(Insertion.adapt("Next sentence.", before: "First sentence.", after: "") == " Next sentence. ")
        #expect(Insertion.adapt("Next sentence.", before: "First sentence. ", after: "") == "Next sentence. ")
    }

    @Test func continuingASentenceLowersACommonFirstWord() {
        #expect(Insertion.adapt("And then we left.", before: "We ate lunch", after: "") == " and then we left. ")
        #expect(Insertion.adapt("The report is late.", before: "I think, ", after: "") == "the report is late. ")
    }

    @Test func namesAndIStayCapitalised() {
        #expect(Insertion.adapt("John said yes.", before: "I talked to", after: "") == " John said yes. ")
        #expect(Insertion.adapt("I agree.", before: "She said that", after: "") == " I agree. ")
        #expect(Insertion.adapt("OK then.", before: "well", after: "") == " OK then. ")
    }

    @Test func newSentenceOrLineKeepsItsCapital() {
        #expect(Insertion.adapt("The end.", before: "Done.\n", after: "") == "The end. ")
        #expect(Insertion.adapt("The end.", before: "Done. ", after: "") == "The end. ")
    }

    @Test func noTrailingSpaceBeforePunctuationOrSpace() {
        #expect(Insertion.adapt("really", before: "It was ", after: " good.") == "really")
        #expect(Insertion.adapt("really", before: "It was ", after: ".") == "really")
        #expect(Insertion.adapt("really", before: "It was ", after: "good") == "really ")
    }

    @Test func noSpaceAfterAnOpeningBracket() {
        #expect(Insertion.adapt("see below", before: "Notes (", after: ")") == "see below")
    }

    @Test func pressEnterIsACommand() {
        #expect(SpokenCommands.trailingEnter("Sounds good, press enter.") == ("Sounds good.", true))
        #expect(SpokenCommands.trailingEnter("On my way. Press enter") == ("On my way.", true))
        #expect(SpokenCommands.trailingEnter("Then press enter to continue.") == ("Then press enter to continue.", false))
        #expect(SpokenCommands.trailingEnter("Hello.") == ("Hello.", false))
    }
}
