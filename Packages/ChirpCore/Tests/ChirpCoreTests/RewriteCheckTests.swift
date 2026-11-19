import Foundation
import Testing

@testable import ChirpCore

/// The rule check a rewrite goes through after the language model.
@Suite struct RewriteCheckTests {
    private func problems(_ task: WritingTask, _ original: String, _ result: String) -> [RewriteCheck.Problem] {
        RewriteCheck.problems(task: task, original: original, result: result)
    }

    @Test func theMailExampleIsCaught() {
        // A real case: the question went and "I / my" became "You / your".
        let found = problems(
            .shorten, "How do I make an expenses. I need to get paid back for my hotel and flight.",
            "You need to get paid back for your hotel and flight.")
        #expect(found.contains(.personChanged))
    }

    @Test func aQuestionMustStayAQuestion() {
        #expect(problems(.rephrase(.neutral), "Can you send me the report by Friday?", "I will send you the report by Friday.").contains(.questionLost))
        #expect(problems(.shorten, "Do we really need to meet again this week, or can it wait?", "It can wait.").contains(.questionLost))
        #expect(problems(.rephrase(.formal), "Can you send me the report by Friday?", "Could you send me the report by Friday?").isEmpty)
    }

    @Test func anAnswerIsNotARewrite() {
        let answered = problems(.rephrase(.neutral), "How do I reset my password?", "To reset your password, open Settings and choose Reset.")
        #expect(answered.contains(.questionLost) && answered.contains(.personChanged))
        #expect(problems(.shorten, "What time does the track open on Sundays?", "Sure! Here is a shorter version: When does the track open Sundays?").contains(.reply))
        #expect(problems(.rephrase(.casual), "The meeting moved to Tuesday.", "As an AI, I cannot know your schedule.").contains(.reply))
        #expect(problems(.rephrase(.neutral), "The report is late.", "Could you clarify which report you mean?").contains(.questionAdded))
    }

    @Test func thePersonIsKept() {
        #expect(problems(.rephrase(.neutral), "I think we should move the run.", "You think they should move the run.").contains(.personChanged))
        #expect(problems(.rephrase(.neutral), "The report is late.", "I believe the report is late.").contains(.personChanged))
        #expect(problems(.rephrase(.neutral), "You said the report was late.", "I said the report was late.").contains(.personChanged))
        #expect(problems(.rephrase(.formal), "She told me the track is closed.", "She informed me that the track is closed.").isEmpty)
        // A polite request may say "you" where the text only implied it.
        #expect(!problems(.rephrase(.formal), "Send the kit list to my address.", "Could you send the kit list to my address?").contains(.personChanged))
    }

    @Test func numbersNamesAndDatesAreKeptAndNoneAdded() {
        #expect(problems(.shorten, "The flight was $412 and the hotel was $380 for two nights.", "The flight was $412 and the hotel $308.").contains(.newNumber))
        #expect(problems(.shorten, "The flight was $412 and the hotel was $380 for two nights.", "The flight and hotel cost a lot.").contains(.lostNumber))
        #expect(problems(.rephrase(.neutral), "We meet at the track at 6.", "We meet with Sam at the track at 6.").contains(.newName))
        #expect(problems(.rephrase(.neutral), "We meet at the track soon.", "We meet at the track on Tuesday.").contains(.newName))
        // "two" and "2" are the same number.
        #expect(!problems(.rephrase(.neutral), "The hotel was two nights in Denver.", "The hotel in Denver was 2 nights.").contains(.newNumber))
    }

    @Test func noGreetingSignOffOrPromise() {
        let notes = "- flight to Denver $412, booked it myself\n- hotel two nights, $380\n- need it paid back before the 30th"
        #expect(problems(.writeOut, notes, "Hi Sam, I booked the flight to Denver myself for $412, and the hotel was $380 for two nights. I need both paid back before the 30th.").contains(.greeting))
        #expect(problems(.writeOut, notes, "I booked the flight to Denver myself for $412, and the hotel was $380 for two nights. I need both paid back before the 30th. Thanks!").contains(.signOff))
        #expect(problems(.writeOut, notes, "I booked the flight to Denver myself for $412, and the hotel was $380 for two nights. I need both paid back before the 30th, and I will send the receipts.").contains(.promise))
    }

