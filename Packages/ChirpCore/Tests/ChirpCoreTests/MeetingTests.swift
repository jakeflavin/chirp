import Foundation
import Testing

@testable import ChirpCore

@Suite struct MeetingTests {
    /// `seconds` of a steady tone (speech stand-in) or silence.
    func audio(_ seconds: Double, loud: Bool) -> [Float] {
        (0..<Int(seconds * 16_000)).map { loud ? Float(sin(Double($0) * 0.3)) * 0.3 : 0 }
    }

    @Test func cutsAtPauseAfterMinimum() {
        var seg = PauseSegmenter()
        var pieces = seg.append(audio(5, loud: true) + audio(1, loud: false) + audio(2, loud: true))
        #expect(pieces.count == 1)
        #expect(abs(pieces[0].end - 5.25) < 0.3)
        pieces += [seg.finish()!]
        #expect(pieces.count == 2)
        #expect(abs(pieces[1].start - pieces[0].end) < 0.001)
        #expect(abs(pieces[1].end - 8.0) < 0.001)
        #expect(seg.finish() == nil)
    }

    @Test func cutsAtMaximumWithoutPause() {
        var seg = PauseSegmenter()
        let pieces = seg.append(audio(30, loud: true))
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { abs(Double($0.samples.count) / 16_000 - 14) < 0.01 })
    }

    @Test func worksWhenFedInSmallChunks() {
        var seg = PauseSegmenter()
        let stream = audio(6, loud: true) + audio(1, loud: false) + audio(6, loud: true) + audio(1, loud: false)
        var pieces: [PauseSegmenter.Piece] = []
        for start in stride(from: 0, to: stream.count, by: 1600) {
            pieces += seg.append(Array(stream[start..<min(start + 1600, stream.count)]))
        }
        if let last = seg.finish() { pieces.append(last) }
        #expect(pieces.count >= 2)
        #expect(pieces.map(\.samples.count).reduce(0, +) == stream.count)
    }

    @Test func assignsSpeakersByOverlap() {
        let segs = [
            TranscriptSegment(itemID: 1, speaker: "Them", start: 0, end: 5, text: "a"),
            TranscriptSegment(itemID: 1, speaker: "Me", start: 5, end: 8, text: "b"),
            TranscriptSegment(itemID: 1, speaker: "Them", start: 8, end: 12, text: "c"),
        ]
        let turns = [SpeakerTurn(speaker: "S7", start: 0, end: 5.5), SpeakerTurn(speaker: "S2", start: 7.5, end: 12)]
        let out = MeetingText.assignSpeakers(segs, turns: turns, replacing: "Them")
        #expect(out.map(\.speaker) == ["Speaker 1", "Me", "Speaker 2"])
        // One speaker only: labels stay as they were.
        let one = MeetingText.assignSpeakers(segs, turns: [SpeakerTurn(speaker: "S1", start: 0, end: 12)], replacing: "Them")
        #expect(one.map(\.speaker) == ["Them", "Me", "Them"])
    }

    @Test func dropsMicrophoneEchoOfTheCall() {
        let segs = [
            TranscriptSegment(itemID: 1, speaker: "Them", start: 0, end: 5, text: "Let's review the budget for next quarter."),
            TranscriptSegment(itemID: 1, speaker: "Me", start: 0.3, end: 5.2, text: "let's review the budget for next quarter"),
            TranscriptSegment(itemID: 1, speaker: "Me", start: 6, end: 9, text: "Sounds good, I'll send the numbers today."),
            TranscriptSegment(itemID: 1, speaker: "Me", start: 20, end: 25, text: "Let's review the budget for next quarter."),
        ]
        let out = MeetingText.dropEchoes(segs)
        #expect(out.map(\.start) == [0, 6, 20])
    }

    @Test func assemblesNotesFromDraftAndReplacements() {
        let draft = "Here are the notes:\n## Summary\n- Launch review\nstray line\n## action items\n- wrong owner\n## Extra\n- ignored"
        let out = MeetingText.assembleNotes(
            wanted: ["Summary", "Decisions", "Action items"], draft: draft,
            replacements: ["Action items": ["I: send the budget"]])
        #expect(out == "## Summary\n- Launch review\n\n## Decisions\n- None noted\n\n## Action items\n- I: send the budget")
    }

    @Test func scriptMergesNeighbours() {
        let segs = [
            TranscriptSegment(itemID: 1, speaker: "Me", start: 0, end: 2, text: "Hello."),
            TranscriptSegment(itemID: 1, speaker: "Me", start: 2.5, end: 4, text: "Ready?"),
            TranscriptSegment(itemID: 1, speaker: "Them", start: 4, end: 6, text: "Yes."),
        ]
        #expect(MeetingText.script(segs) == "Me: Hello. Ready?\nThem: Yes.")
    }

    @Test func markdownHasAllParts() {
        let item = SavedItem(kind: .meeting, title: "Sync", body: "ask about budget", summary: "## Summary\n- Agreed", duration: 125)
        let md = MeetingText.markdown(
            item: item, segments: [TranscriptSegment(itemID: 1, speaker: "Sam", start: 61, end: 63, text: "Hi")])
        #expect(md.contains("# Sync"))
        #expect(md.contains("2:05"))
        #expect(md.contains("## Summary\n- Agreed"))
        #expect(md.contains("## My notes\n\nask about budget"))
        #expect(md.contains("**Sam** (1:01): Hi"))
    }

    @Test func commitmentsBelongToWhoeverMadeThem() {
        func seg(_ who: String, _ text: String) -> TranscriptSegment { TranscriptSegment(itemID: 0, speaker: who, start: 0, end: 1, text: text) }
        let found = MeetingText.commitments(in: [
            seg("Speaker 1", "Thanks for joining everyone. Let's review the launch plan. The beta goes out on March 3rd, and we need two more testers."),
            seg("Me", "Sounds good. I will send the budget numbers by Wednesday."),
            seg("Speaker 2", "I can own the release notes. Marketing needs the final screenshots by Friday, so please send them to me."),
            seg("Me", "I can find the two testers this week"),
            seg("Speaker 1", "Great. One risk is the payment bug. Priya will fix it before the beta. Let's meet again next Tuesday."),
            seg("Speaker 2", "I can see why that worries you. It will be fine."),
        ])
        #expect(found.map { $0.bullet() } == [
            "I: send the budget numbers by Wednesday",
            "Speaker 2: own the release notes",
            "Speaker 2 asked: send them to me",
            "I: find the two testers this week",
            "Priya: fix it before the beta",
            "Everyone: meet again next Tuesday",
        ])
        #expect(found[5].context.contains("payment bug"))
    }

    func tasks(_ lines: [(String, String)]) -> [String] {
        MeetingText.commitments(in: lines.enumerated().map { TranscriptSegment(itemID: 0, speaker: $1.0, start: Double($0), end: Double($0) + 1, text: $1.1) })
            .map { $0.bullet() }
    }

    @Test func steeringTheMeetingIsNotATask() {
        #expect(tasks([
            ("Speaker 4", "Can you go on to the next slide please?"),
            ("Speaker 2", "Next slide. Could you go on to the next?"),
            ("Speaker 1", "We'll come back to that later. Let's move on."),
            ("Speaker 3", "I'll speak about that in the next part. I will wait until you're all set up."),
            ("Speaker 1", "Right, I'm going to wrap it up there. Can you hear me? Could you repeat that last part?"),
            ("Speaker 2", "I'll pass. Let me share my screen. I can do that."),
        ]).isEmpty)
    }

    @Test func whatTheProductShouldDoIsNotATask() {
        #expect(tasks([
            ("Speaker 3", "We should use some colouring components. We need to have a sophisticated integrated circuit."),
            ("Speaker 2", "We have to develop one or two features to dwell on in our ad campaign."),
            ("Speaker 4", "We can make the battery a rechargeable one. We need to check into the financial feasibility."),
            ("Speaker 1", "What would you get out of that remote control before you use it?"),
            ("Speaker 2", "For example, I will record a question like good morning."),
        ]).isEmpty)
    }

    @Test func noisesAndThingsAreNotOwners() {
        #expect(tasks([
            ("Speaker 2", "Uh will go on to the next slide. Um will send it. Ours will look really great by March."),
            ("Speaker 1", "Marcus will need the recording. Congress needs to speak clearly. The remote will have a screen."),
            ("Ian", "Your Honor, those provisions will remain in full force."),
        ]).isEmpty)
    }

    @Test func aJobHandedOutByNameOrRoleIsTheirs() {
        #expect(tasks([
            ("Me", "Dan, can you also ask Professor Okafor whether the page limit includes footnotes?"),
            ("Speaker 1", "The UID is supposed to come up with the user interface design."),
            ("Speaker 1", "In this phase, the two of you, Jana and Francine, have to work together on a prototype using modeling clay."),
            ("Speaker 1", "The marketing expert will do the product evaluation. Priya is going to book the room."),
        ]) == [
            "Dan: ask Professor Okafor whether the page limit includes footnotes",
            "The UID: come up with the user interface design",
            "Jana and Francine: work together on a prototype using modeling clay",
            "The marketing expert: do the product evaluation",
            "Priya: book the room",
        ])
    }

    @Test func aTaskWithADayOnItIsKeptAndRepeatsAreOne() {
        #expect(tasks([
            ("Sam", "I'll start the receipt fix on Monday and have it ready by Thursday night."),
            ("Me", "Let's meet again next Tuesday. Let's resend the invite tomorrow morning."),
            ("Sam", "So I will start the receipt fix on Monday, um."),
            ("Lena", "I'll look into the cost of the yearly plan. I will talk to the host about it."),
        ]) == [
            "Sam: start the receipt fix on Monday and have it ready by Thursday night",
            "Everyone: meet again next Tuesday",
            "Everyone: resend the invite tomorrow morning",
            "Lena: look into the cost of the yearly plan",
            "Lena: talk to the host about it",
        ])
    }

    @Test func notesOutsideTheTaskListDoNotSayWhoDoesWhat() {
        let draft = """
            ## Summary
            - The launch is set for March 3rd.
            - Speaker 1 will fix the payment bug before the beta.
            - Speaker 1 identified a payment bug risk and will fix it before the beta.

            ## Decisions
            - Speaker 2 will own the release notes.

            ## Action items
            - Priya: fix the payment bug
            """
        let cleaned = MeetingText.withoutOwnershipClaims(draft, speakers: ["Speaker 1", "Speaker 2"]) { $0.lowercased().contains("action") }
        #expect(cleaned.contains("March 3rd"))
        #expect(!cleaned.contains("Speaker 1 will"))
        #expect(cleaned.contains("- Speaker 1 identified a payment bug risk."))
        #expect(!cleaned.contains("will fix it"))
        #expect(cleaned.contains("## Decisions\n- None noted"))
        #expect(cleaned.contains("- Priya: fix the payment bug"))
        #expect(MeetingText.needsContext("fix it before the beta"))
        #expect(!MeetingText.needsContext("own the release notes"))
    }
}

