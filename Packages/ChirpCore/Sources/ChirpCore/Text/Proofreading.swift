import Foundation

/// The kind of problem a writing check found. Drives the underline colour.
public enum IssueCategory: String, Codable, Sendable, CaseIterable {
    /// Misspellings and typos.
    case spelling
    /// Grammar, punctuation, capitalization, wrong word.
    case grammar
    /// Wordiness, repetition, readability: optional improvements.
    case style
    /// A snippet's cue that was typed: the saved text is offered in its place.
    case snippet

    /// Maps the checker's own kind names onto Chirp's three categories.
    public init(checkerKind: String) {
        switch checkerKind {
        case "Spelling", "Typo": self = .spelling
        case "Snippet": self = .snippet
        // A wrong word ("should of", "effect" for "affect") is a mistake, not a matter of taste.
        case "Style", "Readability", "Enhancement", "Redundancy", "Repetition", "Regionalism":
            self = .style
        default: self = .grammar
        }
    }
}

/// One way to put a problem right, as the checker offers it.
public struct Fix: Codable, Sendable, Equatable, Hashable {
    /// Swap the flagged text for `text`, add `text` after it, or take the flagged text out.
    public enum Kind: String, Codable, Sendable { case replace, insert, remove }
    public var kind: Kind
    /// The words to put in. Empty for a removal.
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One problem found in a text, with its position in UTF-16 units (what AppKit and Accessibility use).
public struct WritingIssue: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var start: Int
    public var end: Int
    /// The checker's name for the rule, e.g. "SpellCheck". Dismissals are kept by this name.
    public var rule: String
    /// The checker's own kind name, e.g. "Spelling" or "Repetition". See `category`.
    public var kind: String
    /// The checker's explanation, with words marked by backticks. See `Proofreading.plain`.
    public var message: String
    /// How much the problem matters when two overlap: the lower number is kept.
    public var priority: Int
    /// The fixes on offer, best first. May be empty.
    public var suggestions: [Fix]

    public var id: String { "\(start)-\(end)-\(rule)" }
    public var range: NSRange { NSRange(location: start, length: end - start) }
    public var category: IssueCategory { IssueCategory(checkerKind: kind) }

    public init(start: Int, end: Int, rule: String, kind: String, message: String, priority: Int = 127, suggestions: [Fix] = []) {
        self.start = start
        self.end = end
        self.rule = rule
        self.kind = kind
        self.message = message
        self.priority = priority
        self.suggestions = suggestions
    }

    /// The flagged text itself, or nothing when the issue does not fit inside `text`.
    public func flagged(in text: String) -> String {
        let ns = text as NSString
        guard start >= 0, end <= ns.length, start <= end else { return "" }
        return ns.substring(with: range)
    }

    /// What a fix looks like to the user, e.g. the replacement word, or "Remove".
    public func label(for fix: Fix, in text: String) -> String {
        switch fix.kind {
        case .replace:
            if fix.text.isEmpty { return "Remove" }
            // A fix that is only a space has nothing to show as a word.
            if fix.text.allSatisfy(\.isWhitespace) { return fix.text.count == 1 ? "One space" : "Fix the spacing" }
            return fix.text
        case .insert: return flagged(in: text) + fix.text
        case .remove: return "Remove “\(flagged(in: text))”"
        }
    }
}

/// What Chirp does with the checker's findings before showing them: which to show, how to apply a fix,
/// and how to keep underlines and the cursor in the right place while the text changes.
public enum Proofreading {
    /// Moves issues found in `old` onto `new` after an edit, so underlines stay under their words while
    /// the user types instead of vanishing until the next check. Issues before the edit stay where they
    /// are, issues after it shift by how much the text grew or shrank, and any the edit touched are
    /// dropped: the next check decides about those. (Harper's own browser framework does the same.)
    public static func carry(_ issues: [WritingIssue], from old: String, to new: String) -> [WritingIssue] {
        guard old != new else { return issues }
        let a = old as NSString
        let b = new as NSString
        var prefix = 0
        while prefix < min(a.length, b.length), a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(a.length, b.length) - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        let editEnd = a.length - suffix
        let delta = b.length - a.length
        return issues.compactMap { issue in
            // Touching counts: a letter typed at the end of a flagged word changes the word.
            if issue.end < prefix { return issue }
            if issue.start > editEnd {
                var moved = issue
                moved.start += delta
                moved.end += delta
                return moved
            }
            return nil
        }
    }