    @Test func writeOutOnTheCanvasExamplePasses() {
        let notes = "- flight to Denver $412, booked it myself\n- hotel two nights, $380\n- need it paid back before the 30th"
        let out = "I booked the flight to Denver myself for $412, and the hotel was $380 for two nights. I need both paid back before the 30th."
        #expect(problems(.writeOut, notes, out) == [])
    }

    @Test func writeOutMayNotAddOrDrop() {
        let notes = "- flight to Denver $412, booked it myself\n- hotel two nights, $380\n- need it paid back before the 30th"
        // A reason nobody gave.
        #expect(problems(.writeOut, notes, "I booked the flight to Denver myself for $412 because the company portal was broken and the travel agent never answered, and the hotel was $380 for two nights. I need both paid back before the 30th.").contains(.addedContent))
        // The last point left out.
        let dropped = problems(.writeOut, notes, "I booked the flight to Denver myself for $412, and the hotel was $380 for two nights.")
        #expect(dropped.contains(.pointMissing) || dropped.contains(.lostNumber))
        #expect(problems(.writeOut, "- call the venue\n- order the bibs", "I need to call the venue.").contains(.pointMissing))
    }

    @Test func shortenMustBeShorterAndTheSameTextIsNotOffered() {
        #expect(problems(.shorten, "Thanks for the notes.", "Thanks for the notes.") == [.notShorter])
        #expect(problems(.shorten, "Thanks for the notes.", "Thank you very much for the notes you sent.").contains(.notShorter))
        #expect(problems(.rephrase(.neutral), "Thanks for the notes.", "thanks for the  notes.") == [.unchanged])
        // A proofread with nothing to correct is an answer.
        #expect(problems(.fix, "Thanks for the notes.", "Thanks for the notes.") == [])
    }

    @Test func aGoodShortenAndProofreadPass() {
        let long = "I think we should move the long run to Saturday for the first eight weeks, because the track is closed on Sundays until March and most of the group would rather keep one full day free at the weekend, and then we can look at it again once the evenings are lighter and the track is open."
        let short = "I think we should move the long run to Saturday for the first eight weeks, because the track is closed on Sundays until March, and look at it again after that."
        #expect(problems(.shorten, long, short) == [])
        #expect(problems(.fix, "I recieved the plan and it look good to me.", "I received the plan and it looks good to me.") == [])
        #expect(problems(.fix, "How do I make an expenses claim?", "You make an expenses claim in the portal.").isEmpty == false)
    }

    // What the first run of the test sets through the model showed the check was missing or getting wrong.

    @Test func aQuestionTypedWithoutItsMarkIsStillAQuestion() {
        // The user's own text has no question mark: giving it one is not asking something new.
        #expect(problems(.rephrase(.casual), "How do I make an expenses. I need to get paid back for my hotel and flight.", "How do I make an expense claim? I need to get paid back for my hotel and flight.") == [])
        // And answering it is still caught.
        #expect(problems(.shorten, "How do I make an expenses. I need to get paid back for my hotel.", "I need to get paid back for my hotel.").contains(.questionLost))
    }

    @Test func nobodyInTheTextGoesMissing() {
        // "You said you would" went, and the complaint became a statement.
        #expect(problems(.rephrase(.formal), "You said you would send the photos from the race on Sunday. I have not got them yet.", "I have not yet received the photos from the race.").contains(.personChanged))
        // "They" became "the client", whom nobody mentioned.
        #expect(problems(.rephrase(.formal), "They want the deposit of $500 by Friday.", "The client requires a $500 deposit by Friday.").contains(.personChanged))
        // "I want to test it" became "Dev wants to test it".
        #expect(problems(.shorten, "Please do not merge the branch yet. Dev found a problem with the migration and I want to test it first.", "Dev found a problem with the migration and wants to test it first.").contains(.personChanged))
    }

