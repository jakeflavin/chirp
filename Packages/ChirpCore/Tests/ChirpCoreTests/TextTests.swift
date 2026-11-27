import Testing

@testable import ChirpCore

@Suite struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test func removesFillers() {
        #expect(cleaner.clean("Um, I think, uh, we should go.") == "I think, we should go.")
        #expect(cleaner.clean("So um let's start") == "So let's start")
        #expect(cleaner.clean("Hmm. That works.") == "That works.")
    }

    @Test func keepsWordsThatContainFillerLetters() {
        #expect(cleaner.clean("The umbrella is under her arm.") == "The umbrella is under her arm.")
        #expect(cleaner.clean("Ah-ha moment") == "Ah-ha moment")
    }

    @Test func collapsesStutters() {
        #expect(cleaner.clean("Send me the the report.") == "Send me the report.")
        #expect(cleaner.clean("I I I think so.") == "I think so.")
        #expect(cleaner.clean("It was very very good.") == "It was very very good.")
        #expect(cleaner.clean("No no no, stop.") == "No, stop.")
    }

    @Test func doesNotCollapseAcrossPunctuation() {
        #expect(cleaner.clean("That is it. It works.") == "That is it. It works.")
    }

    @Test func scratchThatDropsThePreviousSentence() {
        #expect(cleaner.clean("Let's meet Monday. Scratch that. Let's meet Tuesday.") == "Let's meet Tuesday.")
    }

    @Test func backtrackReplacesSameKindOfWord() {
        #expect(
            cleaner.clean("Move the meeting to Thursday. No wait, Friday at 3 PM.")
                == "Move the meeting to Friday at 3 PM.")
        #expect(cleaner.clean("Send it to Sam, I mean to Alex.") == "Send it to Alex.")
        #expect(cleaner.clean("We need five, no wait, six chairs.") == "We need six chairs.")
    }

    @Test func backtrackLeavesTextAloneWhenUnclear() {
        let s = "I like the blue one, no wait, green is better."
        #expect(cleaner.clean(s) == s)
    }

    @Test func spokenLineBreaks() {
        #expect(cleaner.clean("Hi Sam, new paragraph thanks for the notes.") == "Hi Sam\n\nThanks for the notes.")
        #expect(cleaner.clean("first item new line second item") == "First item\nSecond item")
    }

    @Test func spokenPunctuationIsOptIn() {
        #expect(cleaner.clean("wait comma what") == "Wait comma what")
        var p = WritingProfile()
        p.spokenPunctuation = true
        #expect(TextCleaner(profile: p).clean("wait comma what question mark") == "Wait, what?")
    }

    @Test func respectsProfileSwitches() {
        var p = WritingProfile()
        p.removeFillers = false
        #expect(TextCleaner(profile: p).clean("Um, hello.") == "Um, hello.")
    }

    @Test func neverAddsWords() {
        let samples = [
            "So, um, I was thinking we should, uh, move the the meeting to Thursday. No wait, Friday at 3 PM.",
            "Uh, scratch that. Okay new line let's go.",
        ]
        for s in samples {
            let inWords = Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let outWords = cleaner.clean(s).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            for w in outWords { #expect(inWords.contains(w), "cleanup invented '\(w)'") }
        }
    }
}

@Suite struct DictionaryCorrectorTests {
    func corrector(_ entries: [DictionaryEntry]) -> DictionaryCorrector { DictionaryCorrector(entries: entries) }

