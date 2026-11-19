import Foundation
import Testing

@testable import ChirpCore

@Suite struct ProofreadingTests {
    let text = "This is an test of teh checker."
    var an: WritingIssue {
        WritingIssue(start: 8, end: 10, rule: "AnA", kind: "Grammar", message: "Use a", priority: 31, suggestions: [Fix(kind: .replace, text: "a")])
    }
    var teh: WritingIssue {
        WritingIssue(start: 19, end: 22, rule: "SpellCheck", kind: "Spelling", message: "Did you mean the?", priority: 63, suggestions: [Fix(kind: .replace, text: "the")])
    }

    @Test func decodesCheckerOutput() {
        let json = #"[{"start":8,"end":10,"rule":"AnA","kind":"Grammar","message":"m","priority":31,"suggestions":[{"kind":"replace","text":"a"}]}]"#
        #expect(Proofreading.decode(json) == [WritingIssue(start: 8, end: 10, rule: "AnA", kind: "Grammar", message: "m", priority: 31, suggestions: [Fix(kind: .replace, text: "a")])])
        #expect(Proofreading.decode("not json").isEmpty)
    }

    @Test func categories() {
        #expect(an.category == .grammar)
        #expect(teh.category == .spelling)
        #expect(IssueCategory(checkerKind: "Readability") == .style)
        #expect(IssueCategory(checkerKind: "SomethingNew") == .grammar)
    }

    @Test func flaggedTextAndLabels() {
        #expect(teh.flagged(in: text) == "teh")
        #expect(teh.label(for: teh.suggestions[0], in: text) == "the")
        #expect(teh.label(for: Fix(kind: .remove, text: ""), in: text) == "Remove “teh”")
    }

    @Test func appliesFixes() {
        #expect(Proofreading.apply(teh.suggestions[0], to: teh, in: text).text == "This is an test of the checker.")
        let removed = Proofreading.apply(Fix(kind: .remove, text: ""), to: teh, in: text)
        #expect(removed.text == "This is an test of checker.")
        #expect(removed.delta == -4)
        #expect(Proofreading.apply(Fix(kind: .insert, text: ","), to: an, in: text).text == "This is an, test of teh checker.")
    }

    @Test func fixAllLeavesStyleAlone() {
        let style = WritingIssue(start: 0, end: 4, rule: "Wordy", kind: "Style", message: "", suggestions: [Fix(kind: .replace, text: "It")])
        #expect(Proofreading.fixAll([an, teh, style], in: text) == "This is a test of the checker.")
    }

    @Test func hidesDismissedAndOverlapping() {
        let overlapping = WritingIssue(start: 19, end: 30, rule: "Other", kind: "Style", message: "", priority: 100)
        let out = Proofreading.visible([teh, overlapping, an], in: text, dismissed: [])
        #expect(out.map(\.rule) == ["AnA", "SpellCheck"])
        let dismissedWord = Proofreading.visible([teh, an], in: text, dismissed: [DismissedRule(ruleKey: "SpellCheck", text: "teh")])
        #expect(dismissedWord.map(\.rule) == ["AnA"])
        let dismissedRule = Proofreading.visible([teh, an], in: text, dismissed: [DismissedRule(ruleKey: "AnA", text: nil)])
        #expect(dismissedRule.map(\.rule) == ["SpellCheck"])
        let outOfRange = WritingIssue(start: 40, end: 50, rule: "X", kind: "Grammar", message: "")
        #expect(Proofreading.visible([outOfRange], in: text, dismissed: []).isEmpty)
    }

