import Foundation
import Testing

@testable import ChirpCore

@Suite struct WordDiffTests {
    @Test func findsSubstitutions() {
        let subs = WordDiff.substitutions(
            from: "Ask Alex Okafar about cooper netties today.", to: "Ask Alex Okafor about Kubernetes today.")
        #expect(subs.map(\.heard) == ["Okafar", "cooper netties"])
        #expect(subs.map(\.meant) == ["Okafor", "Kubernetes"])
    }

    @Test func ignoresPunctuationCaseAndPureEdits() {
        #expect(WordDiff.substitutions(from: "hello there", to: "Hello there.").isEmpty)
        #expect(WordDiff.substitutions(from: "send the report", to: "please send the report now").isEmpty)
        #expect(WordDiff.substitutions(from: "one two three four five six", to: "a b c d e f g").isEmpty)
    }

    @Test func diffRoundTrips() {
        let ops = WordDiff.diff(from: "the quick brown fox", to: "the slow brown dog")
        #expect(ops == [.same("the"), .removed("quick"), .added("slow"), .same("brown"), .removed("fox"), .added("dog")])
    }
}

@Suite struct LibraryTests {
    func library() throws -> Library { Library(store: try ChirpStore()) }

    @Test func savesWithTitleAndLists() throws {
        let lib = try library()
        let a = try lib.save(SavedItem(kind: .dictation, body: "Move the meeting to Friday at three. Thanks."))
        #expect(a.id != nil)
        #expect(a.title == "Move the meeting to Friday at three. Thanks")
        try lib.save(SavedItem(kind: .meeting, title: "Weekly sync", body: "Notes"))
        #expect(try lib.items(kinds: [.dictation]).count == 1)
        #expect(try lib.items().count == 2)
        #expect(try lib.count(kind: .meeting) == 1)
    }

    @Test func settingThePlaceLeavesTheRestOfTheItemAlone() throws {
        let lib = try library()
        let saved = try lib.save(SavedItem(kind: .document, title: "Book", body: "One. Two. Three."))
        let id = try #require(saved.id)
        // The title changes elsewhere while a reader still holds the old copy.
        var renamed = saved
        renamed.title = "Renamed"
        _ = try lib.save(renamed)
        try lib.setPosition(id: id, position: 5)
        let now = try #require(try lib.item(id))
        #expect(now.position == 5)
        #expect(now.title == "Renamed")
    }

    @Test func countingUnindexedItemsMatchesTheList() throws {
        let lib = try library()
        _ = try lib.save(SavedItem(kind: .note, title: "A", body: "Some words to find later."))
        _ = try lib.save(SavedItem(kind: .dictation, title: "", body: "Dictations are not indexed."))
        _ = try lib.save(SavedItem(kind: .note, title: "Empty", body: ""))
        #expect(try lib.countItemsNeedingChunks() == lib.itemsNeedingChunks().count)
        #expect(try lib.countItemsNeedingChunks() == 1)
    }

    @Test func searchMatchesStemsPrefixesAndKinds() throws {
        let lib = try library()
        try lib.save(SavedItem(kind: .meeting, title: "Budget review", body: "We approved the marketing budget."))
        try lib.save(SavedItem(kind: .document, title: "Hiking", body: "Trails near the lake."))
        #expect(try lib.search("approve").map(\.item.title) == ["Budget review"])
        #expect(try lib.search("mark").count == 1)
        #expect(try lib.search("budget", kinds: [.document]).isEmpty)
        #expect(try lib.search("\"quotes) AND (").isEmpty)
        #expect(try lib.search("lake").first?.snippet.contains("«lake»") == true)
    }

    @Test func searchSeesEditsAndDeletes() throws {
        let lib = try library()
        var item = try lib.save(SavedItem(kind: .note, title: "Note", body: "alpha"))
        item.body = "beta"
        try lib.save(item)
        #expect(try lib.search("alpha").isEmpty)
        #expect(try lib.search("beta").count == 1)
        try lib.delete(item)
        #expect(try lib.search("beta").isEmpty)
    }