    @Test func aliasMatch() {
        let c = corrector([DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties", "kuber nettys"])])
        #expect(c.correct("We deploy on cooper netties today.") == "We deploy on Kubernetes today.")
        #expect(c.correct("Is it Kuber Nettys?") == "Is it Kubernetes?")
    }

    @Test func fuzzyMatch() {
        let c = corrector([DictionaryEntry(term: "Anthropic"), DictionaryEntry(term: "Okafor")])
        #expect(c.correct("I work with Anthropik on this.") == "I work with Anthropic on this.")
        #expect(c.correct("Ask Alex Okafar, please.") == "Ask Alex Okafor, please.")
    }

    @Test func fixesCasingAndSpacing() {
        let c = corrector([DictionaryEntry(term: "OpenAI"), DictionaryEntry(term: "GitHub")])
        #expect(c.correct("open AI and github") == "OpenAI and GitHub")
    }

    @Test func leavesOrdinaryWordsAlone() {
        let c = corrector([DictionaryEntry(term: "Kubernetes"), DictionaryEntry(term: "Chirp")])
        let s = "The committee meets on Tuesday to chat about cheap options."
        #expect(c.correct(s) == s)
    }

    @Test func doesNotCrossPunctuation() {
        let c = corrector([DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"])])
        #expect(c.correct("Ask Cooper. Netties are fine.") == "Ask Cooper. Netties are fine.")
    }

    @Test func disabledEntriesAreIgnored() {
        let c = corrector([DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"], enabled: false)])
        #expect(c.correct("cooper netties") == "cooper netties")
    }

    @Test func reportsReplacements() {
        let c = corrector([DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"])])
        let r = c.correctWithLog("Use cooper netties.")
        #expect(r.replacements == [.init(heard: "cooper netties", term: "Kubernetes")])
    }

    @Test func soundexAndLevenshtein() {
        #expect(DictionaryCorrector.soundex("robert") == "R163")
        #expect(DictionaryCorrector.soundex("rupert") == "R163")
        #expect(DictionaryCorrector.levenshtein("kitten", "sitting") == 3)
    }
}

@Suite struct SnippetTests {
    @Test func expandsInline() {
        let e = SnippetExpander(snippets: [Snippet(cue: "my email", text: "alex@example.com")])
        #expect(e.expand("Send it to my email, please.") == "Send it to alex@example.com, please.")
    }

    @Test func wholeUtterance() {
        let e = SnippetExpander(snippets: [Snippet(cue: "sign off", text: "Best,\nAlex")])
        #expect(e.expand("Sign off.") == "Best,\nAlex")
    }

    @Test func longestCueWins() {
        let e = SnippetExpander(snippets: [
            Snippet(cue: "my address", text: "1 Main St"), Snippet(cue: "my work address", text: "2 Office Rd"),
        ])
        #expect(e.expand("Ship to my work address") == "Ship to 2 Office Rd")
    }

    @Test func pipelineOrder() {
        let p = DictationPipeline(
            profile: WritingProfile(),
            dictionary: [DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"])],
            snippets: [Snippet(cue: "my email", text: "alex@example.com")])
        #expect(
            p.process("um deploy to cooper netties and and send the logs to my email")
                == "Deploy to Kubernetes and send the logs to alex@example.com")
    }
}

/// What the speech model really returned for phrases a person might say, and what should land on the page.
/// The left side of each pair was produced by running a spoken recording of the phrase through Chirp.
@Suite struct FormattingTests {
    private func page(_ heard: String) -> String {
        DictationPipeline(profile: WritingProfile(), dictionary: [], snippets: []).process(heard)
    }

    @Test func numberedLists() {
        #expect(page("Let's put some items on here that I want to do next. One, test dictation. Two, text speech. Three, text meetings. Four, um test recordings.")
            == "Let's put some items on here that I want to do next.\n1. Test dictation.\n2. Text speech.\n3. Text meetings.\n4. Test recordings.")
        #expect(page("First, check the logs. Second, restart the server. Third, tell the team.")
            == "1. Check the logs.\n2. Restart the server.\n3. Tell the team.")
        #expect(page("Number 1 Buy Milk, Number 2 Call Mom, Number 3 Book Flights.") == "1. Buy Milk\n2. Call Mom\n3. Book Flights")
        #expect(page("Things to do today. 1 Finish the report, 2 email Sam, 3 go for a run.")
            == "Things to do today.\n1. Finish the report\n2. Email Sam\n3. Go for a run")
        #expect(page("Step 1. Open the app. Step 2. Click record. Step 3. Press Stop.")
            == "Step 1. Open the app.\nStep 2. Click record.\nStep 3. Press Stop.")
    }

    @Test func bullets() {
        #expect(page("Shopping list: Bullet point milk, bullet point eggs, bullet point bread.") == "Shopping list:\n- Milk\n- Eggs\n- Bread")
        #expect(page("Next steps: bullet review the design, bullet write the tests, bullet ship it.")
            == "Next steps:\n- Review the design\n- Write the tests\n- Ship it")
        #expect(page("Project update new line bullet point the build is done new line bullet point the tests pass.")
            == "Project update\n- The build is done\n- The tests pass")
    }

    @Test func quotesAndBrackets() {
        #expect(page("She said quote I will be there at 5 end quote and then she left.") == "She said “I will be there at 5” and then she left.")
        #expect(page("He told me open quote do not ship on Friday close quote and I agreed.") == "He told me “do not ship on Friday” and I agreed.")
        #expect(page("The word quote-unquote instant is doing a lot of work here.") == "The word “instant” is doing a lot of work here.")
        #expect(page("Add a note open parenthesis optional close parenthesis to the form.") == "Add a note (optional) to the form.")
    }

    @Test func addressesAndTimes() {
        #expect(page("Email me at alex.smith at gmail.com or visit example.com slash pricing.")
            == "Email me at alex.smith@gmail.com or visit example.com/pricing.")
        #expect(page("Send it to sam at outlook.com today.") == "Send it to sam@outlook.com today.")
        #expect(page("Let's meet at 3.30 p.m. on January 5, 2027.") == "Let's meet at 3:30 p.m. on January 5, 2027.")
    }

    @Test func spokenMarks() {
        #expect(page("Dear Sam Comma New Line Thanks for the update period new paragraph best regards.") == "Dear Sam,\nThanks for the update.\n\nBest regards.")
        #expect(page("Is that right question mark? I think so exclamation point.") == "Is that right? I think so!")
        #expect(page("Wait dot dot dot I am not sure about that.") == "Wait… I am not sure about that.")
    }

    @Test func technicalSymbols() {
        #expect(page("To install the package, run npm install dash dash save dev type script, then add a xconfig.json file to the root of the project.")
            == "To install the package, run npm install --save-dev type script, then add a xconfig.json file to the root of the project.")
        #expect(page("Set the environment variable database underscore URL to your Postgres connection string.")
            == "Set the environment variable DATABASE_URL to your Postgres connection string.")
        #expect(page("Use the endpoint slash API slash v2 slash users.") == "Use the endpoint /API/v2/users.")
        #expect(page("Can you look at the file app slash sources slash speak slash dictation controller dot swift and tell me why?")
            == "Can you look at the file app/sources/speak/dictation controller.swift and tell me why?")
        #expect(page("Run Docker compose up, then check localhost colon 3000.") == "Run Docker compose up, then check localhost:3000.")
        #expect(page("Use git rebase dash i head tilde 3 to squash the last 3 commits.") == "Use git rebase -i head~3 to squash the last 3 commits.")
        #expect(page("The variable is called max retry count in camel case.") == "The variable is called maxRetryCount.")
        #expect(page("Add a column named created at in snake case.") == "Add a column named created_at.")
        #expect(page("At channel the deploy is done, please let me know if you see any errors in sentry.")
            == "@channel the deploy is done, please let me know if you see any errors in sentry.")
        #expect(page("We can do that and slash or the other one.") == "We can do that and/or the other one.")
    }

    @Test func changingYourMind() {
        #expect(page("So I want you to um update the settings page, actually no wait, the onboarding page, so that it shows the the microphone permission first.")
            == "So I want you to update the onboarding page, so that it shows the microphone permission first.")
        #expect(page("Let's meet at 2, make that 3, on Friday.") == "Let's meet at 3, on Friday.")
    }

    @Test func emailsAreLaidOut() {
        let pipeline = DictationPipeline(profile: WritingProfile(), dictionary: [], snippets: [])
        let said = "Hi Sarah, thanks for sending the proposal over. Could we set up a call on Thursday at 2 p.m.? Best, Alex."
        let letter = "Hi Sarah,\n\nThanks for sending the proposal over. Could we set up a call on Thursday at 2 p.m.?\n\nBest,\nAlex"
        // A greeting and a sign-off make a letter in any app.
        #expect(pipeline.process(said) == letter)
        #expect(pipeline.process(said, app: AppKind(bundleID: "com.apple.mail")) == letter)
        // A greeting alone is only broken out in a mail app.
        let update = "Hey team, quick update on the Q3 launch."
        #expect(pipeline.process(update) == update)
        #expect(pipeline.process(update, app: .mail) == "Hey team,\n\nQuick update on the Q3 launch.")
        #expect(pipeline.process("At here, lunch is in the kitchen.", app: .chat) == "@here, lunch is in the kitchen.")
    }

    /// Ordinary sentences that contain the same words must come through untouched.
    @Test func ordinarySentencesAreLeftAlone() {
        for text in [
            "It took a long period of time and I put a comma in the wrong place.",
            "I need two things, one is milk and two is eggs.",
            "The meeting is at 2, not at 3. One more thing: bring the laptop.",
            "The budget is 50% higher, about $12,500.",
            "The total came to $42.50, which is 10% off.",
            "My number is 415-555-0199.",
            "One of them is late. Two of them left.",
            "I have 1 dog, 2 cats and 3 birds.",
            "Take a look at example.com when you can.",
            "We got a quote from the builder and it was high.",
            "I like bullet points in my notes.",
            "The bullet train was fast.",
            "Version 2.10 is out.",
            "I want to underscore the point that this matters.",
            "They slash prices every January.",
            "Add a dash of salt and a dash of pepper.",
            "He lives at 3000 Main Street.",
            "Hi there, how are you doing today?",
            "The best, I think, is the second one.",
            "Yeah that works for me, see you at Standup.",
            "Refactor the dictation controller so that the piece worker is its own class, and add unit tests for the case where the recording is cancelled mid-piece, don't change the public API.",
            "Write a Python script that reads a CSV file, groups the rows by customer ID, and outputs the total revenue per customer as JSON.",
            "We use React 19 with Next.js and Tailwind CSS on the front end, and a Node.js backend with PostgreSQL.",
            "Please summarize this thread in three bullet points and draft a reply that says we'll ship by Friday.",
            "The build is failing with error TS2345. Argument of type string is not assignable to parameter of type number. Fix it.",
        ] {
            #expect(page(text) == text)
        }
    }
}