    @Test func utf16Offsets() {
        let emoji = "Hi 👋 teh end"
        let issue = WritingIssue(start: 6, end: 9, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "the")])
        #expect(issue.flagged(in: emoji) == "teh")
        #expect(Proofreading.apply(issue.suggestions[0], to: issue, in: emoji).text == "Hi 👋 the end")
    }

    @Test func modelCorrectionsBecomeSeparateSuggestions() {
        let original = "There is many reasons to wait and we need less meetings."
        let corrected = "There are many reasons to wait and we need fewer meetings."
        let issues = Proofreading.modelIssues(original: original, corrected: corrected)
        #expect(issues.map { $0.flagged(in: original) } == ["is", "less"])
        #expect(issues.map { $0.suggestions.first?.text } == ["are", "fewer"])
        #expect(Proofreading.fixAll(issues, in: original) == corrected)
    }

    @Test func modelInsertionsAndRemovalsApplyCleanly() {
        let original = "I am looking forward meet you very very soon."
        let corrected = "I am looking forward to meeting you very soon."
        let issues = Proofreading.modelIssues(original: original, corrected: corrected)
        #expect(Proofreading.fixAll(issues, in: original) == corrected)
    }

    @Test func aRewriteIsNotTreatedAsCorrections() {
        let original = "We was late because the bus it broke."
        let corrected = "Our arrival was delayed owing to a mechanical failure of the bus."
        #expect(Proofreading.modelIssues(original: original, corrected: corrected).isEmpty)
        #expect(Proofreading.modelIssues(original: original, corrected: original).isEmpty)
    }

    @Test func wrongWordsCountAsGrammar() {
        #expect(IssueCategory(checkerKind: "WordChoice") == .grammar)
        #expect(IssueCategory(checkerKind: "Redundancy") == .style)
    }

    @Test func commaOnlyChangesFromTheModelAreIgnored() {
        let original = "Let's keep the date as is, and lets revisit it later."
        let corrected = "Let's keep the date as is and let's revisit it later."
        let issues = Proofreading.modelIssues(original: original, corrected: corrected)
        #expect(issues.map { $0.flagged(in: original) } == ["lets"])
    }

    @Test func fixesTheSentenceTheCursorJustFinished() {
        let text = "This one is fine. I recieved teh report. And this is next"
        let ns = text as NSString
        let issues = [
            WritingIssue(start: ns.range(of: "recieved").location, end: NSMaxRange(ns.range(of: "recieved")), rule: "s", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "received")]),
            WritingIssue(start: ns.range(of: "teh").location, end: NSMaxRange(ns.range(of: "teh")), rule: "s", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "the")]),
        ]
        // Cursor right after "report. "
        let caret = NSMaxRange(ns.range(of: "report. "))
        let fix = Proofreading.sentenceFix(in: text, caret: caret, issues: issues)
        #expect(fix?.replacement == "I received the report.")
        #expect(fix?.count == 2)
        #expect(fix.map { ns.replacingCharacters(in: $0.range, with: $0.replacement) } == "This one is fine. I received the report. And this is next")
        // In a sentence with nothing wrong there is nothing to offer.
        #expect(Proofreading.sentenceFix(in: text, caret: 5, issues: issues) == nil)
        #expect(Proofreading.sentenceFix(in: text, caret: ns.length, issues: issues) == nil)
        // Mid-sentence counts too.
        #expect(Proofreading.sentenceFix(in: text, caret: ns.range(of: "teh").location, issues: issues)?.count == 2)
    }
}

@Suite struct CarriedIssuesTests {
    private func issue(_ text: String, _ word: String) -> WritingIssue {
        let r = (text as NSString).range(of: word)
        return WritingIssue(start: r.location, end: r.location + r.length, rule: word, kind: "Spelling", message: "")
    }

    @Test func typingAtTheEndKeepsEarlierUnderlinesInPlace() {
        let old = "I recieve teh report"
        let new = "I recieve teh report today"
        let carried = Proofreading.carry([issue(old, "recieve"), issue(old, "teh")], from: old, to: new)
        #expect(carried.map { $0.flagged(in: new) } == ["recieve", "teh"])
    }

    @Test func typingBeforeAnIssueMovesIt() {
        let old = "I recieve teh report"
        let new = "Yes, I recieve teh report"
        let carried = Proofreading.carry([issue(old, "recieve"), issue(old, "teh")], from: old, to: new)
        #expect(carried.map { $0.flagged(in: new) } == ["recieve", "teh"])
    }