@Suite struct MeetingCalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ id: String, startsIn minutes: Double, length: Double = 30, attendees: [String] = [], link: Bool = false) -> CalendarMeeting {
        CalendarMeeting(id: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60), attendees: attendees, hasCallLink: link)
    }

    @Test func aRecordingTakesTheMeetingUnderWay() {
        let events = [event("focus", startsIn: -20, length: 120), event("review", startsIn: -3, attendees: ["Sam"]), event("later", startsIn: 45, attendees: ["Sam"])]
        #expect(MeetingCalendar.current(events, at: now)?.id == "review")
        #expect(MeetingCalendar.current([event("soon", startsIn: 8, link: true)], at: now)?.id == "soon")
        #expect(MeetingCalendar.current([event("later", startsIn: 45, attendees: ["Sam"])], at: now) == nil)
        #expect(MeetingCalendar.current([event("over", startsIn: -90, attendees: ["Sam"])], at: now) == nil)
    }

    @Test func anEventThatIsNotAMeetingNeverNamesARecording() {
        // A game on a sports calendar: timed, nobody invited, a web link but no call link.
        let game = CalendarMeeting(
            id: "game", title: "Los Angeles Chargers at Baltimore Ravens", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(10_000),
            details: "Tickets and more", links: ["https://www.baltimoreravens.com"])
        #expect(!game.isMeeting)
        #expect(MeetingCalendar.current([game], at: now) == nil)
        #expect(MeetingCalendar.current([game], at: now, onCall: true) == nil)
        #expect(MeetingCalendar.starting([game], at: game.start, alreadyOffered: []) == nil)
        // A block of focus time and a reminder are the same.
        #expect(MeetingCalendar.current([event("focus", startsIn: 0, length: 120)], at: now) == nil)
        // An all-day event is never a meeting, whoever is on it.
        let offsite = CalendarMeeting(id: "offsite", title: "Offsite", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(80_000), attendees: ["Sam"], hasCallLink: true, allDay: true)
        #expect(!offsite.isMeeting)
        #expect(MeetingCalendar.current([offsite], at: now, onCall: true) == nil)
        #expect(MeetingCalendar.starting([offsite], at: offsite.start, alreadyOffered: []) == nil)
        // With a real meeting beside it, the real one is taken.
        #expect(MeetingCalendar.current([game, event("sync", startsIn: 5, attendees: ["Sam"])], at: now)?.id == "sync")
    }

    @Test func aMeetingCountsNearItsStartOrWhileACallIsOn() {
        let review = event("review", startsIn: -40, length: 60, attendees: ["Sam"])
        // Forty minutes in, with no call: a recording begun now is not taken to be that meeting.
        #expect(MeetingCalendar.current([review], at: now) == nil)
        // With a call app on the microphone it is.
        #expect(MeetingCalendar.current([review], at: now, onCall: true)?.id == "review")
        // Over: not even on a call.
        #expect(MeetingCalendar.current([event("done", startsIn: -90, attendees: ["Sam"])], at: now, onCall: true) == nil)
        // Fifteen minutes either side of the start; the nearest start wins.
        #expect(MeetingCalendar.current([event("soon", startsIn: 15, link: true)], at: now)?.id == "soon")
        #expect(MeetingCalendar.current([event("later", startsIn: 16, link: true)], at: now) == nil)
        #expect(MeetingCalendar.current([event("a", startsIn: -12, attendees: ["Sam"]), event("b", startsIn: 4, attendees: ["Lena"])], at: now)?.id == "b")
    }

    @Test func aVoiceNoteGivesBackWhatCameFromTheCalendar() {
        let context = RecordingContext(
            event: CalendarMeeting(id: "1", title: "Sync", start: now, end: now, attendees: ["Sam"], hasCallLink: true, details: "Agenda", location: "Room 2", links: ["https://example.com"]),
            app: "Zoom")
        let plain = context.withoutEvent
        #expect(plain.eventTitle == nil && plain.attendees.isEmpty && plain.eventDetails == nil && plain.location == nil && plain.links.isEmpty)
        #expect(plain.app == "Zoom")
        #expect(RecordingContext(event: nil, app: nil).withoutEvent.isEmpty)
    }

    @Test func onlyMeetingsWithOtherPeopleAreAnnouncedAndOnlyOnce() {
        let events = [event("lunch", startsIn: 0), event("standup", startsIn: 0.5, attendees: ["Sam", "Priya"])]
        #expect(MeetingCalendar.starting(events, at: now, alreadyOffered: [])?.id == "standup")
        #expect(MeetingCalendar.starting(events, at: now, alreadyOffered: ["standup"]) == nil)
        #expect(MeetingCalendar.starting([event("standup", startsIn: 10, attendees: ["Sam"])], at: now, alreadyOffered: []) == nil)
        #expect(MeetingCalendar.names(from: "Sam Lee, Priya Shah") == ["Sam Lee", "Priya Shah"])
    }
}