    /// A checker message in plain words: the checker marks words with backticks, which read as code.
    public static func plain(_ message: String) -> String {
        var out = ""
        var open = false
        for ch in message {
            if ch == "`" {
                out += open ? "”" : "“"
                open.toggle()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Decodes the checker's JSON output.
    public static func decode(_ json: String) -> [WritingIssue] {
        (try? JSONDecoder().decode([WritingIssue].self, from: Data(json.utf8))) ?? []
    }

    /// Drops issues the user dismissed, sorts by position, and removes overlaps (keeping the more important).
    public static func visible(_ issues: [WritingIssue], in text: String, dismissed: [DismissedRule]) -> [WritingIssue] {
        let length = (text as NSString).length
        // Keys, tokens and passwords are never offered as misspellings (or shown in a card or a list).
        let secrets = Secrets.ranges(in: text)
        let kept = issues.filter { issue in
            guard issue.start >= 0, issue.end <= length, issue.start < issue.end else { return false }
            if secrets.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) { return false }
            // A word with a digit in it ("C85x1", "v2beta", "Q3report") is a code, a part number or a name,
            // not a misspelling: the nearest dictionary word ("Cox") is never what was meant.
            if issue.category == .spelling, issue.flagged(in: text).unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) { return false }
            // Rules that offer no fix and were wrong whenever they were seen ("The news is good today").
            if unhelpfulRules.contains(issue.rule) { return false }
            // A note with nothing to press is not shown at all: it needs a fix, or a rewrite of its sentence.
            if issue.suggestions.isEmpty, issue.category != .spelling, sentenceRewrite(for: issue) == nil { return false }
            let flagged = issue.flagged(in: text)
            // Tabs and line breaks are layout (the indent of a list, a table cell), not spacing mistakes.
            if flagged.allSatisfy(\.isWhitespace), flagged.contains(where: { $0 == "\t" || $0.isNewline }) { return false }
            return !dismissed.contains { $0.ruleKey == issue.rule && ($0.text == nil || $0.text == flagged) }
        }
        .map { ranked(refined($0, in: text), in: text) }
        .sorted { ($0.start, $0.priority) < ($1.start, $1.priority) }
        var out: [WritingIssue] = []
        for issue in kept {
            if let last = out.last, issue.start < last.end {
                if issue.start == last.start, issue.end == last.end {
                    // Two rules about the same word (a misspelling that could also be two words run together):
                    // one problem, with both rules' fixes.
                    out[out.count - 1] = merged(last, issue)
                } else if issue.priority < last.priority {
                    out[out.count - 1] = issue
                }
                continue
            }
            out.append(issue)
        }
        return out
    }

    /// Two words that are commonly typed as one.
    static let commonSplits: Set<String> = [
        "a lot", "as well", "in fact", "each other", "in case", "at least", "a bit", "of course", "no one", "every time",
        "thank you", "a while", "all right", "even though", "in front", "as if", "a part", "up to", "on to", "any more",
    ]

    /// Words nobody doubles on purpose. "the the" is a slip to be fixed with the rest; "very very" may be meant.
    static let neverDoubled: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "and", "or", "is", "are", "was", "were", "it", "we", "i", "you",
        "he", "she", "they", "this", "that", "with", "as", "by", "be", "has", "have", "had", "will", "would", "can", "not", "from",
    ]

