import Foundation
import Testing

@testable import ChirpCore

@Suite struct NoteMarkdownTests {
    private func kinds(_ text: String) -> [(NoteMarkdown.Kind, String)] {
        let ns = text as NSString
        return NoteMarkdown.spans(in: text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func has(_ text: String, _ kind: NoteMarkdown.Kind, _ words: String) -> Bool {
        kinds(text).contains { $0.0 == kind && $0.1 == words }
    }

    @Test func headingsListsBoldItalicAndCodeAreFound() {
        let note = "# Ideas for the kitchen shelves\nMeasure the alcove; the wall is **not square**.\n- Oak, *oiled*\n- Brackets `600 mm` apart\n1. First"
        #expect(has(note, .heading(1), "Ideas for the kitchen shelves"))
        #expect(has(note, .mark, "# "))
        #expect(has(note, .bold, "not square"))
        #expect(has(note, .italic, "oiled"))
        #expect(has(note, .code, "600 mm"))
        #expect(has(note, .listMarker(bullet: true), "- "))
        #expect(has(note, .listMarker(bullet: false), "1. "))
        #expect(has(note, .listItem(depth: 0), "- Oak, *oiled*"))
        // The marks of bold are marks; they are not italics.
        #expect(!kinds(note).contains { $0.0 == .italic && $0.1.contains("not") })
    }

    @Test func aCodeBlockTakesItsLinesOutOfEverythingElse() {
        let note = "Steps\n```\n# not a heading\n**not bold**\n```\nAfter **bold**"
        let found = kinds(note)
        #expect(found.contains { $0.0 == .codeBlock && $0.1.hasPrefix("```") && $0.1.hasSuffix("```") })
        #expect(!found.contains { $0.0 == .heading(1) })
        #expect(found.filter { $0.0 == .bold }.map(\.1) == ["bold"])
        #expect(found.filter { $0.0 == .fence }.count == 2)
        // Still being typed: everything after an open fence is code.
        #expect(kinds("a\n```\nrsync -a").contains { $0.0 == .codeBlock && $0.1 == "```\nrsync -a" })
    }

    @Test func codeSpansKeepTheirStarsAndSnakeCaseIsNotItalic() {
        #expect(!kinds("`**x**` and file_name_here").contains { $0.0 == .bold || $0.0 == .italic })
    }

    @Test func checksLeaveCodeAndMarksAlone() {
        let note = "Ask about `rsync` **now**"
        let unchecked = NoteMarkdown.unchecked(in: NoteMarkdown.spans(in: note)).map { (note as NSString).substring(with: $0) }
        #expect(unchecked.contains("rsync"))
        #expect(unchecked.contains("**"))
        #expect(!unchecked.contains("now"))
    }

    @Test func theTitleIsTheFirstLineWithWords() {
        #expect(NoteMarkdown.title("\n\n# Sync script for the **photo** backup\nmore") == "Sync script for the photo backup")
        #expect(NoteMarkdown.title("- packing list") == "packing list")
        #expect(NoteMarkdown.title("   \n") == nil)
        let long = String(repeating: "word ", count: 30)
        let title = NoteMarkdown.title(long)!
        #expect(title.count <= 81 && title.hasSuffix("…"))
    }

    @Test func plainTextHasTheWordsWithoutMarks() {
        let note = "# Plan\nRun **three** times, *easy*.\n- Long run `Sunday`\n```\nrsync -a ~/x nas:/y\n```"
        #expect(NoteMarkdown.plain(note) == "Plan\nRun three times, easy.\n• Long run Sunday\nrsync -a ~/x nas:/y")
    }
}

@Suite struct NoteLibraryTests {
    @Test func aTypedNoteIsSavedWithItsTitleWordsAndFacts() throws {
        let lib = Library(store: try ChirpStore())
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let note = try lib.saveNote(id: nil, markdown: "# Ideas for the kitchen shelves\n- Oak, **oiled**", typed: true, now: at)
        #expect(note.kind == .voiceNote)
        #expect(note.title == "Ideas for the kitchen shelves")
        #expect(note.body == "Ideas for the kitchen shelves\n• Oak, oiled")
        let extra = try #require(try lib.note(itemID: note.id!))
        #expect(extra.markdown.hasPrefix("# Ideas"))
        #expect(extra.typed && !extra.dictated && extra.editedAt == at)
        // Dictating into it later adds to what is known; the title follows the first line.
        let again = try lib.saveNote(id: note.id, markdown: "# Shelves\n- Oak", dictated: true)
        #expect(again.id == note.id && again.title == "Shelves")
        let after = try #require(try lib.note(itemID: note.id!))
        #expect(after.typed && after.dictated)
        // Search finds its words, not its marks.
        #expect(try lib.search("Shelves").first?.item.id == note.id)
        try lib.setNoteExported(itemID: note.id!, at: at)
        #expect(try lib.noteFacts()[note.id!]?.exportedAt == at)
    }

    @Test func aVoiceNoteKeepsItsTitleUntilItsWordsChange() throws {
        let lib = Library(store: try ChirpStore())
        let voice = try lib.save(SavedItem(kind: .voiceNote, title: "Spring half marathon plan", body: "Run three times a week.", audioFile: "a.m4a", duration: 20))
        // Not edited yet: its words are the note.
        #expect(try lib.note(itemID: voice.id!)?.markdown == "Run three times a week.")
        let same = try lib.saveNote(id: voice.id, markdown: "Run three times a week.")
        #expect(same.title == "Spring half marathon plan" && same.audioFile == "a.m4a")
        let edited = try lib.saveNote(id: voice.id, markdown: "Run four times a week.", typed: true)
        #expect(edited.title == "Run four times a week." && edited.audioFile == "a.m4a" && edited.duration == 20)
    }

    @Test func anEmptyNoteIsNotKept() throws {
        let lib = Library(store: try ChirpStore())
        let empty = try lib.saveNote(id: nil, markdown: "  ")
        let kept = try lib.saveNote(id: nil, markdown: "Words")
        let open = try lib.saveNote(id: nil, markdown: "")
        #expect(try lib.deleteEmptyNotes(keeping: open.id) == 1)
        #expect(try lib.item(empty.id!) == nil)
        #expect(try lib.item(kept.id!) != nil)
        #expect(try lib.item(open.id!) != nil)
    }

    @Test func aLibraryMadeBeforeNotesOpensWithItsVoiceNotesEditableAndUnchanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var ids: [Int64] = []
        do {
            // A library as it was at the step before notes.
            let store = try ChirpStore(url: url, upTo: "v7")
            let lib = Library(store: store)
            let voice = try lib.save(SavedItem(kind: .voiceNote, title: "Kitchen shelves", body: "Open shelves on the left wall.", rawText: "open shelves on the left wall", audioFile: "note.m4a", duration: 124, starred: true))
            try lib.replaceSegments(itemID: voice.id!, with: [TranscriptSegment(itemID: voice.id!, speaker: "Me", start: 0, end: 2, text: "open shelves")])
            let meeting = try lib.save(SavedItem(kind: .meeting, title: "Sync", summary: "## Summary\n- Done"))
            let doc = try lib.save(SavedItem(kind: .document, title: "Plan", body: "One. Two."))
            ids = [voice.id!, meeting.id!, doc.id!]
            #expect(try store.db.read { db in try db.tableExists("itemNote") } == false)
        }
        let lib = Library(store: try ChirpStore(url: url))
        #expect(try lib.items().count == 3)
        let voice = try #require(try lib.item(ids[0]))
        #expect(voice.title == "Kitchen shelves" && voice.body == "Open shelves on the left wall." && voice.audioFile == "note.m4a")
        #expect(voice.duration == 124 && voice.starred && voice.rawText == "open shelves on the left wall")
        #expect(try lib.segments(itemID: ids[0]).map(\.text) == ["open shelves"])
        // Editable: it has its own words as Markdown.
        #expect(try lib.note(itemID: ids[0])?.markdown == "Open shelves on the left wall.")
        #expect(try lib.note(itemID: ids[1]) == nil)
        #expect(try lib.item(ids[1])?.summary == "## Summary\n- Done")
        #expect(try lib.search("shelves").contains { $0.item.id == ids[0] })
    }
}
