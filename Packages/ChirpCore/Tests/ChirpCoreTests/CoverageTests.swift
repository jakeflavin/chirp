import Foundation
import Testing

@testable import ChirpCore

/// Small tests for behaviour nothing else exercises.

@Suite struct SecretsDetailTests {
    @Test func emptyTextHoldsNothing() {
        #expect(Secrets.ranges(in: "").isEmpty)
        #expect(!Secrets.contains(""))
    }

    @Test func aKeyIsFoundWhereItSits() {
        #expect(Secrets.ranges(in: "key: ghp_abcdefghijklmnop1234 done") == [NSRange(location: 5, length: 24)])
        #expect(Secrets.ranges(in: "TOKEN=ghp_abcdefghijklmnop1234") == [NSRange(location: 6, length: 24)])
    }

    @Test func quotesAroundAKeyDoNotHideIt() {
        #expect(Secrets.isSecret("\"sk-abcdefghijklmnopqrstuv\""))
        #expect(Secrets.isSecret("9f86d081884c7d659a2feaa0c55ad015"))
    }

    @Test func linksAddressesAndDottedNamesAreNotKeys() {
        #expect(!Secrets.isSecret("https://example.com/a1b2c3d4e5f6g7h8"))
        #expect(!Secrets.isSecret("someone1234@example-mail.com"))
        #expect(!Secrets.isSecret("com.example.app.settings.panel"))
        #expect(!Secrets.isSecret("short"))
    }
}

@Suite struct ProofreadingDetailTests {
    let text = "I saw teh cat"
    var teh: WritingIssue { WritingIssue(start: 6, end: 9, rule: "SpellCheck", kind: "Spelling", message: "") }

    @Test func nothingMovesWhenTheTextIsTheSame() {
        #expect(Proofreading.carry([teh], from: text, to: text) == [teh])
    }

    @Test func labelsSayWhatAFixDoes() {
        #expect(teh.label(for: Fix(kind: .replace, text: ""), in: text) == "Remove")
        #expect(teh.label(for: Fix(kind: .replace, text: " "), in: text) == "One space")
        #expect(teh.label(for: Fix(kind: .replace, text: "  "), in: text) == "Fix the spacing")
        #expect(teh.label(for: Fix(kind: .insert, text: ","), in: text) == "teh,")
        #expect(teh.label(for: Fix(kind: .remove, text: ""), in: text) == "Remove “teh”")
    }

    @Test func anIssuePastTheEndOfTheTextIsIgnored() {
        let past = WritingIssue(start: 10, end: 40, rule: "R", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "x")])
        #expect(past.flagged(in: text) == "")
        let result = Proofreading.apply(Fix(kind: .replace, text: "x"), to: past, in: text)
        #expect(result.text == text)
        #expect(result.delta == 0)
        #expect(Proofreading.visible([past], in: text, dismissed: []).isEmpty)
        let empty = WritingIssue(start: 3, end: 3, rule: "R", kind: "Spelling", message: "")
        #expect(Proofreading.visible([empty], in: text, dismissed: []).isEmpty)
    }

    @Test func removingTheFirstWordTakesTheSpaceAfterIt() {
        let doubled = WritingIssue(start: 0, end: 3, rule: "R", kind: "Repetition", message: "")
        let result = Proofreading.apply(Fix(kind: .remove, text: ""), to: doubled, in: "the the cat")
        #expect(result.text == "the cat")
        #expect(result.delta == -4)
    }

    @Test func insertingGoesAfterTheFlaggedText() {
        let hello = WritingIssue(start: 0, end: 5, rule: "R", kind: "Grammar", message: "")
        let result = Proofreading.apply(Fix(kind: .insert, text: ","), to: hello, in: "Hello world")
        #expect(result.text == "Hello, world")
        #expect(result.delta == 1)
    }

    @Test func aRuleThatIsNeverRightIsHidden() {
        let issue = WritingIssue(start: 0, end: 1, rule: "MissingPreposition", kind: "Grammar", message: "")
        #expect(Proofreading.visible([issue], in: text, dismissed: []).isEmpty)
    }

    @Test func aDismissalForOneWordLeavesOtherWordsFlagged() {
        let other = WritingIssue(start: 10, end: 13, rule: "SpellCheck", kind: "Spelling", message: "")
        let visible = Proofreading.visible([teh, other], in: text, dismissed: [DismissedRule(ruleKey: "SpellCheck", text: "teh")])
        #expect(visible == [other])
    }

    @Test func styleIssuesDoNotMoveTheCursor() {
        let style = WritingIssue(start: 0, end: 1, rule: "R", kind: "Style", message: "", suggestions: [Fix(kind: .replace, text: "Myself")])
        #expect(Proofreading.position(8, afterFixing: [style], in: text) == 8)
        #expect(Proofreading.position(8, afterFixing: [style], in: text, categories: [.style]) == 13)
    }

    @Test func namesAreToldFromSentenceStarts() {
        func spelling(_ word: String, in text: String, kind: String = "Spelling") -> WritingIssue {
            let r = (text as NSString).range(of: word)
            return WritingIssue(start: r.location, end: NSMaxRange(r), rule: "SpellCheck", kind: kind, message: "")
        }
        #expect(Proofreading.likelyName(spelling("Priyaa", in: "We met Priyaa today"), in: "We met Priyaa today"))
        #expect(!Proofreading.likelyName(spelling("Priyaa", in: "We met Priyaa today", kind: "Grammar"), in: "We met Priyaa today"))
        #expect(Proofreading.likelyName(spelling("WordCraft", in: "WordCraft is here"), in: "WordCraft is here"))
        #expect(!Proofreading.likelyName(spelling("priyaa", in: "We met priyaa today"), in: "We met priyaa today"))
        #expect(!Proofreading.likelyName(spelling("Priyaa", in: "Name: Priyaa"), in: "Name: Priyaa"))
        #expect(!Proofreading.likelyName(spelling("Thier", in: "It ended. Thier turn"), in: "It ended. Thier turn"))
    }

    @Test func noSentenceFixWithoutSomethingToFix() {
        #expect(Proofreading.sentenceFix(in: "", caret: 0, issues: [teh]) == nil)
        #expect(Proofreading.sentenceFix(in: text, caret: -1, issues: [teh]) == nil)
        #expect(Proofreading.sentenceFix(in: text, caret: 4, issues: []) == nil)
        // An issue with nothing to offer is not a fix.
        #expect(Proofreading.sentenceFix(in: text, caret: 4, issues: [teh]) == nil)
    }

    @Test func theModelSayingNothingGivesNoIssues() {
        #expect(Proofreading.modelIssues(original: "", corrected: "Something").isEmpty)
        #expect(Proofreading.modelIssues(original: "Something", corrected: "  \n").isEmpty)
        #expect(Proofreading.modelIssues(original: "Same words", corrected: "Same words").isEmpty)
    }

    @Test func badCheckerOutputDecodesToNothing() {
        #expect(Proofreading.decode("not json").isEmpty)
        #expect(Proofreading.decode("[]").isEmpty)
    }
}