@Suite struct RecordingJournalTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chirp-journal-\(UUID().uuidString)")
    }

    @Test func aRecordingCutShortIsRecovered() throws {
        let dir = folder()
        let journal = try RecordingJournal(directory: dir)
        let context = RecordingContext(eventTitle: "Planning", attendees: ["Ana", "Ben"], app: "Zoom")
        journal.save(.init(startedAt: Date(timeIntervalSince1970: 1000), title: "Planning", notes: "ship friday", context: context, sourceApp: "Zoom"))
        journal.append([0.1, 0.2, 0.3], to: .mic)
        journal.append([0.4], to: .mic)
        journal.append([-0.5, 0.5], to: .system)
        journal.add(TranscriptSegment(itemID: 0, speaker: "Them", start: 2, end: 3, text: "second"))
        journal.add(TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "first"))
        // No close: the app died here.

        let found = try #require(RecordingJournal.recover(from: dir))
        #expect(found.micSamples == 4 && found.systemSamples == 2)
        #expect(RecordingJournal.samples(at: RecordingJournal.url(.mic, in: dir)) == [0.1, 0.2, 0.3, 0.4])
        #expect(journal.samples(.system) == [-0.5, 0.5])
        #expect(found.segments.map(\.text) == ["first", "second"])
        #expect(found.meta.notes == "ship friday")
        #expect(found.meta.context == context)

        journal.discard()
        #expect(RecordingJournal.recover(from: dir) == nil)
    }

    @Test func anEmptyOrMissingJournalIsNothing() throws {
        let dir = folder()
        #expect(RecordingJournal.recover(from: dir) == nil)
        let journal = try RecordingJournal(directory: dir)
        journal.save(.init(startedAt: Date()))
        #expect(RecordingJournal.recover(from: dir) == nil)
        journal.discard()
    }

    @Test func aHalfWrittenLineIsSkipped() throws {
        let dir = folder()
        let journal = try RecordingJournal(directory: dir)
        journal.append([0.1], to: .mic)
        journal.add(TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "whole"))
        journal.close()
        let url = dir.appendingPathComponent("segments.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"speaker":"Me","sta"#.utf8))
        try handle.close()
        #expect(RecordingJournal.recover(from: dir)?.segments.map(\.text) == ["whole"])
        RecordingJournal.remove(dir)
    }
}

@Suite struct RecordingContextTests {
    @Test func theModelIsToldWhatTheCalendarKnows() {
        let context = RecordingContext(
            eventTitle: "Q3 pricing review", attendees: ["Ana Ruiz", "Ben Okafor"], eventDetails: "Agenda: tiers, annual discount",
            location: "https://zoom.us/j/1", app: "Zoom")
        let text = MeetingText.notesMaterial(userNotes: "", points: ["Me: hello"], transcript: true, context: context)
        #expect(text.hasPrefix("ABOUT THIS MEETING"))
        #expect(text.contains("Title: Q3 pricing review"))
        #expect(text.contains("Invited: Ana Ruiz, Ben Okafor"))
        #expect(text.contains("Held in: Zoom"))
        #expect(text.contains("Description: Agenda: tiers, annual discount"))
        #expect(!text.contains("Place:"))
        #expect(text.contains("TRANSCRIPT:\nMe: hello"))
    }

