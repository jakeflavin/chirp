import Foundation
import Testing

@testable import ChirpCore

/// One test per defect found in a review. Each failed before its fix.
@Suite struct SpokenListRegressionTests {
    @Test func bareNumbersAfterACommaDoNotStartAList() {
        let text = "We left, 1 person stayed, 2 went home, 3 came back."
        #expect(SpokenLists.format(text) == text)
    }

    @Test func bareNumbersAtTheStartOfASentenceStillDo() {
        #expect(SpokenLists.format("To do. 1 wash up, 2 dry up, 3 put away.") == "To do.\n1. Wash up\n2. Dry up\n3. Put away")
        #expect(SpokenLists.format("1 wash up, 2 dry up, 3 put away") == "1. Wash up\n2. Dry up\n3. Put away")
        #expect(SpokenLists.format("Jobs:\n1 wash up, 2 dry up, 3 put away") == "Jobs:\n1. Wash up\n2. Dry up\n3. Put away")
    }
}

@Suite struct ModelIssueRegressionTests {
    @Test func aLineSeparatorDoesNotShiftTheFlaggedWord() {
        let original = "one\u{2028}two thre four"
        let issues = Proofreading.modelIssues(original: original, corrected: "one\u{2028}two three four")
        #expect(issues.map { $0.flagged(in: original) } == ["thre"])
        #expect(issues.first?.suggestions == [Fix(kind: .replace, text: "three")])
    }

    @Test func aTabDoesNotShiftTheFlaggedWord() {
        let original = "a\tb teh c d e"
        let issues = Proofreading.modelIssues(original: original, corrected: "a\tb the c d e")
        #expect(issues.map { $0.flagged(in: original) } == ["teh"])
    }

    @Test func aChangedLastWordAfterALineSeparatorDoesNotCrash() {
        let original = "one\u{2028}two three fuor"
        let issues = Proofreading.modelIssues(original: original, corrected: "one\u{2028}two three four")
        #expect(issues.map { $0.flagged(in: original) } == ["fuor"])
    }
}

@Suite struct FixRegressionTests {
    @Test func anIssueThatEndsBeforeItStartsIsLeftAlone() {
        let backwards = WritingIssue(start: 5, end: 3, rule: "R", kind: "Spelling", message: "")
        for kind in [Fix.Kind.replace, .insert, .remove] {
            let result = Proofreading.apply(Fix(kind: kind, text: "x"), to: backwards, in: "hello world")
            #expect(result.text == "hello world")
            #expect(result.delta == 0)
        }
    }

    private func issue(_ word: String, _ fix: String, in text: String) -> WritingIssue {
        let r = (text as NSString).range(of: word)
        return WritingIssue(start: r.location, end: NSMaxRange(r), rule: word, kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: fix)])
    }

    @Test func aNameLeftAloneDoesNotMoveTheCursor() {
        let text = "I met Priyaa and alot of dogs stop"
        let issues = [issue("Priyaa", "Priya", in: text), issue("alot", "a lot", in: text)]
        let fixed = Proofreading.fixAll(issues, in: text)
        #expect(fixed == "I met Priyaa and a lot of dogs stop")
        let stop = (text as NSString).range(of: "stop").location
        let moved = Proofreading.position(stop, afterFixing: issues, in: text)
        #expect((fixed as NSString).substring(from: moved) == "stop")
        // Inside the name nothing changed, so the cursor stays where it was.
        let inside = (text as NSString).range(of: "Priyaa").location + 2
        #expect(Proofreading.position(inside, afterFixing: issues, in: text) == inside)
    }

    @Test func aSentenceFixCountsOnlyWhatItChanges() {
        let text = "Ask Priyaa about teh plan."
        let issues = [issue("Priyaa", "Priya", in: text), issue("teh", "the", in: text)]
        let fix = Proofreading.sentenceFix(in: text, caret: (text as NSString).length, issues: issues)
        #expect(fix?.replacement == "Ask Priyaa about the plan.")
        #expect(fix?.count == 1)
    }
}

@Suite struct SpeechTextRegressionTests {
    private func said(_ s: String) -> String { SpeechText.spoken(s) }

    @Test func aLoneCOrLIsALetterNotANumeral() {
        #expect(said("See Appendix C for the Type C cable.") == "See Appendix C for the Type C cable.")
        #expect(said("Class L and Level C are full.") == "Class L and Level C are full.")
        #expect(said("John L. Sullivan fought.") == "John L. Sullivan fought.")
        // The numerals a single letter usually is still count.
        #expect(said("Part I and Phase V") == "Part 1 and Phase 5")
        #expect(said("Section XC and Charles V") == "Section 90 and Charles the fifth")
    }

    @Test func ordinalsPastTwentyEndTheRightWay() {
        #expect(said("Pope John XXIII and Louis XXI") == "Pope John the 23rd and Louis the 21st")
        #expect(SpeechText.ordinal(22) == "22nd")
        #expect(SpeechText.ordinal(24) == "24th")
        #expect(SpeechText.ordinal(91) == "91st")
        #expect(SpeechText.ordinal(100) == nil)
    }