@Suite struct DictionaryDetailTests {
    let kubernetes = DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"])

    @Test func anEmptyDictionaryChangesNothing() {
        let (text, log) = DictionaryCorrector(entries: []).correctWithLog("leave  this alone")
        #expect(text == "leave  this alone")
        #expect(log.isEmpty)
    }

    @Test func lineBreaksAndPunctuationSurvive() {
        let corrector = DictionaryCorrector(entries: [kubernetes])
        #expect(corrector.correct("use cooper netties\nnow") == "use Kubernetes\nnow")
        #expect(corrector.correct("(cooper netties).") == "(Kubernetes).")
    }

    @Test func shortWordsNeedASoundsLike() {
        #expect(DictionaryCorrector(entries: [DictionaryEntry(term: "Koa")]).correct("I use boa daily") == "I use boa daily")
        #expect(DictionaryCorrector(entries: [DictionaryEntry(term: "Koa", soundsLike: ["boa"])]).correct("I use boa daily") == "I use Koa daily")
    }

    @Test func helpers() {
        #expect(DictionaryCorrector.normalize("AT&T") == "atandt")
        #expect(DictionaryCorrector.normalize("Anaïs!") == "anais")
        #expect(DictionaryCorrector.levenshtein("", "abc") == 3)
        #expect(DictionaryCorrector.levenshtein("abc", "") == 3)
        #expect(DictionaryCorrector.levenshtein("kitten", "sitting") == 3)
        let parts = DictionaryCorrector.split("“Hello!”")
        #expect(parts.lead == "“")
        #expect(parts.core == "Hello")
        #expect(parts.trail == "!”")
        #expect(DictionaryCorrector.split("...").core == "")
        #expect(DictionaryCorrector.soundex("") == "")
    }

    @Test func aSnippetKeepsThePunctuationAroundIt() {
        let expander = SnippetExpander(snippets: [Snippet(cue: "my address", text: "1 Main St")])
        #expect(expander.expand("send it to my address, please") == "send it to 1 Main St, please")
    }

    @Test func aSnippetEndingInAStopTakesNoSecondOne() {
        let expander = SnippetExpander(snippets: [Snippet(cue: "sign off", text: "Thanks, Alex.")])
        #expect(expander.expand("okay sign off.") == "okay Thanks, Alex.")
    }

    @Test func disabledAndEmptySnippetsDoNothing() {
        let expander = SnippetExpander(snippets: [Snippet(cue: "my address", text: "1 Main St", enabled: false), Snippet(cue: "  ", text: "x")])
        #expect(expander.expand("send it to my address") == "send it to my address")
    }
}

@Suite struct InsertionDetailTests {
    @Test func nothingDictatedStaysNothing() {
        #expect(Insertion.adapt("", before: "word", after: nil) == "")
    }

    @Test func insideBracketsThereAreNoSpaces() {
        #expect(Insertion.adapt("Hello", before: "(", after: ")") == "Hello")
    }

    @Test func textWithoutACommandIsUnchanged() {
        let result = SpokenCommands.trailingEnter("Press enter to continue, then wait")
        #expect(result.text == "Press enter to continue, then wait")
        #expect(!result.pressEnter)
    }

    @Test func aCommandAloneLeavesNoText() {
        let result = SpokenCommands.trailingEnter("Press enter.")
        #expect(result.text == "")
        #expect(result.pressEnter)
    }
}

@Suite struct LongFormDetailTests {
    @Test func thePieceLengthIsKeptWithinBounds() {
        #expect(LongForm(targetSeconds: 1).targetSeconds == 10)
        #expect(LongForm(targetSeconds: 500).targetSeconds == 60)
        #expect(LongForm().maxSamples == 560_000)
        #expect(LongForm().minSamples == 80_000)
    }