    @Test func nothingKnownAddsNothing() {
        #expect(RecordingContext().material() == nil)
        #expect(RecordingContext().json.isEmpty)
        #expect(RecordingContext(json: "") == RecordingContext())
        let context = RecordingContext(eventTitle: "Sync", attendees: ["Ana"])
        #expect(RecordingContext(json: context.json) == context)
        #expect(MeetingText.notesMaterial(userNotes: "", points: ["x"], context: RecordingContext()) == "POINTS FROM THE TRANSCRIPT:\nx")
    }
}

@Suite struct RecordingKindTests {
    private func line(_ speaker: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(itemID: 0, speaker: speaker, start: 0, end: 1, text: text)
    }

    @Test func onlyMeIsAVoiceNote() {
        #expect(MeetingText.kind(of: [line("Me", "Buy milk.")], invited: []) == .voiceNote)
        #expect(MeetingText.kind(of: [], invited: []) == .voiceNote)
    }

    @Test func anyoneElseMakesItAMeeting() {
        #expect(MeetingText.kind(of: [line("Me", "Hi."), line("Them", "Hello.")], invited: []) == .meeting)
        #expect(MeetingText.kind(of: [line("Me", "Hi."), line("Speaker 2", "Hello.")], invited: []) == .meeting)
        // In person, from the calendar: everyone is on my microphone.
        #expect(MeetingText.kind(of: [line("Me", "Hi.")], invited: ["Ana"]) == .meeting)
    }

    @Test func aShortNoteIsNamedFromItsOpeningWords() {
        #expect(MeetingText.openingTitle([line("Me", "Remind me to book the venue before Friday.")]) == "Remind me to book the venue before Friday")
        #expect(MeetingText.openingTitle([line("Me", "Call the plumber. Then pay the invoice from last week.")]) == "Call the plumber")
        #expect(MeetingText.openingTitle([line("Me", "So. I was thinking about the pricing page and how the tiers are laid out today")])
            == "So. I was thinking about the pricing page…")
        #expect(MeetingText.openingTitle([]) == "")
        #expect(MeetingText.wordCount([line("Me", "one two  three"), line("Me", "four")]) == 4)
    }
}

@Suite struct RecordingExtrasTests {
    @Test func documentsAndScreensReachTheModelInSmallPieces() {
        var context = RecordingContext(eventTitle: "Pricing")
        context.attachments = [.init(name: "Tiers.pdf", text: String(repeating: "Starter is nine dollars. ", count: 200))]
        context.screens = [
            .init(at: 5, app: "Keynote", window: "Q3 deck", text: "Annual discount twenty percent"),
            .init(at: 65, app: "Safari", text: ""),
        ]
        let text = context.material() ?? ""
        #expect(text.contains("DOCUMENTS GIVEN WITH THIS RECORDING"))
        #expect(text.contains("[Tiers.pdf]"))
        #expect(text.contains("ON SCREEN DURING THE RECORDING"))
        #expect(text.contains("[0:05 Keynote, Q3 deck]\nAnnual discount twenty percent"))
        #expect(!text.contains("Safari"))
        #expect(text.count < 1500)
    }

    @Test func olderRecordingsStillDecode() {
        let old = #"{"app":"Zoom","links":[],"attendees":["Ana"]}"#
        let context = RecordingContext(json: old)
        #expect(context.app == "Zoom" && context.attendees == ["Ana"] && context.screens.isEmpty && context.attachments.isEmpty)
    }

    @Test func aScreenIsKeptOnlyWhenItSaysSomethingNew() {
        let slide1 = "Launch plan for the spring release: beta testers start in March, pricing review on Friday, owner Priya"
        let slide1Scrolled = slide1 + " and a footer"
        let slide2 = "Budget by quarter: design forty thousand, engineering ninety thousand, marketing held until the summer campaign"
        #expect(RecordingContext.isNewScreen(slide1, after: nil))
        #expect(!RecordingContext.isNewScreen(slide1Scrolled, after: slide1))
        #expect(RecordingContext.isNewScreen(slide2, after: slide1))
        #expect(!RecordingContext.isNewScreen("File Edit View", after: nil))
    }
}

@Suite struct RecordingNamesTests {
    @Test func namesComeFromWhatTheRecordingWasGiven() {
        var context = RecordingContext(eventTitle: "Launch review", attendees: ["Priya Shah", "sam@example.com"], eventDetails: "Agenda: pick the launch date with Northwind Print Co.")
        context.screens = [.init(at: 3, app: "Keynote", text: "Spring launch plan\n• Owner of the launch checklist: Sam Lee\n• Codename for the release: Kingfisher\n• Budget ceiling: 48,000 dollars")]
        context.attachments = [.init(name: "a.txt", text: "The vendor is Acme Rockets. We talked to Dana on Friday.")]
        let names = context.names()
        #expect(names.contains("Priya Shah"))
        #expect(names.contains("Northwind Print Co"))
        #expect(names.contains("Sam Lee"))
        #expect(names.contains("Kingfisher"))
        #expect(names.contains("Acme Rockets"))
        #expect(names.contains("Dana"))
        // Not names: an address, ordinary words that start a line, days of the week.
        #expect(!names.contains { $0.contains("@") })
        #expect(!names.contains("Spring") && !names.contains("Budget") && !names.contains("Friday") && !names.contains("Agenda"))
        #expect(!names.contains("The") && !names.contains("We"))
    }

    @Test func aQuestionCanLookInDocumentsAndScreens() {
        var context = RecordingContext(eventTitle: "Launch review", attendees: ["Priya Shah"])
        context.screens = [.init(at: 65, app: "Keynote", text: "Budget ceiling:\n48,000 dollars")]
        context.attachments = [.init(name: "agenda.txt", text: "Confirm the vendor")]
        let passages = context.passages()
        #expect(passages.map(\.title) == ["Calendar", "Document: agenda.txt", "On screen at 1:05 in Keynote"])
        #expect(passages[2].text == "Budget ceiling: 48,000 dollars")
        #expect(RecordingContext().passages().isEmpty)
    }
}