    @Test func numbersWrittenAsWordsAreTheSameNumbers() {
        let notes = "- invoice for October attached\n- 42 hours at $85\n- total $3,570\n- due in 30 days"
        let out = "The invoice for October is attached. It is 42 hours at $85, a total of $3,570, due in thirty days."
        #expect(!problems(.writeOut, notes, out).contains(.newNumber))
        #expect(!problems(.writeOut, notes, out).contains(.lostNumber))
        #expect(RewriteCheck.numbers(RewriteCheck.words("forty-two hours on the twenty-eighth and the 30th")) == ["42", "28", "30"])
        // A sum nobody wrote down is a new number.
        #expect(problems(.writeOut, "budget for Q3 is $18,000\nspent $11,400 so far", "The budget for Q3 is $18,000. I have spent $11,400 so far, which leaves $6,600.").contains(.newNumber))
    }

    @Test func aReasonNobodyGaveAndANameThatWent() {
        #expect(problems(.writeOut, "review went badly yesterday. my points were talked over. want to try again next week", "The review went badly yesterday because my points were talked over, and I want to try again next week.").contains(.reason))
        // A reason the text gives may be given.
        #expect(!problems(.rephrase(.neutral), "We moved the run because the track is closed.", "We shifted the run because the track is closed.").contains(.reason))
        #expect(problems(.rephrase(.casual), "The watch from Garmin synced last week's runs.", "The watch synced up last week.").contains(.lostName))
        #expect(problems(.rephrase(.casual), "Can you send me the report by Friday?", "Got it. Can you send me the report by Friday?").contains(.reply))
    }

    @Test func writtenOutNotesMaySayIAndYou() {
        // Notes leave the subject out; writing them out puts it back.
        #expect(problems(.writeOut, "- meeting moved to 3 pm\n- bring printed budget", "The meeting has moved to 3 pm. Please bring your printed budget.") == [])
        #expect(problems(.writeOut, "quote from the printer came in at $640\nasking for a second quote", "The quote from the printer came in at $640. I am asking for a second quote.") == [])
        // Only the marks changed: nothing was written out.
        #expect(problems(.writeOut, "track closed Sundays until March\nmove long run to Saturday", "Track closed Sundays until March. Move long run to Saturday.") == [.unchanged])
        // One new word about something the notes never said.
        #expect(problems(.writeOut, "- 200 emails to get through\n- back since Tuesday", "I have sent 200 emails to get through. I have been back since Tuesday.").contains(.addedContent))
    }

    @Test func notesThatStartLikeQuestionsAreNotQuestions() {
        #expect(RewriteCheck.questions("will tell customers on Monday") == 0)
        #expect(RewriteCheck.questions("do not merge the branch") == 0)
        #expect(RewriteCheck.questions("Do you know when it opens. How do I book") == 2)
        #expect(problems(.writeOut, "launch postponed to 12 May\npayment provider has not finished review\nwill tell customers on Monday", "The launch is postponed to 12 May, but the payment provider has not finished its review, and we will tell customers on Monday.") == [])
        // Someone the notes never mentioned.
        #expect(problems(.writeOut, "quote from the printer came in at $640\nasking for a second quote", "The quote from the printer came in at $640, so they are asking for a second quote.").contains(.personChanged))
        // A name at the start of a line of notes is a sentence start, not a name gone missing.
        #expect(!problems(.writeOut, "bug probably in config loading\nDev is testing a fix today", "The bug is probably in config loading, and Dev is testing a fix today.").contains(.lostName))
    }