    @Test func anIssueTheEditTouchedIsDropped() {
        let old = "I recieve teh report"
        let fixed = "I receive teh report"
        let carried = Proofreading.carry([issue(old, "recieve"), issue(old, "teh")], from: old, to: fixed)
        #expect(carried.map { $0.flagged(in: fixed) } == ["teh"])
        // A letter added to the end of a flagged word changes that word.
        let longer = "I recieve tehh report"
        #expect(Proofreading.carry([issue(old, "teh")], from: old, to: longer).isEmpty)
    }

    @Test func deletingBeforeAnIssueMovesItBack() {
        let old = "Well, I recieve it"
        let new = "I recieve it"
        #expect(Proofreading.carry([issue(old, "recieve")], from: old, to: new).map { $0.flagged(in: new) } == ["recieve"])
        #expect(Proofreading.carry([issue(old, "recieve")], from: old, to: old).count == 1)
    }

    @Test func checkerMessagesReadAsPlainWords() {
        #expect(Proofreading.plain("Did you mean to spell `recieve` this way?") == "Did you mean to spell “recieve” this way?")
        #expect(Proofreading.plain("Use `have` rather than `of` here.") == "Use “have” rather than “of” here.")
        #expect(Proofreading.plain("No marks.") == "No marks.")
    }
}

@Suite struct SameWordTwoRulesTests {
    @Test func aMisspellingIsOfferedAsOneWordBeforeTwo() {
        let text = "I will adress it"
        let split = WritingIssue(start: 7, end: 13, rule: "SplitWords", kind: "WordChoice", message: "should possibly be written as `a dress`", priority: 31,
            suggestions: [Fix(kind: .replace, text: "a dress")])
        let spelling = WritingIssue(start: 7, end: 13, rule: "SpellCheck", kind: "Spelling", message: "Did you mean to spell `adress` this way?", priority: 63,
            suggestions: [Fix(kind: .replace, text: "address"), Fix(kind: .replace, text: "adders")])
        for order in [[split, spelling], [spelling, split]] {
            let out = Proofreading.visible(order, in: text, dismissed: [])
            #expect(out.count == 1)
            #expect(out[0].rule == "SpellCheck")
            #expect(out[0].suggestions.map(\.text) == ["address", "adders", "a dress"])
        }
    }

    @Test func differentRangesStillKeepTheMoreImportantOne() {
        let text = "could of been"
        let a = WritingIssue(start: 0, end: 8, rule: "A", kind: "Grammar", message: "", priority: 10, suggestions: [Fix(kind: .replace, text: "could have")])
        let b = WritingIssue(start: 6, end: 8, rule: "B", kind: "Spelling", message: "", priority: 60)
        #expect(Proofreading.visible([a, b], in: text, dismissed: []).map(\.rule) == ["A"])
    }
}

@Suite struct SameWordReasonTests {
    @Test func theReasonGoesWithTheFirstFix() {
        let text = "I will adress it"
        // Both rules call it a spelling problem; the split rule is the more important one.
        let split = WritingIssue(start: 7, end: 13, rule: "SplitWords", kind: "Spelling", message: "split", priority: 31,
            suggestions: [Fix(kind: .replace, text: "a dress")])
        let spelling = WritingIssue(start: 7, end: 13, rule: "SpellCheck", kind: "Spelling", message: "spelling", priority: 63,
            suggestions: [Fix(kind: .replace, text: "address")])
        let out = Proofreading.visible([split, spelling], in: text, dismissed: [])
        #expect(out[0].message == "spelling")
        #expect(out[0].suggestions.map(\.text) == ["address", "a dress"])
    }
}

@Suite struct SuggestionJudgementTests {
    @Test func wordsPeopleRunTogetherAreSplit() {
        let text = "I get alot of mail"
        let split = WritingIssue(start: 6, end: 10, rule: "SplitWords", kind: "Spelling", message: "split", priority: 31,
            suggestions: [Fix(kind: .replace, text: "a lot")])
        let spelling = WritingIssue(start: 6, end: 10, rule: "SpellCheck", kind: "Spelling", message: "spelling", priority: 63,
            suggestions: [Fix(kind: .replace, text: "allot"), Fix(kind: .replace, text: "alto")])
        let out = Proofreading.visible([spelling, split], in: text, dismissed: [])
        #expect(out[0].suggestions.map(\.text) == ["a lot", "allot", "alto"])
        #expect(out[0].message == "split")
    }