    @Test func everyPauseIsACandidate() {
        let cuts = LongForm.candidates(speech: [100..<200, 400..<500], samples: 600)
        #expect(cuts.map(\.at) == [50, 300, 550])
        #expect(cuts[1].gapSeconds == 200.0 / 16_000)
        #expect(LongForm.candidates(speech: [], samples: 0).isEmpty)
        // Speech from the first sample to the last leaves no pause.
        #expect(LongForm.candidates(speech: [0..<600], samples: 600).isEmpty)
    }

    @Test func emptyPiecesAreLeftOutOfTheJoin() {
        #expect(LongForm.join(["  a ", "", "b\n"]) == "a b")
        #expect(LongForm.join([]) == "")
    }
}

@Suite struct WordDiffDetailTests {
    @Test func emptySides() {
        #expect(WordDiff.diff(from: "", to: "").isEmpty)
        #expect(WordDiff.diff(from: "a", to: "") == [.removed("a")])
        #expect(WordDiff.diff(from: "", to: "b") == [.added("b")])
    }

    @Test func everyWordHasItsPlaceInTheText() {
        for text in ["", "one", " a  b ", "a\tb c", "x\r\ny", "é 👨‍👩‍👧 z\u{2028}w"] {
            let ns = text as NSString
            #expect(WordDiff.wordRanges(text).map { ns.substring(with: $0) } == WordDiff.tokens(text))
        }
        #expect(WordDiff.tokens("a\tb c") == ["a\tb", "c"])
    }

    @Test func longRewritesAreNotVocabulary() {
        #expect(WordDiff.substitutions(from: "a b c d e", to: "v w x y e").isEmpty)
        let learned = WordDiff.substitutions(from: "a b c d e", to: "v w x y e", maxWords: 4)
        #expect(learned.count == 1)
        #expect(learned.first?.heard == "a b c d")
        #expect(learned.first?.meant == "v w x y")
    }
}

@Suite struct TextCleanerDetailTests {
    @Test func wordHelpers() {
        #expect(TextCleaner.wordKey("Hello,") == "hello")
        #expect(TextCleaner.wordKey("—") == "")
        #expect(TextCleaner.stripped("word?!") == "word")
        #expect(TextCleaner.category(of: "Friday,") == 0)
        #expect(TextCleaner.category(of: "March") == 1)
        #expect(TextCleaner.category(of: "3pm") == 2)
        #expect(TextCleaner.category(of: "table") == nil)
    }

    @Test func aCollapsedRunKeepsItsLastPunctuation() {
        #expect(TextCleaner.collapseRepeats("I I think the the the. plan") == "I think the. plan")
        // Two in a row is only a slip for small words.
        #expect(TextCleaner.collapseRepeats("very very good") == "very very good")
        #expect(TextCleaner.collapseRepeats("") == "")
    }

    @Test func tidyingDoesNotCapitaliseAfterAnAbbreviation() {
        #expect(TextCleaner.tidy("hello ,  world . it is 3 p.m. on friday") == "Hello, world. It is 3 p.m. on friday")
        #expect(TextCleaner.tidy(", so anyway") == "So anyway")
        #expect(TextCleaner.tidy("") == "")
    }

    @Test func emptyAndBlankInputComeBackEmpty() {
        #expect(TextCleaner().clean("") == "")
        #expect(TextCleaner().clean("   ") == "")
        #expect(TextCleaner().clean("um") == "")
    }

    @Test func spokenPunctuationCoversEveryMark() {
        var profile = WritingProfile()
        profile.spokenPunctuation = true
        let cleaner = TextCleaner(profile: profile)
        #expect(cleaner.clean("wait semicolon then go full stop") == "Wait; then go.")
        #expect(cleaner.clean("two things colon milk comma eggs") == "Two things: milk, eggs")
    }
}

@Suite struct TechnicalSpeechDetailTests {
    @Test func flags() {
        #expect(TechnicalSpeech.apply("git commit dash dash amend") == "git commit --amend")
        #expect(TechnicalSpeech.apply("run it with dash dash dry run now") == "run it with --dry-run now")
        #expect(TechnicalSpeech.apply("dash dash verbose output") == "--verbose output")
    }

    @Test func namesInAStatedCase() {
        #expect(TechnicalSpeech.apply("a class named user profile view in pascal case") == "a class named UserProfileView")
        #expect(TechnicalSpeech.apply("a file called my cool file in kebab case") == "a file called my-cool-file")
    }

    @Test func appsAreSortedByKind() {
        #expect(AppKind(bundleID: "com.apple.mail") == .mail)
        #expect(AppKind(bundleID: "COM.APPLE.MAIL") == .mail)
        #expect(AppKind(bundleID: "com.tinyspeck.slackmacgap") == .chat)
        #expect(AppKind(bundleID: "com.apple.Notes") == .other)
        #expect(AppKind(bundleID: nil) == .other)
    }

    @Test func textLaidOutByHandOnlyGetsItsMentions() {
        #expect(MessageShape.apply("First line\nat here second", for: .chat) == "First line\n@here second")
        #expect(MessageShape.apply("Hi Sam,\nat here second", for: .mail) == "Hi Sam,\nat here second")
        #expect(MessageShape.apply("Look at everyone go", for: .chat) == "Look at everyone go")
    }
}

@Suite struct SpokenListDetailTests {
    @Test func numbersThatSkipAreNotAList() {
        #expect(SpokenLists.format("One, apples. Three, pears.") == "One, apples. Three, pears.")
    }

    @Test func oneBulletIsNotAList() {
        #expect(SpokenLists.format("Bullet point milk.") == "Bullet point milk.")
    }

    @Test func stepsSaidAsWords() {
        #expect(SpokenLists.format("Step one, open the app. Step two, press record.") == "Step 1. Open the app.\nStep 2. Press record.")
    }