@Suite struct NoteSourceTests {
    private let lines = [
        TranscriptSegment(itemID: 0, speaker: "Speaker 1", start: 0, end: 8, text: "Thanks for joining everyone. The beta goes out on March 3rd, and we need two more testers."),
        TranscriptSegment(itemID: 0, speaker: "Me", start: 9, end: 12, text: "Sounds good. I will send the budget numbers by Wednesday."),
        TranscriptSegment(itemID: 0, speaker: "Speaker 2", start: 13, end: 20, text: "Marketing needs the final screenshots by Friday, so please send them to me."),
    ]

    @Test func aPointIsTracedToTheLineItCameFrom() {
        #expect(MeetingText.source(of: "Budget figures will be provided by Wednesday.", in: lines) == 1)
        #expect(MeetingText.source(of: "Marketing requires final screenshots by Friday.", in: lines) == 2)
        #expect(MeetingText.source(of: "Two additional testers need to be onboarded before the beta.", in: lines) == 0)
        #expect(MeetingText.source(of: "I: send the budget numbers by Wednesday", in: lines) == 1)
    }

    @Test func aPointWithNoLineIsNotTraced() {
        #expect(MeetingText.source(of: "None noted", in: lines) == nil)
        #expect(MeetingText.source(of: "The vendor contract was signed in Berlin.", in: lines) == nil)
        #expect(MeetingText.source(of: "Budget", in: lines) == nil)
        #expect(MeetingText.source(of: "anything", in: []) == nil)
    }
}

@Suite struct WovenNotesTests {
    private let summary = """
        ## Summary
        - The beta goes out on March 3rd.
        - Two more testers need to be found.

        ## Key points
        - Budget figures will be provided by Wednesday.
        - Marketing requires final screenshots by Friday.

        ## Decisions
        - None noted

        ## Action items
        - I: send the budget numbers by Wednesday
        - I: find the two testers this week
        """

    @Test func whatChirpWroteSitsUnderTheLineItIsAbout() {
        let woven = MeetingText.weave(userNotes: "- Ask about testers\nBudget is mine\n\n", summary: summary)
        #expect(woven.mine.map(\.text) == ["Ask about testers", "Budget is mine"])
        #expect(woven.mine[0].added == ["Two more testers need to be found."])
        #expect(woven.mine[1].added == ["Budget figures will be provided by Wednesday."])
        // The rest keeps its headings; tasks stay whole even though they mention the same things.
        #expect(woven.sections.map(\.title) == ["Summary", "Key points", "Decisions", "Action items"])
        #expect(woven.sections[0].points == ["The beta goes out on March 3rd."])
        #expect(woven.sections[1].points == ["Marketing requires final screenshots by Friday."])
        #expect(woven.sections[2].points == ["None noted"])
        #expect(woven.sections[3].points.count == 2)
    }

    @Test func nothingTypedLeavesTheNotesAsWritten() {
        let woven = MeetingText.weave(userNotes: "  \n", summary: summary)
        #expect(woven.mine.isEmpty)
        #expect(woven.sections.map(\.points.count) == [2, 2, 1, 2])
    }

    @Test func aLineNobodyWroteAboutStandsAlone() {
        let woven = MeetingText.weave(userNotes: "Remember to thank Dana", summary: summary)
        #expect(woven.mine == [.init(text: "Remember to thank Dana", added: [])])
        #expect(MeetingText.weave(userNotes: "typed", summary: "").sections.isEmpty)
    }

    @Test func aHeadingLeftEmptyIsDropped() {
        let woven = MeetingText.weave(userNotes: "testers", summary: "## Summary\n- Two more testers need to be found.\n\n## Decisions\n- None noted")
        #expect(woven.sections.map(\.title) == ["Decisions"])
    }
}

@Suite struct LongRecordingNotesTests {
    @Test func aPointSaidTwiceIsKeptOnce() {
        let draft = "## Key points\n- Budget is $12,500.\n- budget is $12,500\n- Launch moved to next quarter.\n- Budget is $12,500."
        let notes = MeetingText.assembleNotes(wanted: ["Key points"], draft: draft, replacements: [:])
        #expect(notes == "## Key points\n- Budget is $12,500.\n- Launch moved to next quarter.")
    }

    @Test func aSectionStopsAtAReadableLength() {
        let draft = "## Key points\n" + (1...40).map { "- Point number \($0)" }.joined(separator: "\n")
        let notes = MeetingText.assembleNotes(wanted: ["Key points"], draft: draft, replacements: [:])
        #expect(notes.components(separatedBy: "\n").count == 13)
    }

    @Test func aPromiseMadeTwiceIsOneTask() {
        let line = TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "I will send a revised timeline by Friday.")
        let again = TranscriptSegment(itemID: 0, speaker: "Me", start: 60, end: 61, text: "I will send a revised timeline by Friday.")
        #expect(MeetingText.commitments(in: [line, again]).count == 1)
    }
}

@Suite struct NotesAcrossSectionsTests {
    @Test func aPointUnderTwoHeadingsIsKeptUnderTheFirst() {
        let draft = "## Summary\n- Marketing needs screenshots by Friday.\n\n## Key points\n- The beta is on March 3rd.\n- Marketing needs screenshots by Friday.\n\n## Action items\n- x"
        let notes = MeetingText.assembleNotes(
            wanted: ["Summary", "Key points", "Action items"], draft: draft,
            replacements: ["Action items": ["I: send the screenshots", "Marketing needs screenshots by Friday."]])
        #expect(notes == "## Summary\n- Marketing needs screenshots by Friday.\n\n## Key points\n- The beta is on March 3rd.\n\n## Action items\n- I: send the screenshots\n- Marketing needs screenshots by Friday.")
    }
}

@Suite struct SharedMicrophoneTests {
    private func line(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(itemID: 0, speaker: "Me", start: start, end: end, text: text)
    }