    @Test func aDoubledLittleWordIsAMistakeNotStyle() {
        let text = "Read the the notes, they are very very long"
        let the = WritingIssue(start: 5, end: 12, rule: "RepeatedWords", kind: "Repetition", message: "", suggestions: [Fix(kind: .replace, text: "the")])
        let very = WritingIssue(start: 29, end: 38, rule: "RepeatedWords", kind: "Repetition", message: "", suggestions: [Fix(kind: .replace, text: "very")])
        let out = Proofreading.visible([the, very], in: text, dismissed: [])
        #expect(out.map(\.category) == [.grammar, .style])
        #expect(Proofreading.fixAll(out, in: text) == "Read the notes, they are very very long")
    }
}

@Suite struct PositionAfterFixAllTests {
    @Test func aCursorKeepsItsPlaceInTheWords() {
        let text = "I recieve teh report and stop here"
        let ns = text as NSString
        func issue(_ word: String, _ fix: String) -> WritingIssue {
            let r = ns.range(of: word)
            return WritingIssue(start: r.location, end: NSMaxRange(r), rule: word, kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: fix)])
        }
        let issues = [issue("recieve", "receive"), issue("teh", "the")]
        let fixed = Proofreading.fixAll(issues, in: text)
        #expect(fixed == "I receive the report and stop here")
        // Before any fix: unchanged. After both: same place in the words.
        #expect(Proofreading.position(0, afterFixing: issues, in: text) == 0)
        let stop = ns.range(of: "stop").location
        let moved = Proofreading.position(stop, afterFixing: issues, in: text)
        #expect((fixed as NSString).substring(from: moved).hasPrefix("stop"))
        // Inside a fixed word: the end of the fix.
        let inside = ns.range(of: "teh").location + 1
        #expect((fixed as NSString).substring(to: Proofreading.position(inside, afterFixing: issues, in: text)).hasSuffix("the"))
    }
}

@Suite struct LayoutWhitespaceTests {
    @Test func theIndentOfAListIsNotASpacingMistake() {
        let text = "\t•\tRecieve the numbers and  send them"
        let tab = WritingIssue(start: 0, end: 1, rule: "Spaces", kind: "Formatting", message: "", suggestions: [Fix(kind: .replace, text: " ")])
        let afterBullet = WritingIssue(start: 2, end: 3, rule: "Spaces", kind: "Formatting", message: "", suggestions: [Fix(kind: .replace, text: " ")])
        let double = (text as NSString).range(of: "  ")
        let twoSpaces = WritingIssue(start: double.location, end: NSMaxRange(double), rule: "Spaces", kind: "Formatting", message: "", suggestions: [Fix(kind: .replace, text: " ")])
        let out = Proofreading.visible([tab, afterBullet, twoSpaces], in: text, dismissed: [])
        #expect(out.count == 1)
        #expect(out[0].flagged(in: text) == "  ")
        #expect(out[0].label(for: out[0].suggestions[0], in: text) == "One space")
    }
}

@Suite struct MissingLetterTests {
    @Test func aLetterLeftOutIsPutBack() {
        let text = "It is writen here"
        let issue = WritingIssue(start: 6, end: 12, rule: "SpellCheck", kind: "Spelling", message: "",
            suggestions: [Fix(kind: .replace, text: "write"), Fix(kind: .replace, text: "written"), Fix(kind: .replace, text: "writes")])
        let out = Proofreading.visible([issue], in: text, dismissed: [])
        #expect(out[0].suggestions.map(\.text) == ["written", "write", "writes"])
    }