    @Test func emptyText() {
        #expect(SpokenLists.format("") == "")
    }
}

@Suite struct SpeechTextDetailTests {
    private func said(_ s: String) -> String { SpeechText.spoken(s) }

    @Test func onlyWellFormedNumeralsCount() {
        #expect(SpeechText.roman("IV") == 4)
        #expect(SpeechText.roman("VIII") == 8)
        #expect(SpeechText.roman("CCCXCIX") == 399)
        #expect(SpeechText.roman("IIII") == nil)
        #expect(SpeechText.roman("IC") == nil)
        #expect(SpeechText.roman("CD") == nil)
        #expect(SpeechText.roman("") == nil)
        #expect(said("See Chapter IIII.") == "See Chapter IIII.")
    }

    @Test func ordinalWords() {
        #expect(SpeechText.ordinal(1) == "first")
        #expect(SpeechText.ordinal(12) == "twelfth")
        #expect(SpeechText.ordinal(20) == "twentieth")
    }

    @Test func moneyInMillions() {
        #expect(said("Costs $2M or $1.5k") == "Costs 2 million dollars or 1.5 thousand dollars")
    }

    @Test func ticketNumbersAndWith() {
        #expect(said("Ticket #42 w/ notes") == "Ticket number 42 with notes")
    }

    @Test func emptyAndBlank() {
        #expect(said("") == "")
        #expect(said("   ") == "")
    }

    @Test func aDateThatIsNotADateIsLeft() {
        #expect(said("Code 2026-13-45 stays.") == "Code 2026-13-45 stays.")
    }
}

@Suite struct ReadingDetailTests {
    @Test func aPauseForASentenceThatIsNotThere() {
        #expect(ReadingText.pause(after: 5, in: []) == 0.25)
        #expect(ReadingText.pause(after: -1, in: ReadingText.sentences("One. Two.")) == 0.25)
    }

    @Test func aColonGetsAShorterPause() {
        let sentences = ReadingText.sentences("Here is the list:\nmilk and eggs.")
        #expect(ReadingText.pause(after: 0, in: sentences) == 0.22)
    }

    @Test func wordsAreSplitOnAnyWhiteSpace() {
        #expect(ReadingText.wordRanges("a  bc\td") == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 2), NSRange(location: 6, length: 1)])
        #expect(ReadingText.wordRanges("").isEmpty)
        #expect(ReadingText.wordRanges("   ").isEmpty)
    }

    @Test func noTimingsNoWord() {
        #expect(ReadingText.wordIndex(at: 1, in: []) == nil)
        #expect(ReadingText.wordTimings(sentence: "Some words", spokenWeights: [], duration: 0).isEmpty)
    }

    @Test func listeningTime() {
        let text = Array(repeating: "word", count: 165).joined(separator: " ")
        #expect(ReadingText.estimatedDuration(text) == 60)
        #expect(ReadingText.estimatedDuration("") == 0)
    }

    @Test func sentenceEnds() {
        #expect(ReadingText.sentences("").isEmpty)
        #expect(ReadingText.sentences(" \n\n ").isEmpty)
        #expect(ReadingText.sentences("Really? Yes! Fine.").map(\.text) == ["Really?", "Yes!", "Fine."])
        // A full stop before a lower-case word, or inside a number, does not end the sentence.
        #expect(ReadingText.sentences("It costs 3.50 today. see you").map(\.text) == ["It costs 3.50 today. see you"])
    }

    @Test func aLineWithoutAStopIsGivenOne() {
        #expect(ReadingText.spoken("Chapter one") == "Chapter one.")
        #expect(ReadingText.spoken("Is it late?") == "Is it late?")
        #expect(ReadingText.spoken("") == "")
    }

    @Test func aHyphenBeforeACapitalIsNotAWrappedWord() {
        #expect(ReadingText.clean("well-\nKnown fact") == "well- Known fact")
        #expect(ReadingText.clean("") == "")
        #expect(ReadingText.clean("one\r\ntwo\r\rthree") == "one two\n\nthree")
    }
}

@Suite struct HTMLDetailTests {
    @Test func numberedAndUnknownEntities() {
        #expect(HTMLText.decodeEntities("&#65;&#x42;&unknown; &amp;") == "AB&unknown; &")
        #expect(HTMLText.decodeEntities("no entities") == "no entities")
        // A number that is not a character is left as written.
        #expect(HTMLText.decodeEntities("&#xD800;") == "&#xD800;")
    }

    @Test func scriptsAndCommentsAreNotText() {
        #expect(HTMLText.text(from: "<p>One</p><script>var a = 1;</script><!-- hidden --><p>Two &amp; three</p>") == "One\n\nTwo & three")
        #expect(HTMLText.text(from: "") == "")
        #expect(HTMLText.text(from: "line one<br/>line two") == "line one line two")
    }

    @Test func aPageWithoutATitleOrBody() {
        let article = HTMLText.article(from: "<p>Just a paragraph.</p>")
        #expect(article.title == "")
        #expect(article.text == "Just a paragraph.")
    }

    @Test func aPatternThatDoesNotMatch() {
        #expect(HTMLText.firstMatch("<h1>(.*?)</h1>", in: "<p>none</p>") == nil)
        // A pattern that is not valid finds nothing, the second time as well as the first.
        #expect(HTMLText.firstMatch("(", in: "(") == nil)
        #expect(HTMLText.firstMatch("(", in: "(") == nil)
        #expect(HTMLText.firstMatch("<B>(.*?)</B>", in: "<b>one\ntwo</b>") == "one\ntwo")
        #expect(HTMLText.epubPackagePath(container: "<container/>") == nil)
        let spine = HTMLText.epubSpine(package: "<package/>")
        #expect(spine.title == "")
        #expect(spine.chapters.isEmpty)
    }
}

