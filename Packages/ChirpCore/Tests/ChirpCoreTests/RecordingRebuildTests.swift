import Foundation
import GRDB
import Testing

@testable import ChirpCore

/// How a recording is made and kept: the kind is chosen, notes are kept with their times, the Mac's own
/// sound is not written down twice, jobs take turns.
@Suite struct RecordingRebuildTests {
    private func line(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(itemID: 0, speaker: speaker, start: start, end: end, text: text)
    }

    // MARK: Timed notes

    @Test func aRecordingSavedBeforeTimedNotesStillOpens() throws {
        let old = #"{"attendees":["Ann"],"links":[],"attachments":[],"screens":[],"eventTitle":"Sync","template":"General"}"#
        let context = RecordingContext(json: old)
        #expect(context.eventTitle == "Sync")
        #expect(context.attendees == ["Ann"])
        #expect(context.notes.isEmpty)
        #expect(context.kind == nil)
        #expect(context.template == "General")
    }

    @Test func timedNotesSurviveBeingSavedAndRead() throws {
        var context = RecordingContext()
        context.kind = .meeting
        context.notes = [
            TimedNote(at: 314, text: "April, not March. Tell finance."),
            TimedNote(at: 739, image: "capture-1.jpg", app: "Keynote", window: "Test results, week 45", seen: "Checkout 92%"),
        ]
        let back = RecordingContext(json: context.json)
        #expect(back == context)
        #expect(back.notes[0].clock == "5:14")
        #expect(back.notes[0].line == "April, not March. Tell finance.")
        #expect(back.notes[1].isPicture)
        #expect(back.notes[1].line == "Picture of Test results, week 45")
        #expect(back.notes[1].caption == "Keynote · Test results, week 45")
        #expect(TimedNote(at: 2, image: "x.jpg").line == "Picture of the front window")
    }

    @Test func timedNotesAndThePictureWordsAreSearchedAndNeverGivenToTheNotesStep() throws {
        var context = RecordingContext(attachments: [.init(name: "plan.txt", text: "Budget 40k")])
        context.notes = [TimedNote(at: 5, text: "ask Priya about zebras"), TimedNote(at: 9, image: "a.jpg", app: "Keynote", window: "Deck", seen: "quarterly giraffe")]
        #expect(context.searchText.contains("zebras"))
        #expect(context.searchText.contains("giraffe"))
        #expect(context.searchText.contains("Budget 40k"))
        // What the notes model is handed never holds them.
        let material = context.material() ?? ""
        #expect(!material.contains("zebras"))
        #expect(!material.contains("giraffe"))
        #expect(!context.names().contains { $0.lowercased().contains("zebra") })
        #expect(context.notesText == "0:05  ask Priya about zebras\n0:09  Picture of Deck")
    }

    @Test func aNoteSitsInTheTranscriptAtItsMoment() throws {
        let lines = [line("Them", 0, 4, "One."), line("Me", 5, 9, "Two."), line("Them", 12, 15, "Three.")]
        let notes = [TimedNote(at: 14, text: "late"), TimedNote(at: 6, text: "early"), TimedNote(at: 30, image: "p.jpg")]
        let timeline = MeetingText.timeline(lines: lines, notes: notes)
        let order = timeline.map { entry -> String in
            switch entry {
            case .line(let s): s.text
            case .note(let n): n.isPicture ? "picture" : n.text
            }
        }
        #expect(order == ["One.", "Two.", "early", "Three.", "late", "picture"])
        #expect(MeetingText.lineIndex(at: 6, in: lines) == 1)
        #expect(MeetingText.lineIndex(at: 30, in: lines) == 2)
        #expect(MeetingText.lineIndex(at: -1, in: lines) == nil)
        #expect(MeetingText.timeline(lines: [], notes: []).isEmpty)
    }

    @Test func exportHasMyNotesWithTheirTimes() throws {
        var context = RecordingContext()
        context.notes = [TimedNote(at: 302, text: "Ask Priya for the date"), TimedNote(at: 739, image: "c.jpg", window: "Sam's slide")]
        let meeting = SavedItem(kind: .meeting, title: "Launch review", summary: "## Summary\n- Moved to April", context: context.json)
        let md = MeetingText.markdown(item: meeting, segments: [line("Me", 0, 2, "Hello.")])
        #expect(md.contains("## My notes\n\n- 5:02 Ask Priya for the date\n- 12:19 Picture of Sam's slide"))
        let note = SavedItem(kind: .voiceNote, title: "Plan", body: "Three runs a week.", context: context.json)
        let noteMd = MeetingText.markdown(item: note, segments: [])
        #expect(noteMd.contains("Three runs a week.\n\n## My notes\n\n- 5:02"))
        #expect(!noteMd.contains("## My notes\n\nThree runs"))
    }