    @Test func peopleSharingAMicrophoneAreToldApart() {
        let segments = [line(0, 8, "Let's start."), line(9, 16, "I have the numbers."), line(17, 24, "Good, thanks.")]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 8), SpeakerTurn(speaker: "b", start: 9, end: 16), SpeakerTurn(speaker: "a", start: 17, end: 24)]
        let out = MeetingText.assignSpeakers(segments, turns: MeetingText.significant(turns), replacing: "Me")
        #expect(out.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(MeetingText.kind(of: out, invited: []) == .meeting)
    }

    @Test func oneVoiceWithAStrayMomentStaysOnePerson() {
        let segments = [line(0, 30, "A long note to myself."), line(31, 60, "And some more of it.")]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 29), SpeakerTurn(speaker: "b", start: 29, end: 30.5), SpeakerTurn(speaker: "a", start: 31, end: 60)]
        let out = MeetingText.assignSpeakers(segments, turns: MeetingText.significant(turns), replacing: "Me")
        #expect(out.map(\.speaker) == ["Me", "Me"])
        #expect(MeetingText.kind(of: out, invited: []) == .voiceNote)
    }

    @Test func aRoomOnACallIsNumberedAfterTheFarSide() {
        let segments = [line(0, 8, "Hello."), line(9, 16, "Hi.")]
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 8), SpeakerTurn(speaker: "b", start: 9, end: 16)]
        let out = MeetingText.assignSpeakers(segments, turns: turns, replacing: "Me", startingAt: 3)
        #expect(out.map(\.speaker) == ["Speaker 3", "Speaker 4"])
    }

    // MARK: Notes written part by part

    @Test func aPartsAnswerIsReadForgivingly() {
        let answer = "**Summary**\nThe group went through the beta numbers and the payment bug in some detail today.\n\n## Key points\n- Thirty one of forty installed.\n* Two crashes, one phone.\n\n## Decisions\n- None noted"
        let found = MeetingText.partSections(of: answer, cut: false)
        #expect(found.map(\.title) == ["Summary", "Key points", "Decisions"])
        #expect(found[0].bullets == ["The group went through the beta numbers and the payment bug in some detail today."])
        #expect(found[1].bullets == ["Thirty one of forty installed.", "Two crashes, one phone."])
        // Cut off by the token limit: the unfinished last line goes, the finished ones stay.
        let cut = MeetingText.partSections(of: "## Summary\n- The beta went out.\n## Key points\n- Thirty one of forty inst", cut: true)
        #expect(cut.map(\.title) == ["Summary", "Key points"])
        #expect(cut[0].bullets == ["The beta went out."] && cut[1].bullets.isEmpty)
    }

    @Test func partsNotesArePutTogetherInOrderWithTheEndKept() {
        let parts: [[(title: String, bullets: [String])]] = [
            [("Summary", ["The beta numbers were reviewed.", "A second point from the start."]), ("Decisions", ["None noted"]), ("Key points", ["Thirty one of forty installed.", "Two crashes on one phone.", "A third thing."])],
            [("summary", ["The payment bug and its two fixes were weighed."]), ("Decisions", ["None noted."]), ("Key points", ["31 of forty people installed the beta.", "The proper fix takes four days."])],
            [("Summary", ["Onboarding was left for next Thursday."]), ("Decisions", ["Ship the proper payment fix.", "Launch stays on March third."]), ("Key points", [])],
        ]
        let draft = MeetingText.mergedDraft(parts: parts, wanted: ["Summary", "Key points", "Decisions", "Action items"]) { $0 == "Summary" ? 1 : 2 }
        let sections = MeetingText.sections(of: draft)
        #expect(sections.map(\.title) == ["Summary", "Key points", "Decisions", "Action items"])
        // One summary point from each part, first to last.
        #expect(sections[0].bullets == ["The beta numbers were reviewed.", "The payment bug and its two fixes were weighed.", "Onboarding was left for next Thursday."])
        // Two a part; "A third thing." is past the part's share.
        #expect(sections[1].bullets == ["Thirty one of forty installed.", "Two crashes on one phone.", "31 of forty people installed the beta.", "The proper fix takes four days."])
        // "None noted" from the early parts does not hide the decisions made at the end.
        #expect(sections[2].bullets == ["Ship the proper payment fix.", "Launch stays on March third."])
        #expect(sections[3].bullets == ["None noted"])
    }

    @Test func aPointSaidAgainInALaterPartIsKeptOnce() {
        #expect(MeetingText.sameThing("Launch stays on March third.", "The launch date stays on March third"))
        #expect(!MeetingText.sameThing("Launch stays on March third.", "The server bill went up to $210."))
        let parts: [[(title: String, bullets: [String])]] = [
            [("Notes", ["Release notes for version 2.4 are due Wednesday."])],
            [("Notes", ["The release notes for version 2.4 are due on Wednesday.", "Call Dad on Thursday."])],
        ]
        #expect(MeetingText.sections(of: MeetingText.mergedDraft(parts: parts, wanted: ["Notes"]) { _ in 9 })[0].bullets
            == ["Release notes for version 2.4 are due Wednesday.", "Call Dad on Thursday."])
    }

    @Test func aLongRecordingsSectionsAreNotCutAtTwelveAndTasksAreNeverCut() {
        let many = (1...30).map { "- Point number \($0) about topic \($0)" }.joined(separator: "\n")
        let short = MeetingText.assembleNotes(wanted: ["Key points"], draft: "## Key points\n" + many, replacements: [:])
        #expect(MeetingText.sections(of: short)[0].bullets.count == 12)
        let long = MeetingText.assembleNotes(wanted: ["Key points"], draft: "## Key points\n" + many, replacements: [:], limit: 30)
        #expect(MeetingText.sections(of: long)[0].bullets.count == 30)
        let tasks = (1...40).map { "Sam: do thing number \($0)" }
        let notes = MeetingText.assembleNotes(wanted: ["Summary", "Action items"], draft: "## Summary\n- One.", replacements: ["Action items": tasks])
        #expect(MeetingText.sections(of: notes)[1].bullets.count == 40)
        // A voice note's to-dos, written by the model, are all kept too, and Home still reads them.
        let todo = (1...20).map { "- Do thing number \($0) today" }.joined(separator: "\n")
        let voice = MeetingText.assembleNotes(wanted: ["To do", "Notes"], draft: "## To do\n" + todo + "\n## Notes\n- A fact.", replacements: [:], taskSection: { $0 == "To do" })
        #expect(MeetingText.sections(of: voice)[0].bullets.count == 20)
    }

    @Test func mergedVoiceNotePartsKeepEveryToDoOnce() throws {
        let parts: [[(title: String, bullets: [String])]] = [
            [("To do", ["Buy gels before Sunday."]), ("Notes", ["The long run is eighteen miles."])],
            [("To do", ["Call Dad on Thursday.", "Buy gels before Sunday"]), ("Notes", ["None noted"])],
        ]
        let draft = MeetingText.mergedDraft(parts: parts, wanted: ["To do", "Notes"]) { _ in .max }
        let summary = MeetingText.assembleNotes(wanted: ["To do", "Notes"], draft: draft, replacements: [:], taskSection: { $0 == "To do" })
        #expect(summary == "## To do\n- Buy gels before Sunday.\n- Call Dad on Thursday.\n\n## Notes\n- The long run is eighteen miles.")
    }

    @Test func aShortTranscriptIsOnePartAndALongOneIsCutEvenlyBetweenSpeakers() {
        let line = "Sam: " + String(repeating: "word ", count: 39) + "end."
        let short = (1...40).map { _ in line }.joined(separator: "\n")  // about 8,000 characters
        #expect(MeetingText.transcriptParts(short) == [short])
        let long = (1...250).map { "Speaker \($0 % 3): " + String(repeating: "word ", count: 39) + "end \($0)." }.joined(separator: "\n")  // about 53,000
        let parts = MeetingText.transcriptParts(long)
        #expect(parts.count == 9)
        #expect(parts.joined(separator: "\n") == long)
        #expect(parts.allSatisfy { $0.hasPrefix("Speaker ") && $0.count <= 6500 })
        #expect(parts.map(\.count).min()! * 10 > parts.map(\.count).max()! * 8)
        #expect(MeetingText.transcriptParts("").isEmpty)
    }

    @Test func theInstructionsExampleIsTakenOutUnlessItWasSaid() {
        let draft = "## To do\n- Buy gels\n\n## Notes\n- Family arrives this weekend for the birthday party.\n- The long run is eighteen miles."
        let cleaned = MeetingText.withoutExample(draft, example: Prompts.voiceNoteExample, transcript: "Me: I need gels. The birthday party is at eleven on Sunday.")
        #expect(cleaned == "## To do\n- Buy gels\n\n## Notes\n- The long run is eighteen miles.")
        // Really said: it stays.
        #expect(MeetingText.withoutExample(draft, example: Prompts.voiceNoteExample, transcript: "Me: My family arrives this weekend for the birthday party.") == draft)
    }

    @Test func waysOfSayingNothing() {
        for nothing in ["None noted", "- none noted.", "**No decision noted.**", "No decisions were made", "Nothing was decided", "N/A"] {
            #expect(MeetingText.isNothing(nothing))
        }
        #expect(!MeetingText.isNothing("No decision on onboarding until next Thursday, when thirty more testers have tried version B"))
        #expect(!MeetingText.isNothing("Nonessential screens were cut from onboarding"))
    }

    @Test func theSectionAnAnswerStoppedIn() {
        #expect(MeetingText.lastSection(of: "## Summary\n- One.\n## Action items\n- Sam: write the notes\n- Sam: write the") == "Action items")
        #expect(MeetingText.lastSection(of: "no headings here") == nil)
    }

    // MARK: Decisions in a long recording

    typealias Note = MeetingText.DecisionNote

    @Test func decisionNotesAreReadFromAnAnswer() {
        let answer = "- Decided: The group decided to use rubber buttons.\n- **Decided:** The remote will have an LCD screen.\n- Open: The cost of voice recognition depends on research.\n- Decided: The remote will have an LCD screen.\n- None\nSome stray sentence."
        #expect(MeetingText.decisionNotes(of: answer, cut: false) == [
            Note("Use rubber buttons."), Note("The remote will have an LCD screen."), Note("The cost of voice recognition depends on research.", open: true),
        ])
        #expect(MeetingText.decisionNotes(of: "- None", cut: false).isEmpty)
        // A looping answer cut at its limit: the repeats and the unfinished line go, and it stops at eight.
        let loop = (1...20).map { "- Decided: Use chip number \($0) on the print." }.joined(separator: "\n") + "\n- Decided: Use chip num"
        #expect(MeetingText.decisionNotes(of: loop, cut: true).count == 8)
    }

    @Test func aDecisionCountsWhenTheLastPartStatesItOrALaterPartRepeatsIt() {
        let decided = MeetingText.decisions(parts: [
            [Note("The remote will be T-shaped with an alarm clock."), Note("Use ordinary push buttons instead of a scroll wheel.")],
            [Note("Use a sophisticated integrated circuit.")],
            [Note("The energy source is a battery."), Note("Push buttons for the user interface.")],
        ])
        // The T shape and the circuit were proposed once and never returned to. Push buttons were said again; the battery is in the last part.
        #expect(decided == ["The energy source is a battery.", "Push buttons for the user interface."])
        #expect(MeetingText.decisions(parts: []).isEmpty)
        #expect(MeetingText.decisions(parts: [[], []]).isEmpty)
    }

    @Test func theLaterStatementIsTheOneKept() {
        let decided = MeetingText.decisions(parts: [
            [Note("The launch date is March third.")],
            [Note("The launch date moves to March tenth.")],
            [Note("Onboarding uses the three screen version.")],
        ])
        #expect(decided == ["The launch date moves to March tenth.", "Onboarding uses the three screen version."])
    }

    @Test func whatIsLeftOpenIsNeverWrittenAsDecided() {
        // Decided early, left open later: open. Both in the last part: open.
        let decided = MeetingText.decisions(parts: [
            [Note("Include voice recognition in the remote.")],
            [Note("Use rubber buttons on the remote."), Note("Voice recognition is included as the star feature."),
             Note("Voice recognition depends on what the research says it costs.", open: true)],
        ])
        #expect(decided == ["Use rubber buttons on the remote.", "Still open: voice recognition depends on what the research says it costs."])
        // Open earlier, settled later: decided.
        #expect(MeetingText.decisions(parts: [[Note("The battery type depends on cost.", open: true)], [Note("The battery type is kinetic.")]]) == ["The battery type is kinetic."])
        // Open once, early, and never returned to: left out like any other single mention.
        #expect(MeetingText.decisions(parts: [[Note("The colour of the logo is undecided.", open: true)], [Note("The battery type is kinetic.")]]) == ["The battery type is kinetic."])
    }

    @Test func notesOnTheSameSubjectAreMatchedByTheirTellingWords() {
        #expect(MeetingText.sameSubject(["rubber", "button", "bottom"], ["rubber", "button", "flip", "top"]))
        #expect(!MeetingText.sameSubject(["rubber", "button", "bottom"], ["kinetic", "battery", "charging"]))
        #expect(!MeetingText.sameSubject(["rubber", "button", "bottom", "side"], ["rubber", "cover", "fruit", "colour"]))
        #expect(MeetingText.sameSubject(["battery"], ["battery", "energy", "source"]))
        #expect(!MeetingText.sameSubject([], ["battery"]))
        // Words that are in most of the notes do not make two notes the same subject.
        let decided = MeetingText.decisions(parts: [
            [Note("The remote control will have a mirror."), Note("The remote control will use a stylus."), Note("The remote control will use solar cells.")],
            [Note("The remote control will have an LCD screen."), Note("The remote control will use kinetic charging.")],
        ])
        #expect(decided == ["The remote control will have an LCD screen.", "The remote control will use kinetic charging."])
    }

    @Test func aTaskSomeoneTookOnIsNotADecisionAndSpellingsMatch() {
        let decided = MeetingText.decisions(
            parts: [[Note("Use fruit and vegetable colours for the rubberised cover.")],
                    [Note("Send Marcus the recording and these notes tonight."), Note("The memo is capped at eight pages."),
                     Note("The rubberized cover will use fruit and vegetable colors.")]],
            tasks: ["send Marcus the recording and these notes tonight"])
        #expect(decided == ["The memo is capped at eight pages.", "The rubberized cover will use fruit and vegetable colors."])
    }

    @Test func theDecisionRequestsPutTheTranscriptFirst() {
        let prompts = Prompts(profile: WritingProfile())
        #expect(prompts.decisionNotesRequest(part: "BODY").hasPrefix("<transcript>\nBODY\n</transcript>"))
        #expect(prompts.agreementRequest(part: "BODY").contains("sums up what has been decided"))
        #expect(Prompts.isDecisionSection("Key Decisions") && !Prompts.isDecisionSection("Summary"))
    }
}