@Suite struct MeetingDetailTests {
    private func line(_ who: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(itemID: 0, speaker: who, start: start, end: end, text: text)
    }

    @Test func storedNames() {
        #expect(MeetingCalendar.names(from: " Sam , ,Priya") == ["Sam", "Priya"])
        #expect(MeetingCalendar.names(from: nil).isEmpty)
    }

    @Test func aMeetingWithPeopleBeatsABlockOfTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let solo = CalendarMeeting(id: "solo", title: "Focus", start: now, end: now.addingTimeInterval(1800))
        let call = CalendarMeeting(id: "call", title: "Sync", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900), attendees: ["Sam"])
        #expect(MeetingCalendar.current([solo, call], at: now)?.id == "call")
        #expect(MeetingCalendar.current([solo], at: now.addingTimeInterval(-601)) == nil)
        #expect(MeetingCalendar.current([], at: now) == nil)
        #expect(!solo.isWithOthers)
        #expect(CalendarMeeting(id: "x", title: "", start: now, end: now, hasCallLink: true).isWithOthers)
    }

    @Test func aVoiceHeardOnlyBrieflyIsLeftOut() {
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 10), SpeakerTurn(speaker: "B", start: 10, end: 11), SpeakerTurn(speaker: "A", start: 11, end: 20)]
        #expect(MeetingText.significant(turns).map(\.speaker) == ["A", "A"])
        #expect(MeetingText.significant([]).isEmpty)
    }

    @Test func oneSpeakerMeansNoRelabelling() {
        let segments = [line("Them", 0, 5, "hello")]
        #expect(MeetingText.assignSpeakers(segments, turns: [SpeakerTurn(speaker: "A", start: 0, end: 5)], replacing: "Them") == segments)
        #expect(MeetingText.assignSpeakers(segments, turns: [], replacing: "Them") == segments)
    }

    @Test func linesFarApartStaySeparate() {
        let segments = [line("Me", 0, 1, "a"), line("Me", 5, 6, "b"), line("Me", 6, 7, "")]
        #expect(MeetingText.merged(segments).map(\.text) == ["a", "b"])
        #expect(MeetingText.merged(segments, gap: 5).map(\.text) == ["a b"])
        #expect(MeetingText.merged([]).isEmpty)
    }

    @Test func sectionsKeepOnlyTheirBullets() {
        let sections = MeetingText.sections(of: "intro\n- stray\n## A\n- one\n* two\ntext\n# B")
        #expect(sections.map { $0.title } == ["A", "B"])
        #expect(sections.map { $0.bullets } == [["one", "two"], []])
        #expect(MeetingText.sections(of: "").isEmpty)
    }

    @Test func repeatsAreDroppedWhateverTheirCapitals() {
        #expect(MeetingText.unique(["Ship it.", "ship it", "—", "—", "Next"]) == ["Ship it.", "—", "—", "Next"])
    }

    @Test func wordsAreCounted() {
        #expect(MeetingText.wordCount([line("Me", 0, 1, "a b"), line("Me", 1, 2, "c  d e")]) == 5)
        #expect(MeetingText.wordCount([]) == 0)
    }

    @Test func tasksThatLeanOnWhatCameBefore() {
        #expect(MeetingText.needsContext("fix it by Friday"))
        #expect(!MeetingText.needsContext("send the report"))
    }

    @Test func actionItemLines() {
        let mine = Commitment(owner: "I", isRequest: false, sentence: "", task: "send the report.", context: "")
        #expect(mine.bullet() == "I: send the report")
        #expect(mine.bullet(task: " Do it, ") == "I: Do it")
        let asked = Commitment(owner: "Sam", isRequest: true, sentence: "", task: "book a room", context: "")
        #expect(asked.bullet() == "Sam asked: book a room")
    }

    @Test func requestsAndGroupTasks() {
        let found = MeetingText.commitments(in: [
            line("Sam", 0, 1, "Could you send the slides over?"),
            line("Me", 1, 2, "We should update the roadmap. Let's start with the budget. I can see the problem."),
        ])
        // The request is a task. "We should update the roadmap" has no day on it and nobody's name: it is
        // talk about what ought to happen, like "let's start with the budget", and is left out.
        #expect(found.map(\.owner) == ["Sam"])
        #expect(found.map(\.isRequest) == [true])
        #expect(found.last?.task == "send the slides over")
    }

    @Test func whatTheNotesModelIsGiven() {
        #expect(MeetingText.notesMaterial(userNotes: "  ", points: ["a", "b"]) == "POINTS FROM THE TRANSCRIPT:\na\nb")
        #expect(MeetingText.notesMaterial(userNotes: "mine", points: ["a"], transcript: true) == "MY OWN NOTES (written by \"Me\"):\nmine\n\nTRANSCRIPT:\na")
    }

    @Test func clockTimes() {
        #expect(75.0.clock == "1:15")
        #expect(0.0.clock == "0:00")
        #expect(3725.0.clock == "1:02:05")
    }

    @Test func aShortTitleForNothingSaid() {
        #expect(MeetingText.openingTitle([]) == "")
    }

    @Test func whatIsLeftAtTheEndIsReturnedOnce() {
        var segmenter = PauseSegmenter()
        #expect(segmenter.append([Float](repeating: 0.5, count: 16_000)).isEmpty)
        #expect(segmenter.received == 1)
        let piece = segmenter.finish()
        #expect(piece?.samples.count == 16_000)
        #expect(piece?.start == 0)
        #expect(piece?.end == 1)
        #expect(segmenter.finish() == nil)
        #expect(segmenter.received == 1)
    }

    @Test func loudness() {
        #expect(PauseSegmenter.rms([]) == 0)
        #expect(abs(PauseSegmenter.rms([3, 4]) - 3.5355339) < 0.0001)
    }
}