    @Test func twoLettersTheWrongWayRoundArePutRight() {
        let text = "this adn that. Adn more. I taht it"
        func issue(_ start: Int, _ end: Int, _ fixes: [String]) -> WritingIssue {
            WritingIssue(start: start, end: end, rule: "SpellCheck", kind: "Spelling", message: "",
                suggestions: fixes.map { Fix(kind: .replace, text: $0) })
        }
        let out = Proofreading.visible([issue(5, 8, ["ad"]), issue(15, 18, ["Ad", "Add"]), issue(27, 31, ["tat", "that"])], in: text, dismissed: [])
        #expect(out[0].suggestions.map(\.text) == ["and", "ad"])
        #expect(out[1].suggestions.map(\.text) == ["And", "Ad", "Add"])
        #expect(out[2].suggestions.map(\.text) == ["that", "tat"])
        #expect(Proofreading.fixAll(out, in: text) == "this and that. And more. I that it")
    }

    @Test func otherwiseTheCheckersOrderStands() {
        let text = "See you tommorow"
        let issue = WritingIssue(start: 8, end: 16, rule: "SpellCheck", kind: "Spelling", message: "",
            suggestions: [Fix(kind: .replace, text: "tomorrow"), Fix(kind: .replace, text: "tomorrows")])
        #expect(Proofreading.visible([issue], in: text, dismissed: [])[0].suggestions.map(\.text) == ["tomorrow", "tomorrows"])
    }
}

@Suite struct FixAllLeavesNamesTests {
    @Test func aNameIsNotReplacedByAGuess() {
        let text = "This is a test of Chirp in WordCraft. I will recieve it from Priya."
        let name = WritingIssue(start: 27, end: 36, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Woodcraft")])
        let slip = WritingIssue(start: 45, end: 52, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "receive")])
        let person = WritingIssue(start: 61, end: 66, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Pica")])
        #expect(Proofreading.fixAll([name, slip, person], in: text) == "This is a test of Chirp in WordCraft. I will receive it from Priya.")
    }

    @Test func aMisspellingAtTheStartOfAListItemIsStillFixed() {
        let text = "Things to do\n•\tRecieve the numbers\n2\tAdress the budget"
        let one = WritingIssue(start: 15, end: 22, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Receive")])
        let two = WritingIssue(start: 37, end: 43, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Address")])
        #expect(Proofreading.fixAll([one, two], in: text) == "Things to do\n•\tReceive the numbers\n2\tAddress the budget")
    }

    @Test func aMisspellingAtTheStartOfASentenceIsStillFixed() {
        let text = "Done. Recieve the report."
        let slip = WritingIssue(start: 6, end: 13, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Receive")])
        #expect(Proofreading.fixAll([slip], in: text) == "Done. Receive the report.")
    }
}

@Suite struct SecretsTests {
    // Every value here is made up: a service's prefix followed by a counting pattern.
    @Test func credentialsAreRecognised() {
        for word in [
            "sk-EXAMPLE0000111122223333", "ghp_EXAMPLE00001111222233334444", "AKIAEXAMPLE0000111122", "xoxb-0000-1111-EXAMPLEexample",
            "0123456789abcdef0123456789abcdef", "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0",
        ] {
            #expect(Secrets.isSecret(word), "\(word)")
        }
    }

    @Test func ordinaryWritingIsNot() {
        for word in [
            "internationalization", "counterrevolutionaries", "https://example.com/a/very/long/path", "someone@example-company.com",
            "com.apple.TextEdit.settings", "supercalifragilisticexpialidocious", "well-known-and-much-loved-phrase",
        ] {
            #expect(!Secrets.isSecret(word), "\(word)")
        }
        #expect(!Secrets.contains("The quarterly planning notes are attached. Please read them before Friday, 2026-11-20."))
    }

    @Test func keysInANoteAreFound() {
        let text = "Service one\nkey: Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0\nService two\nkey: sk-EXAMPLE0000111122223333"
        #expect(Secrets.ranges(in: text).count == 2)
    }
}

@Suite struct QuietAppsTests {
    @Test func terminalsEditorsAndPasswordManagersAreLeftAlone() {
        for id in ["com.apple.Terminal", "com.microsoft.VSCode", "com.jetbrains.intellij", "com.1password.1password", "com.apple.Passwords"] {
            #expect(PersonalLanguage.staysOut(of: id), "\(id)")
        }
        for id in ["com.apple.TextEdit", "md.obsidian", "com.apple.mail", "ai.storyteller.wordcraft"] {
            #expect(!PersonalLanguage.staysOut(of: id), "\(id)")
        }
    }
}

@Suite struct SecretsAreNotFlaggedTests {
    @Test func aKeyIsNeverOfferedAsAMisspelling() {
        let text = "key: Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0 and a mistaek"
        let key = WritingIssue(start: 5, end: 35, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [])
        let slip = WritingIssue(start: 42, end: 49, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "mistake")])
        let out = Proofreading.visible([key, slip], in: text, dismissed: [])
        #expect(out.map { $0.flagged(in: text) } == ["mistaek"])
    }
}

@Suite struct SmallestEditTests {
    private func edit(_ old: String, _ new: String, web: Bool = false) -> (String, String) {
        let e = Proofreading.smallestEdit(from: old, to: new, neverBareCursor: web)
        return ((old as NSString).substring(with: e.range), e.replacement)
    }