@Suite struct SharedClockTests {
    func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.3)) * 0.3 } }

    @Test func aSideThatStartsLateIsTimedFromWhereItStarted() {
        var seg = PauseSegmenter()
        // The other side joins a minute into the recording.
        #expect(seg.skip(to: 60 * 16_000) == nil)
        let pieces = seg.append(tone(30))
        #expect(pieces.first.map { abs($0.start - 60) < 0.001 } == true)
        #expect(seg.receivedSamples == 90 * 16_000)
    }

    @Test func soundWaitingBeforeAGapIsNotLost() {
        var seg = PauseSegmenter()
        _ = seg.append(tone(2))
        let waiting = seg.skip(to: 10 * 16_000)
        #expect(waiting?.samples.count == 2 * 16_000)
        #expect(waiting?.start == 0)
        // Already past it: nothing moves.
        #expect(seg.skip(to: 5 * 16_000) == nil)
        #expect(seg.finish() == nil)
        _ = seg.append(tone(1))
        #expect(seg.finish()?.start == 10)
    }

    @Test func theJournalIsPaddedWithSilence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-pad-\(UUID().uuidString)")
        let journal = try RecordingJournal(directory: dir)
        journal.append([0.5, 0.5], to: .system)
        journal.pad(.system, to: 10)
        journal.append([0.25], to: .system)
        // Shorter than what is there: nothing is cut off.
        journal.pad(.system, to: 3)
        journal.flush()
        #expect(RecordingJournal.samples(at: RecordingJournal.url(.system, in: dir)) == [0.5, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0.25])
        #expect(RecordingJournal.samples(at: RecordingJournal.url(.system, in: dir), from: 9, count: 5) == [0, 0.25])
        RecordingJournal.remove(dir)
    }
}