@Suite struct LongFormTests {
    private func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }

    @Test func shortAudioIsNotCut() {
        let plan = LongForm(targetSeconds: 25)
        #expect(plan.cuts([], samples: s(30)).isEmpty)
    }

    @Test func cutsFallInThePauseNearestTheTarget() {
        let plan = LongForm(targetSeconds: 25)
        // Speech for 60 s with pauses at 8, 24 and 41 seconds.
        let speech = [s(0)..<s(8), s(8.6)..<s(24), s(24.8)..<s(41), s(41.5)..<s(60)]
        let cuts = plan.cuts(LongForm.candidates(speech: speech, samples: s(60)), samples: s(60))
        // The 24 s pause is nearest the target; what is left is still too long, so it is cut again at 41 s.
        #expect(cuts == [(s(24) + s(24.8)) / 2, (s(41) + s(41.5)) / 2])
    }

    @Test func noPauseMeansAHardCut() {
        let plan = LongForm(targetSeconds: 25)
        let cuts = plan.cuts([], samples: s(100))
        #expect(cuts.first == plan.maxSamples)
        #expect(s(100) - (cuts.last ?? 0) <= plan.maxSamples)
    }

    @Test func piecesJoinWithASpace() {
        #expect(LongForm.join(["Hello there. ", "", " And more."]) == "Hello there. And more.")
    }
}