    @Test func anAccentWrittenAsASeparateMarkIsStillHandled() {
        #expect(said("The cafe\u{301} is open.") == "The cafay is open.")
        #expect(said("A nai\u{308}ve plan.") == "A naive plan.")
    }

    @Test func joinedEmojiLeaveNothingBehind() {
        #expect(said("Family 👨‍👩‍👧 photo") == "Family photo")
    }

    @Test func markdownKeepsTheBlankLinesBetweenParagraphs() {
        #expect(SpeechText.markdown("Intro\n\n- item\n\n# Head\n\n> quote") == "Intro\n\nitem\n\nHead\n\nquote")
    }
}

@Suite struct ReadingRegressionTests {
    @Test func aPronunciationForATermEndingInASymbolIsUsed() {
        #expect(ReadingText.spoken("I write C++ daily.", pronunciations: ["C++": "C plus plus"]) == "I write C plus plus daily.")
        // Still whole words only.
        #expect(ReadingText.spoken("The category is cats.", pronunciations: ["cat": "feline"]) == "The category is cats.")
    }

    @Test func aPronunciationIsUsedAsWritten() {
        #expect(ReadingText.spoken("Use the slash key.", pronunciations: ["slash": "back\\slash"]) == "Use the back\\slash key.")
    }

    @Test func theLongerTermWinsWhenTwoOverlap() {
        for _ in 0..<5 {
            #expect(ReadingText.spoken("Ask Anna Lee.", pronunciations: ["Anna": "Ah-na", "Anna Lee": "Annalee"]) == "Ask Annalee.")
        }
    }

    @Test func aLinkTagIsNotAListItem() {
        #expect(HTMLText.text(from: "<link rel=\"stylesheet\" href=\"a.css\">Intro<p>Hello</p>") == "Intro\n\nHello")
        #expect(HTMLText.text(from: "<ul><li>One</li><li class=\"x\">Two</li></ul>") == "- One\n\n- Two")
    }
}

@Suite struct MeetingRegressionTests {
    @Test func aLineCutInTheMiddleOfALetterLosesOnlyThatLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-journal-\(UUID().uuidString)")
        let journal = try RecordingJournal(directory: dir)
        journal.append([0.1], to: .mic)
        journal.add(TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "whole"))
        journal.close()
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("segments.jsonl"))
        try handle.seekToEnd()
        // The first byte of "é", with the second never written.
        try handle.write(contentsOf: Data(#"{"speaker":"Me","text":"caf"#.utf8) + Data([0xC3]))
        try handle.close()
        #expect(RecordingJournal.recover(from: dir)?.segments.map(\.text) == ["whole"])
        RecordingJournal.remove(dir)
    }

    @Test func goAheadAndIsNotPartOfTheTask() {
        func said(_ text: String) -> [Commitment] {
            MeetingText.commitments(in: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: text)])
        }
        #expect(said("I'll go ahead and send the invoice tomorrow.").map(\.task) == ["send the invoice tomorrow."])
        #expect(said("I’ll go ahead and book the room.").map(\.task) == ["book the room."])
        #expect(said("I'll send the invoice tomorrow.").map(\.task) == ["send the invoice tomorrow."])
    }
}

@Suite struct StoreRegressionTests {
    @Test func aProfileSavedBeforeAFieldExistedKeepsItsOtherFields() throws {
        let engine = PersonalLanguage(store: try ChirpStore())
        try engine.setSetting("writingProfile", ["removeFillers": false])
        let profile = try engine.profile()
        #expect(profile.removeFillers == false)
        #expect(profile.spokenLineBreaks == true)
        #expect(profile.formality == .neutral)
        // And a full profile still round-trips.
        var full = WritingProfile()
        full.spelling = .british
        full.styleNotes = "Short sentences."
        try engine.saveProfile(full)
        #expect(try engine.profile() == full)
    }

    @Test func resultsThatTieComeInTheSameOrderEveryTime() {
        let items = Dictionary(uniqueKeysWithValues: (1...8).map { (Int64($0), SavedItem(id: Int64($0), kind: .note, title: "\($0)")) })
        // Each list puts a different item first, so they tie pair by pair.
        let keyword = [8, 6, 4, 2].map { Library.Hit(item: items[Int64($0)]!, snippet: "", score: 0) }
        let semantic = [1, 3, 5, 7].map { SemanticSearch.PassageHit(chunk: Chunk(id: Int64($0), itemID: Int64($0), offset: 0, text: "t"), score: 0.9) }
        let ids = SemanticSearch.fuse(keyword: keyword, semantic: semantic, items: items).map(\.id)
        #expect(ids == [8, 1, 6, 3, 4, 5, 2, 7])
    }

    @Test func aVectorCutShortReadsItsWholeNumbers() {
        let data = SemanticSearch.data([1.5, -2]) + Data([0x01])
        #expect(SemanticSearch.vector(data) == [1.5, -2])
        // A slice that does not start on a four-byte boundary.
        let shifted = (Data([0xFF]) + SemanticSearch.data([0.25, 4])).dropFirst()
        #expect(SemanticSearch.vector(shifted) == [0.25, 4])
        #expect(SemanticSearch.vector(Data()).isEmpty)
    }
}