    /// For a misspelling, fixes that keep every letter the user typed, in order, come first: the commonest
    /// slip is a letter left out ("writen" is "written", not "write"). Otherwise the checker's order stands.
    ///
    /// Before that comes the same word with two neighbouring letters the other way round ("adn" is "and"):
    /// the checker offered only "ad" for it, and Fix all then wrote "ad". Only for the commonest words
    /// ("and", "the", "that"); for any other word the checker's order stands ("alot" is not "alto").
    static func ranked(_ issue: WritingIssue, in text: String) -> WritingIssue {
        guard issue.category == .spelling, !issue.suggestions.isEmpty else { return issue }
        let flagged = issue.flagged(in: text)
        let typed = Array(flagged.lowercased())
        var swapped = Set<String>()
        for i in typed.indices.dropLast() where typed[i] != typed[i + 1] {
            var word = typed
            word.swapAt(i, i + 1)
            swapped.insert(String(word))
        }
        if let word = swapped.intersection(neverDoubled).sorted().first {
            var out = issue
            let capital = flagged.first?.isUppercase == true
            let fix = Fix(kind: .replace, text: capital ? word.prefix(1).uppercased() + word.dropFirst() : word)
            out.suggestions.removeAll { $0 == fix }
            out.suggestions.insert(fix, at: 0)
            return out
        }
        guard issue.suggestions.count > 1 else { return issue }
        func keepsAll(_ fix: Fix) -> Bool {
            guard fix.kind == .replace, !fix.text.contains(" "), fix.text.count == typed.count + 1 else { return false }
            var i = 0
            for ch in fix.text.lowercased() where i < typed.count && ch == typed[i] { i += 1 }
            return i == typed.count
        }
        var out = issue
        out.suggestions = issue.suggestions.filter(keepsAll) + issue.suggestions.filter { !keepsAll($0) }
        return out
    }

    /// A doubled word that can only be a slip is a mistake, not a matter of style.
    static func refined(_ issue: WritingIssue, in text: String) -> WritingIssue {
        guard issue.kind == "Repetition" else { return issue }
        let words = issue.flagged(in: text).lowercased().split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == words[1], neverDoubled.contains(String(words[0])) else { return issue }
        var mistake = issue
        mistake.kind = "Grammar"
        return mistake
    }

    /// One problem from two rules that flag exactly the same text. A misspelling keeps its own rule, so the
    /// word can be added to the dictionary; otherwise the more important rule wins. The fixes of both are
    /// offered, a single word before a split into two ("address" before "a dress"): a misspelt word is far
    /// more often one word than two.
    static func merged(_ a: WritingIssue, _ b: WritingIssue) -> WritingIssue {
        let aSpelling = a.category == .spelling, bSpelling = b.category == .spelling
        var winner = aSpelling != bSpelling ? (aSpelling ? a : b) : (b.priority < a.priority ? b : a)
        let other = winner.id == a.id && winner.rule == a.rule ? b : a
        var seen = Set<Fix>()
        let all = (winner.suggestions + other.suggestions).filter { seen.insert($0).inserted }
        func oneWord(_ fix: Fix) -> Bool { fix.kind != .replace || !fix.text.contains(" ") }
        // Except for the handful of pairs people really do run together ("alot", "aswell"): there the split is right.
        let runTogether = all.filter { !oneWord($0) && commonSplits.contains($0.text.lowercased()) }
        let rest = all.filter { !runTogether.contains($0) }
        let ordered = runTogether + rest.filter(oneWord) + rest.filter { !oneWord($0) }
        // The reason shown goes with the fix shown first.
        if let first = ordered.first, !winner.suggestions.contains(first), aSpelling == bSpelling { winner = other }
        winner.suggestions = ordered
        return winner
    }

    /// The smallest change that turns `old` into `new`: the range of `old` to replace (UTF-16) and what
    /// to put there, found by skipping what the two share at the start and at the end.
    ///
    /// The replacement is never empty. A fix that only takes letters out ("untill" to "until", "adn" to
    /// "ad") would otherwise be "select one letter and put nothing there"; where the fix goes in by
    /// paste that pastes an empty clipboard, which does nothing, and the mistake stays (seen with Fix all
    /// in an editor that inserts by paste). So such a change takes the letter before it along (or the one after, at
    /// the very start) and replaces two letters with one.
    ///
    /// With `neverBareCursor`, a change that only adds letters takes the letter before it along too: web
    /// editors do not reliably move a bare cursor, but do select a letter.
    public static func smallestEdit(from old: String, to new: String, neverBareCursor: Bool = false) -> (range: NSRange, replacement: String) {
        let a = old as NSString, b = new as NSString
        var prefix = 0
        while prefix < min(a.length, b.length), a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(a.length, b.length) - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        // The change never starts or ends in the middle of an emoji (two units that only mean something together).
        if prefix > 0, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
        let addsOnly = a.length - prefix - suffix == 0
        let removesOnly = b.length - prefix - suffix == 0
        if (removesOnly || (addsOnly && neverBareCursor)) && a.length > 0 {
            if prefix > 0 {
                // A whole letter: an emoji is two units.
                prefix = a.rangeOfComposedCharacterSequence(at: prefix - 1).location
            } else if suffix > 0 {
                suffix = a.length - NSMaxRange(a.rangeOfComposedCharacterSequence(at: a.length - suffix))
            }
        }
        return (
            NSRange(location: prefix, length: a.length - prefix - suffix),
            b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        )
    }