    @Test func whatTheLastRunLetThrough() {
        // "has not finished" came back as "finished".
        #expect(problems(.shorten, "We have decided to postpone the launch until the 12th of May, because the payment provider has not finished their review.", "We postponed the launch until May 12, as the payment provider finished their review.").contains(.negationLost))
        // A name at the start of a sentence, one letter out.
        #expect(problems(.rephrase(.casual), "Garmin synced last week's runs, so you can see the pace I am starting from.", "Garman synced up last week's runs, so you can see the pace I'm starting from.").contains(.lostName))
        // The same word used another way is not a misspelling.
        #expect(!problems(.rephrase(.neutral), "Thanks for the notes on Friday.", "Thank you for the notes on Friday.").contains(.lostName))
        #expect(!problems(.rephrase(.neutral), "Sorry for the late reply, I was not at my desk.", "Sorry for replying late, I wasn't at my desk.").contains(.negationLost))
    }

    @Test func aSummaryIsNotChecked() {
        #expect(problems(.summarize, "A long text about many things.", "- many things") == [])
    }

    @Test func whatIsSaidInstead() {
        #expect(RewriteCheck.message(task: .shorten, problems: [.notShorter]) == "Nothing to shorten here.")
        #expect(RewriteCheck.message(task: .shorten, problems: [.personChanged]) == "Chirp could not shorten this without changing what it says. Your text is as it was.")
        #expect(RewriteCheck.message(task: .writeOut, problems: [.greeting]).contains("without adding to it"))
        #expect(RewriteCheck.reminder(for: [.questionLost]).contains("stays a question"))
    }

    @Test func wrappingIsTakenOff() {
        #expect(RewriteCheck.tidy("\"I booked the flight.\"") == "I booked the flight.")
        #expect(RewriteCheck.tidy("Rewritten: I booked the flight.") == "I booked the flight.")
        #expect(RewriteCheck.tidy("She said \"no\" and \"yes\"") == "She said \"no\" and \"yes\"")
    }
}

/// Snippets where the user types, and what is suggested for saving.
@Suite struct SnippetOfferTests {
    private let address = Snippet(cue: "my address", text: "14 Alder Lane, Portland, OR 97214")

    @Test func aTypedCueIsOfferedLikeAFix() {
        let text = "Send the kit list to my address and I will sort the rest."
        let found = SnippetOffers.issues(in: text, snippets: [address])
        #expect(found.count == 1)
        #expect(found.first?.flagged(in: text) == "my address")
        #expect(found.first?.category == .snippet)
        #expect(found.first?.message == "Your snippet “my address”.")
        #expect(Proofreading.fixAll(found, in: text) == "Send the kit list to 14 Alder Lane, Portland, OR 97214 and I will sort the rest.")
    }

    @Test func onlyWholeWordsAndOnlySwitchedOn() {
        #expect(SnippetOffers.issues(in: "This is not my addressbook.", snippets: [address]).isEmpty)
        #expect(SnippetOffers.issues(in: "Use My Address here", snippets: [address]).count == 1)
        var off = address
        off.enabled = false
        #expect(SnippetOffers.issues(in: "to my address", snippets: [off]).isEmpty)
        // The longer cue wins where two overlap.
        let work = Snippet(cue: "my address at work", text: "2 Office Rd")
        let both = SnippetOffers.issues(in: "ship to my address at work", snippets: [address, work])
        #expect(both.count == 1 && both.first?.suggestions.first?.text == "2 Office Rd")
    }

    @Test func theSentenceFixAppliesASnippetToo() {
        let text = "Send it to my address."
        let found = SnippetOffers.issues(in: text, snippets: [address])
        let fix = Proofreading.sentenceFix(in: text, caret: (text as NSString).length, issues: found)
        #expect(fix?.replacement == "Send it to 14 Alder Lane, Portland, OR 97214.")
    }

    @Test func aSentenceSaidOftenIsSuggested() {
        let said = ["Thanks, talk soon.", "Move the documents.", "thanks talk soon", "Thanks, talk soon!", "Thanks, talk soon."]
        #expect(SnippetOffers.repeated(dictations: said, snippets: []) == SnippetOffers.Repeat(text: "Thanks, talk soon.", count: 4))
        #expect(SnippetOffers.repeated(dictations: said, snippets: [Snippet(cue: "sign off", text: "Thanks, talk soon.")]) == nil)
        #expect(SnippetOffers.repeated(dictations: said, snippets: [], declined: ["thanks talk soon"]) == nil)
        #expect(SnippetOffers.repeated(dictations: ["Okay.", "Okay.", "Okay.", "Okay."], snippets: []) == nil)
    }
}