    @Test func trimKeepsNewestAndStarred() throws {
        let lib = try library()
        for i in 0..<5 {
            try lib.save(
                SavedItem(
                    kind: .dictation, body: "d\(i)", starred: i == 0,
                    createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        try lib.trimDictations(keep: 2)
        #expect(Set(try lib.items(kinds: [.dictation]).map(\.body)) == ["d0", "d3", "d4"])
    }

    @Test func segmentsAndSpeakerRename() throws {
        let lib = try library()
        let m = try lib.save(SavedItem(kind: .meeting, title: "Sync"))
        try lib.replaceSegments(
            itemID: m.id!,
            with: [
                TranscriptSegment(itemID: 0, speaker: "Speaker 1", start: 0, end: 2, text: "Hi"),
                TranscriptSegment(itemID: 0, speaker: "Me", start: 2, end: 4, text: "Hello"),
            ])
        try lib.renameSpeaker(itemID: m.id!, from: "Speaker 1", to: "Sam")
        #expect(try lib.segments(itemID: m.id!).map(\.speaker) == ["Sam", "Me"])
        try lib.delete(m)
        #expect(try lib.segments(itemID: m.id!).isEmpty)
    }

    @Test func chunkerRespectsLimit() {
        let text = String(repeating: "This is a sentence about budgets. ", count: 60) + "\n\nSecond paragraph here."
        let chunks = TextChunker.chunks(text, maxCharacters: 400)
        #expect(chunks.count > 4)
        #expect(chunks.allSatisfy { $0.count <= 400 })
        #expect(chunks.joined(separator: " ").contains("Second paragraph here."))
        #expect(TextChunker.chunks("short", maxCharacters: 400) == ["short"])
    }

    @Test func promptsCarryTheProfile() {
        var p = WritingProfile()
        p.spelling = .british
        p.styleNotes = "No exclamation marks."
        let prompts = Prompts(profile: p, formality: .formal, terms: ["Kubernetes"])
        let text = prompts.instructions(for: .rephrase(.formal))
        #expect(text.contains("British"))
        #expect(text.contains("No exclamation marks."))
        #expect(text.contains("Kubernetes"))
        #expect(text.contains("professional"))
        #expect(prompts.instructions(for: .fix).contains("proofreader"))
        #expect(prompts.meetingSectionInstructions(section: "Decisions").contains("together"))
        #expect(prompts.meetingSectionInstructions(section: "Objections").contains("\"Objections\""))
    }
}

@Suite struct NotesWithoutActionItemsTests {
    @Test func aTemplateLosesItsActionItems() {
        #expect(Prompts.noteSections(template: "Summary\nKey points\nDecisions\nAction items") == ["Summary", "Key points", "Decisions"])
        #expect(Prompts.noteSections(template: "Updates\nNext steps\nFollow-ups\nTo do") == ["Updates"])
        // Nothing but action items, or no template: the usual three.
        #expect(Prompts.noteSections(template: "Action items") == ["Summary", "Key points", "Decisions"])
        #expect(Prompts.noteSections(template: nil) == ["Summary", "Key points", "Decisions"])
        // A stand-up's "Doing next" is a topic of the meeting, not a to-do list.
        #expect(Prompts.noteSections(template: "Done\nDoing next\nBlockers") == ["Done", "Doing next", "Blockers"])
    }

    @Test func noBuiltInTemplateAsksForActionItems() throws {
        let templates = try Library(store: try ChirpStore()).templates()
        #expect(!templates.isEmpty)
        #expect(templates.allSatisfy { t in !t.sections.split(separator: "\n").contains { Prompts.isTaskSection(String($0)) } })
    }

    @Test func whatPeopleTookOnGoesAmongTheKeyPoints() {
        #expect(Prompts.sectionForCommitments(["Summary", "Key points", "Decisions"]) == "Key points")
        #expect(Prompts.sectionForCommitments(["Done", "Doing next", "Blockers"]) == "Doing next")
        #expect(Prompts.sectionForCommitments(["Summary", "Risks", "Decisions"]) == "Risks")
        #expect(Prompts.sectionForCommitments(["Summary", "Decisions"]) == nil)
        let mine = Commitment(owner: "I", isRequest: false, sentence: "", task: "send the budget numbers by Wednesday.", context: "")
        let asked = Commitment(owner: "Speaker 2", isRequest: true, sentence: "", task: "send the slides", context: "")
        #expect(mine.point() == "I will send the budget numbers by Wednesday")
        #expect(asked.point() == "Speaker 2 asked: send the slides")
        let notes = MeetingText.assembleNotes(
            wanted: ["Summary", "Key points", "Decisions"],
            draft: "## Summary\n- Launch review.\n\n## Key points\n- The beta is on March 3rd.\n\n## Decisions\n- None noted",
            replacements: [:], additions: ["Key points": [mine.point(), asked.point()]])
        #expect(notes == "## Summary\n- Launch review.\n\n## Key points\n- The beta is on March 3rd.\n- I will send the budget numbers by Wednesday\n"
            + "- Speaker 2 asked: send the slides\n\n## Decisions\n- None noted")
        #expect(!notes.contains("Action items"))
        // With nothing else under the heading, "None noted" gives way to them.
        let bare = MeetingText.assembleNotes(wanted: ["Key points"], draft: "## Key points\n- None noted", replacements: [:], additions: ["Key points": [mine.point()]])
        #expect(bare == "## Key points\n- I will send the budget numbers by Wednesday")
    }

    @Test func theNotesAreNotToldToListTasks() {
        let text = Prompts(profile: WritingProfile()).meetingNotesInstructions(sections: Prompts.usualSections)
        #expect(text.contains("## Summary\n## Key points\n## Decisions"))
        #expect(!text.lowercased().contains("action item"))
    }
}