@Suite struct RecordingContextDetailTests {
    @Test func nothingKnownIsStoredAsNothing() {
        #expect(RecordingContext().json == "")
        #expect(RecordingContext(json: "").isEmpty)
        #expect(RecordingContext(json: "not json").isEmpty)
    }

    @Test func whatIsKnownRoundTrips() {
        var context = RecordingContext(eventTitle: "Sync", attendees: ["Sam"], app: "Zoom", screens: [.init(at: 65, app: "Safari", text: "Roadmap")])
        context.template = "General"
        #expect(RecordingContext(json: context.json) == context)
    }

    @Test func aCallWithoutAnEventStillKnowsItsApp() {
        let context = RecordingContext(event: nil, app: "Zoom")
        #expect(context.app == "Zoom")
        #expect(!context.isEmpty)
        #expect(context.material() == "ABOUT THIS MEETING (from the calendar, not something that was said):\nHeld in: Zoom")
    }

    @Test func anEventFillsInItsDetails() {
        let now = Date()
        let event = CalendarMeeting(id: "1", title: "Sync", start: now, end: now, attendees: ["Sam"], details: "", location: "Room 2", links: ["https://example.com"])
        let context = RecordingContext(event: event, app: nil)
        #expect(context.eventTitle == "Sync")
        #expect(context.eventDetails == nil)
        #expect(context.location == "Room 2")
        #expect(context.links == ["https://example.com"])
    }

    @Test func aWebAddressIsNotAPlace() {
        let context = RecordingContext(eventTitle: "Sync", location: "https://zoom.us/j/1")
        #expect(context.material() == "ABOUT THIS MEETING (from the calendar, not something that was said):\nTitle: Sync")
    }

    @Test func screenTimesAreShownAsClockTimes() {
        let context = RecordingContext(screens: [.init(at: 65, app: "Safari", text: "Roadmap for the year")])
        #expect(context.passages().map { $0.title } == ["On screen at 1:05 in Safari"])
    }

    @Test func theSameScreenAgainIsNotNew() {
        let screen = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike"
        #expect(RecordingContext.isNewScreen(screen, after: nil))
        #expect(!RecordingContext.isNewScreen(screen, after: screen))
        #expect(!RecordingContext.isNewScreen("too few words here", after: nil))
    }

    @Test func soundIsReadBackAsItWasWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-journal-\(UUID().uuidString)")
        let journal = try RecordingJournal(directory: dir)
        journal.append([0.25, -0.5], to: .system)
        journal.append([], to: .system)
        journal.append([1], to: .system)
        journal.flush()
        #expect(journal.samples(.system) == [0.25, -0.5, 1])
        #expect(journal.samples(.mic).isEmpty)
        #expect(RecordingJournal.sampleCount(at: RecordingJournal.url(.system, in: dir)) == 3)
        #expect(RecordingJournal.sampleCount(at: dir.appendingPathComponent("missing.pcm")) == 0)
        journal.save(.init(startedAt: Date(timeIntervalSince1970: 100), title: "Sync"))
        journal.close()
        // Appending after closing is ignored rather than an error.
        journal.append([2], to: .system)
        let recovered = RecordingJournal.recover(from: dir)
        #expect(recovered?.systemSamples == 3)
        #expect(recovered?.micSamples == 0)
        #expect(recovered?.meta.title == "Sync")
        journal.discard()
        #expect(RecordingJournal.recover(from: dir) == nil)
    }
}

@Suite struct LibraryDetailTests {
    func library() throws -> Library { Library(store: try ChirpStore()) }

    @Test func titlesFromText() {
        #expect(Library.title(from: "") == "Untitled")
        #expect(Library.title(from: "...") == "Untitled")
        #expect(Library.title(from: "# Heading here\nmore") == "Heading here")
        #expect(Library.title(from: "one two three four five six seven eight nine") == "one two three four five six seven eight")
        let long = Library.title(from: String(repeating: "a", count: 80))
        #expect(long == String(repeating: "a", count: 60) + "…")
    }

    @Test func searchWordsAreQuoted() {
        #expect(Library.ftsPattern("hello wor") == "\"hello\" \"wor\"*")
        #expect(Library.ftsPattern("it's") == "\"it\" \"s\"*")
        #expect(Library.ftsPattern("!!!") == nil)
        #expect(Library.ftsPattern("") == nil)
    }

    @Test func aSearchForOnlyPunctuationFindsNothing() throws {
        let lib = try library()
        try lib.save(SavedItem(kind: .note, body: "Some \"quoted\" AND text"))
        #expect(try lib.search("\"").isEmpty)
        // Words that mean something to the search engine are only words here.
        #expect(try lib.search("AND").count == 1)
        #expect(try lib.search("quoted OR").isEmpty)
    }