    /// The text after applying one fix, and how much later positions shift. An issue that does not fit
    /// inside the text (it was found in an older version of it) changes nothing.
    public static func apply(_ fix: Fix, to issue: WritingIssue, in text: String) -> (text: String, delta: Int) {
        let ns = text as NSString
        guard issue.start >= 0, issue.start <= issue.end, issue.end <= ns.length else { return (text, 0) }
        switch fix.kind {
        case .replace:
            return (ns.replacingCharacters(in: issue.range, with: fix.text), (fix.text as NSString).length - issue.range.length)
        case .insert:
            return (ns.replacingCharacters(in: NSRange(location: issue.end, length: 0), with: fix.text), (fix.text as NSString).length)
        case .remove:
            // Removing a word also removes one neighbouring space, so no double space is left behind.
            var range = issue.range
            if range.location > 0, ns.character(at: range.location - 1) == 32 {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            } else if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 32 {
                range.length += 1
            }
            return (ns.replacingCharacters(in: range, with: ""), -range.length)
        }
    }

    /// Where a position in the text belongs after `fixAll` has run: moved along by however much the
    /// fixes before it changed the length. A position inside a fixed word goes to the end of the fix.
    /// Used to put the cursor and the scroll position back after "Fix all". Issues `fixAll` leaves alone
    /// (likely names) move nothing here either.
    public static func position(_ index: Int, afterFixing issues: [WritingIssue], in text: String, categories: Set<IssueCategory> = [.spelling, .grammar, .snippet]) -> Int {
        var shift = 0
        for issue in issues.sorted(by: { $0.start < $1.start }) where categories.contains(issue.category) {
            guard let fix = issue.suggestions.first, issue.start < index, !likelyName(issue, in: text) else { continue }
            let delta = apply(fix, to: issue, in: text).delta
            if issue.end <= index {
                shift += delta
            } else {
                // Inside the fixed word.
                return issue.end + shift + delta
            }
        }
        return index + shift
    }

    /// Applies the first suggestion of every spelling and grammar issue (style is left to the writer,
    /// and so are words that are probably names).
    public static func fixAll(_ issues: [WritingIssue], in text: String, categories: Set<IssueCategory> = [.spelling, .grammar, .snippet]) -> String {
        var result = text
        // Work backwards so earlier positions stay valid.
        for issue in issues.sorted(by: { $0.start > $1.start }) where categories.contains(issue.category) {
            guard let fix = issue.suggestions.first, !likelyName(issue, in: text) else { continue }
            result = apply(fix, to: issue, in: result).text
        }
        return result
    }

    /// Rules that are never shown: they offer no fix and were wrong whenever they were seen.
    static let unhelpfulRules: Set<String> = ["MissingPreposition"]