    @Test func aReplacementTouchesOnlyWhatDiffers() {
        #expect(edit("I recieve it", "I receive it") == ("ie", "ei"))
        #expect(edit("teh cat", "the cat") == ("eh", "he"))
    }

    /// "untill" to "until" and "adn" to "ad" were left unfixed by Fix all where fixes are pasted: the
    /// change was "select one letter, paste nothing", and an empty paste does nothing.
    @Test func takingLettersOutNeverPastesNothing() {
        #expect(edit("wait untill noon", "wait until noon") == ("ll", "l"))
        #expect(edit("this adn that", "this ad that") == ("dn", "d"))
        #expect(edit("a  b", "a b") == ("  ", " "))
        // At the very start there is no letter before, so the one after goes along.
        #expect(edit("xthe end", "the end") == ("xt", "t"))
        // Everything goes: there is nothing to take along.
        #expect(edit("x", "") == ("x", ""))
    }

    @Test func applyingTheEditGivesTheNewText() {
        for (old, new) in [("wait untill noon", "wait until noon"), ("a  b", "a b"), ("xthe end", "the end"), ("I recieve", "I receive"), ("go 🙂🙂 now", "go 🙂 now"), ("ab", "abc")] {
            for web in [false, true] {
                let e = Proofreading.smallestEdit(from: old, to: new, neverBareCursor: web)
                #expect((old as NSString).replacingCharacters(in: e.range, with: e.replacement) == new, "\(old)")
                #expect(old.isEmpty || !e.replacement.isEmpty || new.isEmpty)
            }
        }
    }

    @Test func aWebEditorNeverGetsABareCursor() {
        #expect(edit("writen", "written", web: true) == ("t", "tt"))
        #expect(edit("writen", "written") == ("", "t"))
    }

    @Test func anEmojiIsNeverCutInHalf() {
        let e = Proofreading.smallestEdit(from: "go 🙂🙂 now", to: "go 🙂 now")
        #expect(e.range.length == 4 && e.replacement == "🙂")
    }
}

@Suite struct WordsWithDigitsTests {
    @Test func aWordWithADigitIsNotAMisspelling() {
        let text = "Ship C85x1 and teh rest."
        let code = WritingIssue(start: 5, end: 10, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "Cox")])
        let typo = WritingIssue(start: 15, end: 18, rule: "SpellCheck", kind: "Spelling", message: "", suggestions: [Fix(kind: .replace, text: "the")])
        let shown = Proofreading.visible([code, typo], in: text, dismissed: [])
        #expect(shown.map { $0.flagged(in: text) } == ["teh"])
    }

    @Test func otherRulesStillSeeIt() {
        let text = "We need  2x more."
        let spaces = WritingIssue(start: 7, end: 9, rule: "Spaces", kind: "Formatting", message: "", suggestions: [Fix(kind: .replace, text: " ")])
        #expect(Proofreading.visible([spaces], in: text, dismissed: []).count == 1)
    }
}