    // MARK: The kind is chosen

    @Test func theKindIsWhatWasChosen() throws {
        #expect(RecordingKind.voiceNote.itemKind == .voiceNote)
        #expect(RecordingKind.meeting.itemKind == .meeting)
        #expect(RecordingKind.voiceNote.name == "Note")
        #expect(RecordingKind.meeting.name == "Meeting")
        #expect(RecordingKind.voiceNote.untitled == "New note")
    }

    @Test func aVoiceNoteIsCleanTextInParagraphs() throws {
        let lines = [
            line("Me", 0, 4, "Three runs a week from January."), line("Me", 4.5, 8, "The long run is on Sundays."),
            line("Me", 12, 15, "Tuesday is the easy run."), line("Me", 15.2, 16, ""),
        ]
        #expect(MeetingText.cleanText(lines) == "Three runs a week from January. The long run is on Sundays.\n\nTuesday is the easy run.")
        // A pause in the middle of a sentence does not break it.
        let mid = [line("Me", 0, 2, "I was thinking that"), line("Me", 9, 11, "we should go.")]
        #expect(MeetingText.cleanText(mid) == "I was thinking that we should go.")
        #expect(MeetingText.cleanText([]) == "")
    }

    // MARK: The echo

    @Test func theMacsOwnSoundIsDroppedOnSpeakersAndKeptOnHeadphones() throws {
        let lines = [
            line("Them", 0, 6, "Welcome back to the channel, today we are looking at marathon training."),
            line("Me", 0.4, 6.3, "Welcome back to the channel today we're looking at marathon training"),
            line("Me", 8, 10, "I should write that down."),
            line("Them", 11, 15, "Start with three runs a week."),
            line("Me", 11.2, 15.4, "Start with three runs a week"),
        ]
        let onSpeakers = MeetingText.shown(lines, headphones: false)
        #expect(onSpeakers.map(\.text) == [
            "Welcome back to the channel, today we are looking at marathon training.", "I should write that down.", "Start with three runs a week.",
        ])
        #expect(MeetingText.shown(lines, headphones: true).count == 5)
        // The user's own words about the same thing, in other words, stay.
        #expect(!MeetingText.isEcho(line("Me", 12, 14, "Three runs sounds like plenty to me"), of: lines.filter { $0.speaker == "Them" }))
        // A short "yes" is never dropped, and neither is the same sentence said a long time after.
        #expect(!MeetingText.isEcho(line("Me", 1, 2, "Welcome back"), of: lines.filter { $0.speaker == "Them" }))
        #expect(!MeetingText.isEcho(line("Me", 40, 46, "Welcome back to the channel today we are looking at marathon training"), of: lines.filter { $0.speaker == "Them" }))
    }

    // MARK: Speakers by word

    @Test func aLineIsSplitWhereTheVoiceChanges() throws {
        let words = [
            SaidWord(text: "April", start: 0.0, end: 0.4), SaidWord(text: "is", start: 0.4, end: 0.6), SaidWord(text: "honest.", start: 0.6, end: 1.2),
            SaidWord(text: "Then", start: 1.4, end: 1.7), SaidWord(text: "we", start: 1.7, end: 1.9), SaidWord(text: "say", start: 1.9, end: 2.2),
            SaidWord(text: "April.", start: 2.2, end: 2.8),
        ]
        let lines = [line("Them", 0, 2.8, "April is honest. Then we say April."), line("Me", 3, 4, "Good."), line("Them", 5, 6, "Fine.")]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 1.3), SpeakerTurn(speaker: "b", start: 1.3, end: 3), SpeakerTurn(speaker: "a", start: 4.8, end: 6.2)]
        let out = MeetingText.speakersByWord(lines, words: words, turns: turns, replacing: "Them")
        #expect(out.map(\.speaker) == ["Speaker 1", "Speaker 2", "Me", "Speaker 1"])
        #expect(out.map(\.text) == ["April is honest.", "Then we say April.", "Good.", "Fine."])
        #expect(out[1].start == 1.4)
        // One voice: nothing to tell apart.
        #expect(MeetingText.speakersByWord(lines, words: words, turns: [SpeakerTurn(speaker: "a", start: 0, end: 9)], replacing: "Them") == lines)
    }

    @Test func oneStrayWordDoesNotMakeATurn() throws {
        let words = (0..<8).map { SaidWord(text: "w\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let lines = [line("Them", 0, 2.4, words.map(\.text).joined(separator: " ")), line("Them", 10, 12, "Other voice here.")]
        let turns = [
            SpeakerTurn(speaker: "a", start: 0, end: 0.9), SpeakerTurn(speaker: "b", start: 0.9, end: 1.2), SpeakerTurn(speaker: "a", start: 1.2, end: 2.5),
            SpeakerTurn(speaker: "b", start: 10, end: 12),
        ]
        let out = MeetingText.speakersByWord(lines, words: words, turns: turns, replacing: "Them")
        #expect(out.count == 2)
        #expect(out.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    // MARK: Jobs take turns

    @Test func theSecondJobWaitsAndSaysWhatFor() throws {
        var line = JobLine()
        let link = line.add("the link")
        let notes = line.add("Design sync", itemID: 7)
        let third = line.add("Vendor call")
        #expect(line.isRunning(link))
        #expect(line.waitingLine(for: link) == nil)
        #expect(line.waitingLine(for: notes) == "Waiting for the link to finish…")
        #expect(line.waitingLine(for: third) == "Waiting for the link to finish…")
        #expect(line.firstWaiting?.job.itemID == 7)
        // Cancelled while waiting: it leaves and the others keep their order.
        line.remove(notes)
        #expect(line.waiting.map(\.name) == ["Vendor call"])
        // The running one ends: the next has its turn.
        line.remove(link)
        #expect(line.isRunning(third))
        #expect(line.firstWaiting == nil)
        line.remove(third)
        #expect(line.running == nil)
    }

    @Test func progressLinesReadAsTheBoardsDo() throws {
        #expect(ProgressLine.recording(elapsed: 62) == "Recording · 1:02")
        #expect(ProgressLine.recording(.meeting, elapsed: 62) == "Recording · 1:02")
        #expect(ProgressLine.recording(.voiceNote, elapsed: 26) == "Note · 0:26")
        #expect(ProgressLine.writingNotes == "Writing notes…")
    }

    // MARK: The library is not disturbed

    @Test func anExistingLibraryOpensAndItsRecordingsRead() throws {
        // A library as the build before this one left it: a meeting with typed notes in its body and a
        // context without timed notes, and a voice note with lines.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-rebuild-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try ChirpStore(url: url)
            let library = Library(store: store)
            let old = #"{"attendees":["Ann"],"links":[],"attachments":[],"screens":[{"at":3,"app":"Keynote","window":"Deck","text":"hello"}]}"#
            let meeting = try library.save(SavedItem(kind: .meeting, title: "Old meeting", body: "typed during it", summary: "## Summary\n- Fine", context: old))
            try library.replaceSegments(itemID: meeting.id!, with: [line("Me", 0, 2, "Hello."), line("Speaker 1", 2, 4, "Hi.")])
            let note = try library.save(SavedItem(kind: .voiceNote, title: "Old note", summary: "## To do\n- Call Sam"))
            try library.replaceSegments(itemID: note.id!, with: [line("Me", 0, 2, "Call Sam.")])
        }
        let store = try ChirpStore(url: url)
        let library = Library(store: store)
        let items = try library.items(kinds: [.meeting, .voiceNote])
        #expect(items.count == 2)
        let meeting = try #require(items.first { $0.kind == .meeting })
        #expect(meeting.body == "typed during it")
        #expect(RecordingContext(json: meeting.context).screens.count == 1)
        #expect(try library.segments(itemID: meeting.id!).count == 2)
        // Saving timed notes into it changes nothing else.
        var context = RecordingContext(json: meeting.context)
        context.notes.append(TimedNote(at: 1, text: "added later"))
        var changed = meeting
        changed.context = context.json
        _ = try library.save(changed)
        try library.setAttachmentText(itemID: meeting.id!, text: context.searchText)
        let again = try #require(try library.item(meeting.id!))
        #expect(RecordingContext(json: again.context).notes.map(\.text) == ["added later"])
        #expect(try library.search("later", kinds: [.meeting]).contains { $0.item.id == meeting.id })
        let check = try store.db.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        #expect(check == "ok")
    }
}