    /// An unknown word that is probably a name ("WordCraft", "Priya"): capitalised in the middle of a
    /// sentence, or with a capital inside it. Fixing everything at once leaves these alone, because the
    /// nearest dictionary word ("Woodcraft") is a guess the user has not looked at.
    public static func likelyName(_ issue: WritingIssue, in text: String) -> Bool {
        guard issue.category == .spelling else { return false }
        let word = issue.flagged(in: text)
        guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        if word.unicodeScalars.dropFirst().contains(where: { CharacterSet.uppercaseLetters.contains($0) }) { return true }
        // Capitalised: a name unless it only has its capital because it starts a sentence.
        let before = (text as NSString).substring(to: max(0, min(issue.start, (text as NSString).length)))
        // The first word of a line (after a bullet or a number, say) starts a sentence too.
        let line = before.components(separatedBy: .newlines).last ?? ""
        if !line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return false }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.unicodeScalars.last else { return false }
        return !CharacterSet(charactersIn: ".!?\n:").contains(last)
    }

    // MARK: Fixing one sentence

    /// Every spelling and grammar fix for one sentence, as a single replacement.
    public struct SentenceFix: Equatable, Sendable {
        /// The sentence, in UTF-16 units of the whole text.
        public var range: NSRange
        /// The sentence with its fixes applied.
        public var replacement: String
        /// How many fixes it applies.
        public var count: Int
    }

    /// The sentence the position is in, or has just finished ("…sentence. |" still belongs to it), in
    /// UTF-16 units. Nil in an empty text or an empty line.
    public static func sentenceRange(in text: String, at position: Int) -> NSRange? {
        let ns = text as NSString
        let n = ns.length
        guard n > 0, position >= 0 else { return nil }
        func isEnd(_ i: Int) -> Bool { [46, 33, 63].contains(ns.character(at: i)) }  // . ! ?
        func isBreak(_ i: Int) -> Bool { ns.character(at: i) == 10 || ns.character(at: i) == 13 }
        func isBlank(_ i: Int) -> Bool { ns.character(at: i) == 32 || ns.character(at: i) == 9 }
        // Just after "…sentence. " the cursor still belongs to that sentence.
        var p = min(position, n)
        while p > 0, isBlank(p - 1) { p -= 1 }
        while p > 0, isEnd(p - 1) { p -= 1 }
        var start = p
        while start > 0, !isEnd(start - 1), !isBreak(start - 1) { start -= 1 }
        while start < p, isBlank(start) { start += 1 }
        var end = p
        while end < n, !isEnd(end), !isBreak(end) { end += 1 }
        while end < n, isEnd(end) { end += 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The fix for the sentence the cursor is in, or has just finished, if that sentence has anything to fix.
    public static func sentenceFix(in text: String, caret: Int, issues: [WritingIssue]) -> SentenceFix? {
        guard let range = sentenceRange(in: text, at: caret) else { return nil }
        return sentenceFix(in: text, sentence: range, issues: issues)
    }

    /// The fix for one sentence: every spelling and grammar fix in it, and every snippet cue typed in it.
    static func sentenceFix(in text: String, sentence range: NSRange, issues: [WritingIssue]) -> SentenceFix? {
        let ns = text as NSString
        let (start, end) = (range.location, NSMaxRange(range))
        let inside = issues.filter { $0.start >= start && $0.end <= end && $0.category != .style && !$0.suggestions.isEmpty }
        guard !inside.isEmpty else { return nil }
        let sentence = ns.substring(with: range)
        let shifted = inside.map { issue -> WritingIssue in
            var i = issue
            i.start -= start
            i.end -= start
            return i
        }
        let fixed = fixAll(shifted, in: sentence)
        guard fixed != sentence else { return nil }
        // Count what was changed: a likely name is left alone by `fixAll`.
        let applied = shifted.filter { !likelyName($0, in: sentence) }.count
        return SentenceFix(range: range, replacement: fixed, count: applied)
    }

    /// Every sentence of the text that has something to fix, in order: where the small bird goes.
    public static func sentenceFixes(in text: String, issues: [WritingIssue]) -> [SentenceFix] {
        var out: [SentenceFix] = []
        for issue in issues.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, issue.start < NSMaxRange(last.range) { continue }
            // A place inside the problem: its first character may be the first of its sentence, and the
            // position just before that still belongs to the sentence before.
            guard let range = sentenceRange(in: text, at: min(issue.start + 1, issue.end)), let fix = sentenceFix(in: text, sentence: range, issues: issues) else { continue }
            out.append(fix)
        }
        return out
    }

    /// The rewrite offered for a note that has no fix of its own: the name on its one button, and what
    /// the language model is asked to do with the note's sentence. Nil when the note has fixes, or nothing
    /// could be done about it.
    public static func sentenceRewrite(for issue: WritingIssue) -> (title: String, task: WritingTask)? {
        guard issue.suggestions.isEmpty else { return nil }
        if issue.rule == "LongSentences" { return ("Shorten this sentence", .shorten) }
        switch issue.category {
        case .style: return ("Rephrase this sentence", .rephrase(.neutral))
        case .grammar: return ("Fix this sentence", .fix)
        case .spelling, .snippet: return nil
        }
    }

    /// What the card says once a note's sentence has been rewritten: "Shortened from 57 words to 31."
    public static func rewriteSummary(task: WritingTask, from old: String, to new: String) -> String {
        switch task {
        case .shorten: return "Shortened from \(TextStats.words(old)) words to \(TextStats.words(new))."
        case .fix: return "Fixed with the language model."
        default: return "Rephrased, saying the same thing."
        }
    }

    // MARK: Corrections from the language model

    /// The rule name carried by issues that came from the language model rather than the instant checker.
    public static let modelRule = "LanguageModel"

    /// Turns a proofread version of a text into individual suggestions on the original, one per changed
    /// run of words, so each can be accepted or dismissed on its own. Returns nothing when the model
    /// changed so much that it rewrote rather than corrected.
    public static func modelIssues(original: String, corrected: String) -> [WritingIssue] {
        let ns = original as NSString
        // Words of the original with their positions, split exactly as the comparison below splits them.
        // (Splitting by a different rule here put suggestions on the wrong word after a tab, and ran off
        // the end after a line separator.)
        let ranges = WordDiff.wordRanges(original)
        let fixed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ranges.isEmpty, !fixed.isEmpty else { return [] }
        func word(_ i: Int) -> String { ns.substring(with: ranges[i]) }

        var issues: [WritingIssue] = []
        var changed = 0
        var position = 0  // index of the next original word
        var removedFrom: Int?
        var added: [String] = []

        func flush() {
            defer {
                removedFrom = nil
                added = []
            }
            let a = removedFrom ?? position
            let b = position  // removed words are a..<b
            guard a < b || !added.isEmpty else { return }
            changed += max(b - a, added.count)
            var range: NSRange
            var replacement = added.joined(separator: " ")
            if a < b, !added.isEmpty {
                range = NSRange(location: ranges[a].location, length: NSMaxRange(ranges[b - 1]) - ranges[a].location)
            } else if a < b {
                // Words removed: take a neighbour along so the spacing comes out right.
                if a > 0 {
                    range = NSRange(location: ranges[a - 1].location, length: NSMaxRange(ranges[b - 1]) - ranges[a - 1].location)
                    replacement = word(a - 1)
                } else if b < ranges.count {
                    range = NSRange(location: ranges[a].location, length: NSMaxRange(ranges[b]) - ranges[a].location)
                    replacement = word(b)
                } else {
                    return
                }
            } else if a > 0 {
                // Words added after an existing word.
                range = ranges[a - 1]
                replacement = word(a - 1) + " " + replacement
            } else {
                range = ranges[0]
                replacement = replacement + " " + word(0)
            }
            guard ns.substring(with: range) != replacement else { return }
            // A change of only a comma or a capital is not worth an underline from the slower check,
            // and is where it is most often wrong. The instant checker covers capitals and spacing.
            let edge = CharacterSet.punctuationCharacters.union(.whitespaces)
            func bare(_ s: String) -> String {
                s.split(separator: " ").map { $0.trimmingCharacters(in: edge).lowercased() }.joined(separator: " ")
            }
            guard bare(ns.substring(with: range)) != bare(replacement) else { return }
            issues.append(
                WritingIssue(
                    start: range.location, end: NSMaxRange(range), rule: modelRule, kind: "Grammar",
                    message: "A grammar correction from Chirp's deeper check.", priority: 200,
                    suggestions: [Fix(kind: .replace, text: replacement)]))
        }

        for op in WordDiff.diff(from: original, to: fixed) {
            switch op {
            case .same:
                flush()
                position += 1
            case .removed:
                if removedFrom == nil { removedFrom = position }
                position += 1
            case .added(let w):
                added.append(w)
            }
        }
        flush()
        // More than a third of the words changed: that is a rewrite, not proofreading.
        if changed > max(3, ranges.count / 3) { return [] }
        return issues
    }
}