/// The bird at the end of a sentence, and the one button on a note.
@Suite struct SentenceOfferTests {
    private func spelling(_ text: String, _ word: String, _ fix: String) -> WritingIssue {
        let r = (text as NSString).range(of: word)
        return WritingIssue(start: r.location, end: NSMaxRange(r), rule: "s", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: fix)])
    }

    @Test func everySentenceWithAFixHasOne() {
        let text = "I recieved the plan and it look good to me. I can make Tuesdays. Send teh list."
        let issues = [spelling(text, "recieved", "received"), spelling(text, "look", "looks"), spelling(text, "teh", "the")]
        let fixes = Proofreading.sentenceFixes(in: text, issues: issues)
        #expect(fixes.count == 2)
        #expect(fixes.first?.count == 2)
        #expect((text as NSString).substring(with: fixes[0].range) == "I recieved the plan and it look good to me.")
        #expect(fixes[1].replacement == "Send the list.")
    }

    // One bird, for the sentence at the cursor only, while it has a fix.
    @Test func onlyTheSentenceAtTheCursorGetsTheBird() {
        let text = "I recieved the plan and it look good to me. I can make Tuesdays. Send teh list."
        let issues = [spelling(text, "recieved", "received"), spelling(text, "look", "looks"), spelling(text, "teh", "the")]
        let ns = text as NSString
        func bird(at caret: Int?) -> String? {
            SentenceBirdRule.sentence(in: text, caret: caret, issues: issues).map { ns.substring(with: $0.range) }
        }
        // Typing at the end: the last sentence, not the first one with a fix.
        #expect(bird(at: ns.length) == "Send teh list.")
        // Inside the first sentence, or just after its full stop and space.
        #expect(bird(at: 5) == "I recieved the plan and it look good to me.")
        #expect(bird(at: ns.range(of: "I can").location) == "I recieved the plan and it look good to me.")
        // In the clean middle sentence: none.
        #expect(bird(at: ns.range(of: "Tuesdays").location) == nil)
        // A selection (no caret): none.
        #expect(bird(at: nil) == nil)
        // Once its fix is in, the sentence has no bird.
        let fixed = "Send the list."
        #expect(SentenceBirdRule.sentence(in: fixed, caret: 14, issues: []) == nil)
        // An older paragraph with a fix gets nothing while the cursor is in the new one.
        let two = "I recieved the plan.\n\nThe new paragraph is fine"
        let old = [spelling(two, "recieved", "received")]
        #expect(SentenceBirdRule.sentence(in: two, caret: (two as NSString).length, issues: old) == nil)
    }

    @Test func theBirdNeverCoversText() {
        // Characters 8 wide on a line 20 tall; the field's visible edge at x = 400.
        func box(_ x: CGFloat, line: CGFloat = 0) -> CGRect { CGRect(x: x, y: 100 + line * 24, width: 8, height: 20) }
        let side = SentenceBirdRule.side(forLine: 20)
        #expect(side == 16)
        // At the end of what is typed: just after the full stop, on its line.
        let open = SentenceBirdRule.place(end: box(100), next: nil, right: 400)
        #expect(open == CGRect(x: 111, y: 102, width: 16, height: 16))
        // The next word on the same line far enough away (a wide gap): after the full stop.
        #expect(SentenceBirdRule.place(end: box(100), next: box(140), right: 400)?.minX == 111)
        // The sentence ends its line and the text goes on below: after it, if the edge leaves room.
        #expect(SentenceBirdRule.place(end: box(300), next: box(10, line: 1), right: 400)?.minX == 311)
        #expect(SentenceBirdRule.place(end: box(385), next: box(10, line: 1), right: 400) == nil)
        // Whatever the case, the bird stays inside its line's height, so it cannot reach the next line.
        for r in [open].compactMap({ $0 }) { #expect(r.minY >= 100 && r.maxY <= 120) }
    }

    // With more text after the sentence on its line and no room after its last character, the bird
    // never goes to the line's end (it read as belonging to the other sentence). A small bird sits just
    // above the last character when nothing is there; otherwise there is none.
    @Test func noRoomAfterTheSentenceMeansASmallBirdAboveOrNone() {
        // Lines 20 tall, 4 apart (24 from top to top); characters 8 wide.
        func box(_ x: CGFloat, line: CGFloat = 0) -> CGRect { CGRect(x: x, y: 100 + line * 24, width: 8, height: 20) }
        let small = SentenceBirdRule.smallSide(forLine: 20)
        #expect(small == 11)
        // First line, with room above it inside the field: a small bird centred over the full stop.
        let first = SentenceBirdRule.place(end: box(100), next: box(116), right: 400, top: 80, textAbove: [])
        #expect(first == CGRect(x: 104 - small / 2, y: 100 - 1 - small, width: small, height: small))
        // It is above the character and covers nothing: not the character, nor the next word.
        if let first { #expect(first.maxY <= 100 && first.maxX <= 116) }
        // Not at the line's end, wherever that is.
        #expect(first.map { $0.minX < 116 } == true)
        // First line, the field's top edge too close: no bird.
        #expect(SentenceBirdRule.place(end: box(100), next: box(116), right: 400, top: 95, textAbove: []) == nil)
        // A line above with text over the character: only 4 points between lines, so no bird.
        let above = [CGRect(x: 10, y: 100, width: 300, height: 20)]
        #expect(SentenceBirdRule.place(end: box(100, line: 1), next: box(116, line: 1), right: 400, top: 80, textAbove: above) == nil)
        // A short line above that ends before the character: the space over it is empty, so a small bird.
        let short = [CGRect(x: 10, y: 100, width: 40, height: 20)]
        let overEmpty = SentenceBirdRule.place(end: box(100, line: 1), next: box(116, line: 1), right: 400, top: 80, textAbove: short)
        #expect(overEmpty != nil)
        if let overEmpty { #expect(overEmpty.maxY <= 124 && overEmpty.minX > 50) }
        // The app does not say where its lines are (a web editor): no bird, rather than a guess.
        #expect(SentenceBirdRule.place(end: box(100), next: box(116), right: 400, top: 80, textAbove: nil) == nil)
        #expect(SentenceBirdRule.place(end: box(100), next: box(116), right: 400) == nil)
        // Near the right edge, the small bird is moved in so it stays inside the field.
        let edge = SentenceBirdRule.place(end: box(392), next: nil, right: 400, top: 60, textAbove: [])
        #expect(edge.map { $0.maxX <= 400 && $0.maxY <= 100 } == true)
    }

    @Test func aNoteWithoutAFixGetsOneRewrite() {
        let long = WritingIssue(start: 0, end: 10, rule: "LongSentences", kind: "Readability", message: "This sentence is 57 words long.")
        #expect(Proofreading.sentenceRewrite(for: long)?.title == "Shorten this sentence")
        #expect(Proofreading.sentenceRewrite(for: long)?.task == .shorten)
        let style = WritingIssue(start: 0, end: 10, rule: "Other", kind: "Style", message: "")
        #expect(Proofreading.sentenceRewrite(for: style)?.title == "Rephrase this sentence")
        let fixable = WritingIssue(start: 0, end: 3, rule: "s", kind: "Style", message: "", suggestions: [Fix(kind: .replace, text: "x")])
        #expect(Proofreading.sentenceRewrite(for: fixable) == nil)
        #expect(Proofreading.rewriteSummary(task: .shorten, from: "one two three four", to: "one two") == "Shortened from 4 words to 2.")
    }

    @Test func aSnippetOfferWithNothingToPutInIsNotShown() {
        let empty = WritingIssue(start: 0, end: 4, rule: "Snippet", kind: "Snippet", message: "")
        #expect(Proofreading.visible([empty], in: "text here", dismissed: []).isEmpty)
    }
}