@Suite struct LiveCutTests {
    private func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }
    let cut = LiveCut()

    @Test func waitsWhileThePhraseGoesOn() {
        // Talking from 0.2 s and still talking at 3 s.
        #expect(cut.next(speech: [s(0.2)..<s(3)], samples: s(3)) == .wait)
    }

    @Test func aPauseAfterAPhraseCutsHalfAPauseIn() {
        // A phrase from 0.2 s to 2.5 s, then quiet for 0.6 s.
        #expect(cut.next(speech: [s(0.2)..<s(2.5)], samples: s(3.1)) == .transcribe(upTo: s(2.5) + s(0.5) / 2))
    }

    @Test func aShortPauseIsNotTheEndOfAPhrase() {
        #expect(cut.next(speech: [s(0.2)..<s(2.5)], samples: s(2.8)) == .wait)
    }

    @Test func tooLittleAudioWaits() {
        // A word, then a pause, before there is enough to go on.
        #expect(cut.next(speech: [s(0.1)..<s(0.5), s(1.2)..<s(1.6)], samples: s(1.7)) == .wait)
    }

    @Test func theLatestLongPauseWins() {
        // Two phrases, each followed by a long pause, and a third still going: one piece up to the second pause.
        let speech = [s(0)..<s(2), s(2.8)..<s(4.5), s(5.4)..<s(6.5)]
        #expect(cut.next(speech: speech, samples: s(6.5)) == .transcribe(upTo: (s(4.5) + s(5.4)) / 2))
    }

    @Test func quietIsPassedOver() {
        #expect(cut.next(speech: [], samples: s(1.5)) == .wait)
        #expect(cut.next(speech: [], samples: s(3)) == .skip(upTo: s(2.5)))
    }

    @Test func tooLongWithoutAPauseIsCutAtTheLongestOne() {
        // Talking for 13 s with only short breaths at 4 s and 9 s, the one at 9 s the longer.
        let speech = [s(0)..<s(4), s(4.2)..<s(9), s(9.3)..<s(13)]
        #expect(cut.next(speech: speech, samples: s(13)) == .transcribe(upTo: (s(9) + s(9.3)) / 2))
        // With no break at all, it is cut at the limit.
        #expect(cut.next(speech: [s(0)..<s(13)], samples: s(13)) == .transcribe(upTo: s(12)))
    }
}