    @Test func searchablePartsLeaveOutRepeatsAndBlanks() {
        let item = SavedItem(kind: .note, body: "B", rawText: "B", summary: "S")
        #expect(Library.searchableParts(item) == ["B", "S"])
        let segments = [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "hello")]
        #expect(Library.searchableText(SavedItem(kind: .meeting, rawText: "R"), segments: segments) == "R\n\nMe: hello")
        #expect(Library.searchableParts(SavedItem(kind: .note)).isEmpty)
    }

    @Test func deletingAFolderKeepsItsItems() throws {
        let lib = try library()
        let folder = try lib.addFolder("Work")
        let saved = try lib.save(SavedItem(kind: .note, body: "In a folder", folderID: folder.id))
        try lib.save(SavedItem(kind: .note, body: "Loose"))
        #expect(try lib.items(folderID: folder.id).map(\.id) == [saved.id])
        #expect(try lib.folders().map(\.name) == ["Work"])
        try lib.delete(folder)
        #expect(try lib.folders().isEmpty)
        #expect(try lib.item(saved.id!)?.folderID == nil)
        #expect(try lib.count(kind: .note) == 2)
        #expect(try lib.count(kind: .meeting) == 0)
    }

    @Test func aTitleGivenByHandIsKept() throws {
        let lib = try library()
        let saved = try lib.save(SavedItem(kind: .note, title: "Mine", body: "Other words"))
        #expect(saved.title == "Mine")
        #expect(try lib.item(999) == nil)
    }

    @Test func ownTemplatesComeAfterTheBuiltInOnes() throws {
        let lib = try library()
        let builtIn = try lib.templates().count
        let mine = try lib.save(NoteTemplate(name: "Mine", sections: "A\nB"))
        #expect(try lib.templates().last == mine)
        try lib.delete(mine)
        #expect(try lib.templates().count == builtIn)
    }

    @Test func changedTextIsSplitAgainForSearch() throws {
        let lib = try library()
        try lib.save(SavedItem(kind: .dictation, body: "Dictations are not searched by meaning"))
        try lib.save(SavedItem(kind: .note))
        var note = try lib.save(SavedItem(kind: .note, body: "First words"))
        #expect(try lib.itemsNeedingChunks().map(\.id) == [note.id])
        try lib.replaceChunks(itemID: note.id!, with: [Chunk(itemID: 0, offset: 0, text: "First words", embedding: SemanticSearch.data([1]))])
        #expect(try lib.itemsNeedingChunks().isEmpty)
        // Saving without a change of text keeps the passages.
        note.starred = true
        note = try lib.save(note)
        #expect(try lib.chunks().count == 1)
        note.body = "Other words"
        try lib.save(note)
        #expect(try lib.chunks().isEmpty)
        #expect(try lib.itemsNeedingChunks().map(\.id) == [note.id])
    }

    @Test func deletingAnItemRemovesItsTranscript() throws {
        let lib = try library()
        let meeting = try lib.save(SavedItem(kind: .meeting, title: "Sync"))
        try lib.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 1, text: "hello")])
        #expect(try lib.itemsNeedingChunks().map(\.id) == [meeting.id])
        try lib.delete(meeting)
        #expect(try lib.segments(itemID: meeting.id!).isEmpty)
    }
}

@Suite struct EngineDetailTests {
    func engine() throws -> PersonalLanguage { PersonalLanguage(store: try ChirpStore()) }

    @Test func settingsRoundTrip() throws {
        let e = try engine()
        #expect(try e.setting("missing", as: String.self) == nil)
        try e.setSetting("limit", 5)
        #expect(try e.setting("limit", as: Int.self) == 5)
        try e.setSetting("limit", 6)
        #expect(try e.setting("limit", as: Int.self) == 6)
        // Asked for as the wrong kind of value: nothing, not an error.
        #expect(try e.setting("limit", as: [String].self) == nil)
        #expect(try e.profile() == WritingProfile())
    }

    @Test func switchedOffSnippetsAndWordsAreOnlyListedWhenAsked() throws {
        let e = try engine()
        try e.save(Snippet(cue: "on", text: "1"))
        try e.save(Snippet(cue: "off", text: "2", enabled: false))
        try e.save(DictionaryEntry(term: "Hidden", enabled: false))
        #expect(try e.snippets().map(\.cue) == ["on"])
        #expect(try e.snippets(includeDisabled: true).map(\.cue) == ["off", "on"])
        #expect(try e.dictionary().isEmpty)
        #expect(try e.dictionary(includeDisabled: true).map(\.term) == ["Hidden"])
        // Adding the word again switches it back on.
        try e.addWord("  hidden ")
        #expect(try e.dictionary().map(\.term) == ["Hidden"])
    }

    @Test func correctionsThatTeachNothingAreNotLearned() throws {
        let e = try engine()
        #expect(try e.learnCorrection(heard: "kubernetes", meant: "Kubernetes", note: "") == nil)
        #expect(try e.learnCorrection(heard: "", meant: "Word", note: "") == nil)
        #expect(try e.learnCorrection(heard: "a", meant: "one two three four five", note: "") == nil)
        #expect(try e.dictionary().isEmpty)
    }

    @Test func anAppHasOneStyle() throws {
        let e = try engine()
        try e.save(AppStyle(bundleID: "com.apple.mail", appName: "Mail", formality: .formal))
        try e.save(AppStyle(bundleID: "com.apple.mail", appName: "Mail", formality: .casual, underlinesEnabled: false))
        #expect(try e.appStyles().count == 1)
        #expect(try e.appStyle(bundleID: "com.apple.mail")?.formality == .casual)
        #expect(try e.underlinesEnabled(for: WorkContext(bundleID: "com.apple.mail")) == false)
        #expect(try e.underlinesEnabled(for: WorkContext()) == true)
        #expect(try e.formality(for: WorkContext(bundleID: "com.unknown.app")) == .neutral)
    }