@Suite struct VoiceSegmenterTests {
    /// Runs `scores` (one a frame) through the segmenter with a ramp for sound, so pieces can be checked by value.
    func run(_ scores: [Float], _ adjust: (inout VoiceSegmenter) -> Void = { _ in }) -> [PauseSegmenter.Piece] {
        var seg = VoiceSegmenter()
        adjust(&seg)
        var out: [PauseSegmenter.Piece] = []
        for (i, score) in scores.enumerated() {
            seg.append((0..<VoiceSegmenter.frame).map { Float(i * VoiceSegmenter.frame + $0) })
            while seg.nextFrame != nil { if let piece = seg.score(score) { out.append(piece) } }
        }
        if let last = seg.finish() { out.append(last) }
        return out
    }

    @Test func aPieceIsTheSpeechWithALittleBeforeIt() {
        // 10 quiet frames, 20 of speech, 10 quiet.
        let pieces = run(Array(repeating: 0.05, count: 10) + Array(repeating: 0.9, count: 20) + Array(repeating: 0.05, count: 10))
        #expect(pieces.count == 1)
        let frame = Double(VoiceSegmenter.frame) / 16_000
        // Starts 0.6 s before the end of the first speech frame; ends where the quiet began.
        #expect(abs(pieces[0].start - (11 * frame - 0.6)) < 0.001)
        #expect(abs(pieces[0].end - 30 * frame) < 0.001)
        // The samples are the ones at those times.
        #expect(pieces[0].samples.first == Float(Int(pieces[0].start * 16_000)))
    }

    @Test func unbrokenSpeechIsCutAtTheLongestLengthWithNothingLostOrDoubled() {
        let pieces = run(Array(repeating: 0.9, count: 300))
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { Double($0.samples.count) / 16_000 <= 25.01 })
        for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(abs(a.end - b.start) < 0.001) }
        #expect(pieces.map(\.samples.count).reduce(0, +) == 300 * VoiceSegmenter.frame)
    }

    @Test func aShortDipDoesNotEndAPiece() {
        let pieces = run(Array(repeating: 0.9, count: 20) + [0.1, 0.1] + Array(repeating: 0.9, count: 20) + Array(repeating: 0.05, count: 6))
        #expect(pieces.count == 1)
    }

    @Test func silenceIsNotKept() {
        #expect(run(Array(repeating: 0.02, count: 500)).isEmpty)
    }
}