    @Test func appsLeftAloneByPrefix() {
        #expect(PersonalLanguage.staysOut(of: "com.jetbrains.intellij"))
        #expect(PersonalLanguage.staysOut(of: "com.apple.Terminal"))
        #expect(!PersonalLanguage.staysOut(of: "com.apple.Notes"))
    }

    @Test func aDismissalCanBeForOneWordOrAWholeRule() throws {
        let e = try engine()
        let rules = [DismissedRule(ruleKey: "Spell", text: "teh"), DismissedRule(ruleKey: "Commas")]
        #expect(e.isDismissed(ruleKey: "Spell", text: "teh", in: rules))
        #expect(!e.isDismissed(ruleKey: "Spell", text: "other", in: rules))
        #expect(e.isDismissed(ruleKey: "Commas", text: "anything", in: rules))
        #expect(!e.isDismissed(ruleKey: "Other", text: "teh", in: rules))
    }

    @Test func exportHoldsEverything() throws {
        let e = try engine()
        try e.addWord("Kubernetes")
        try e.save(Snippet(cue: "sig", text: "Alex", enabled: false))
        try e.save(AppStyle(bundleID: "a.b", appName: "App"))
        try e.dismiss(ruleKey: "R", text: nil)
        let export = try e.export()
        #expect(export.dictionary.count == 1)
        #expect(export.snippets.count == 1)
        #expect(export.appStyles.count == 1)
        #expect(export.dismissedRules.count == 1)
        #expect(export.profile == WritingProfile())
    }

    @Test func modelSizes() {
        #expect(LanguageModelSize.large.smaller == .medium)
        #expect(LanguageModelSize.medium.smaller == .small)
        #expect(LanguageModelSize.small.smaller == nil)
        #expect(LanguageModelSize.resolve(choice: "nonsense", memoryBytes: 8 << 30) == .small)
        #expect(Set(LanguageModelSize.allCases.map(\.modelID)).count == 3)
    }

    @Test func taskSectionsAndTitles() {
        #expect(Prompts.isTaskSection("Action items"))
        #expect(Prompts.isTaskSection("Next steps"))
        #expect(Prompts.isTaskSection("Follow-ups"))
        #expect(Prompts.isTaskSection("To do"))
        #expect(!Prompts.isTaskSection("Doing next"))
        #expect(!Prompts.isTaskSection("Decisions"))
        #expect(WritingTask.rephrase(.formal).title == "More formal")
        let prompts = Prompts(profile: WritingProfile())
        #expect(prompts.meetingSectionInstructions(section: "Decisions").contains("explicitly made together"))
        #expect(prompts.meetingSectionInstructions(section: "Summary").contains("Do not list tasks here"))
        #expect(prompts.meetingSectionInstructions(section: "Risks").contains("belong under the heading \"Risks\""))
        #expect(prompts.meetingNotesInstructions(sections: ["A", "B"], solo: true).contains("## A\n## B"))
    }
}

@Suite struct SearchDetailTests {
    @Test func vectorsOfDifferentLengthsDoNotCompare() {
        #expect(SemanticSearch.similarity([1, 2], [1]) == 0)
        #expect(SemanticSearch.similarity([1, 2], [3, 4]) == 11)
        #expect(SemanticSearch.similarity([], []) == 0)
    }

    @Test func shortTextIsOnePassage() {
        let passages = SemanticSearch.passages("short")
        #expect(passages.count == 1)
        #expect(passages.first?.offset == 0)
        #expect(passages.first?.text == "short")
        #expect(SemanticSearch.passages("").isEmpty)
    }

    @Test func nearestStopsAtTheLimit() {
        let chunks = (1...3).map { Chunk(id: Int64($0), itemID: 1, offset: 0, text: "", embedding: SemanticSearch.data([Float($0) / 3])) }
        #expect(SemanticSearch.nearest([1], in: chunks, limit: 1).map(\.chunk.id) == [3])
        #expect(SemanticSearch.nearest([1], in: []).isEmpty)
    }

    @Test func aLongSnippetIsCutShort() {
        let item = SavedItem(id: 1, kind: .note)
        let long = String(repeating: "a", count: 300)
        let results = SemanticSearch.fuse(keyword: [], semantic: [.init(chunk: Chunk(id: 1, itemID: 1, offset: 7, text: long), score: 0.9)], items: [1: item])
        #expect(results.first?.snippet == String(repeating: "a", count: 220) + "…")
        #expect(results.first?.offset == 7)
        // A passage of an item that is gone is left out.
        #expect(SemanticSearch.fuse(keyword: [], semantic: [.init(chunk: Chunk(id: 1, itemID: 2, offset: 0, text: "x"), score: 0.9)], items: [1: item]).isEmpty)
    }

    @Test func chunkingShortAndUnbrokenText() {
        #expect(TextChunker.chunks("", maxCharacters: 10).isEmpty)
        #expect(TextChunker.chunks("short", maxCharacters: 10) == ["short"])
        #expect(TextChunker.chunks(String(repeating: "a", count: 25), maxCharacters: 10) == ["aaaaaaaaaa", "aaaaaaaaaa", "aaaaa"])
        #expect(TextChunker.chunks("One two. Three four. Five six.", maxCharacters: 12) == ["One two.", "Three four.", "Five six."])
        #expect(TextChunker.chunks("first line\nsecond line\nthird", maxCharacters: 16) == ["first line", "second line", "third"])
    }
}
