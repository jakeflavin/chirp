import Foundation

/// Fast, rule-based cleanup of dictated text. No model involved, so it never invents content:
/// every rule only removes or re-punctuates words the user said.
public struct TextCleaner: Sendable {
    /// Which of the optional rules run: the user's switches under Remember.
    public var profile: WritingProfile

    public init(profile: WritingProfile = WritingProfile()) {
        self.profile = profile
    }

    /// What the speech model heard, tidied for the page. The order matters: corrections and fillers go
    /// first so later rules see the words that are staying, and spacing and capitals are settled last.
    public func clean(_ input: String) -> String {
        var text = input
        if profile.handleSelfCorrections { text = Self.applySelfCorrections(text) }
        if profile.removeFillers { text = Self.removeFillers(text) }
        text = SpokenFormatting.applyEllipsis(text)
        if profile.collapseRepeats { text = Self.collapseRepeats(text) }
        if profile.spokenLineBreaks { text = SpokenFormatting.applySafePunctuation(text) }
        if profile.spokenLineBreaks { text = SpokenFormatting.restoreHeldMarks(Self.applySpokenLineBreaks(text)) }
        if profile.spokenPunctuation { text = Self.applySpokenPunctuation(text) }
        text = SpokenFormatting.applyQuotesAndBrackets(text)
        text = SpokenFormatting.applyAddresses(text)
        text = SpokenFormatting.applyTimes(text)
        text = TechnicalSpeech.apply(text)
        return Self.tidy(text)
    }

    // MARK: Fillers

    /// "um", "uh", "er", "hmm" and the like as whole words, with a comma or stop that trails them.
    static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])(?:u+m+|u+h+m*|e+r+m+|e+r|a+h+|h+m+|m+h+m+)(?![\p{L}\p{N}'’-])[,.…]*"#,
        options: [.caseInsensitive])

    static func removeFillers(_ text: String) -> String {
        fillerPattern.replacing(in: text, with: "")
    }

    // MARK: Repeats

    /// Words people stutter on. Two in a row is treated as a slip; other words need three.
    static let stutterWords: Set<String> = [
        "the", "a", "an", "i", "to", "and", "of", "in", "is", "it", "we", "you", "so", "but", "for", "on", "my",
        "this", "with", "at", "be", "if", "or", "they", "he", "she", "can", "was", "are",
    ]

    /// Drops a word said several times in a row ("the the the plan"), keeping it once.
    static func collapseRepeats(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let key = wordKey(tokens[i])
            var j = i + 1
            // A run only continues through tokens with no punctuation between the repeats.
            while j < tokens.count, !key.isEmpty, wordKey(tokens[j]) == key, tokens[j - 1] == stripped(tokens[j - 1]) {
                j += 1
            }
            let run = j - i
            if run >= 3 || (run == 2 && stutterWords.contains(key)) {
                // Keep the first word's capitalization and the last word's trailing punctuation.
                let last = tokens[j - 1]
                let trailing = String(last.drop { !".,!?;:".contains($0) })
                out.append(stripped(tokens[i]) + trailing)
            } else {
                out.append(contentsOf: tokens[i..<j])
            }
            i = j
        }
        return out.joined(separator: " ")
    }

    // MARK: Self-corrections

    /// "Scratch that" with the sentence before it.
    static let scratchPattern = try! NSRegularExpression(
        pattern: #"[^.!?\n]*[.!?]?\s*\b(?:scratch that|delete that|strike that)\b[,.!]*\s*"#,
        options: [.caseInsensitive])

    /// The words people change their mind with mid-sentence: "no wait", "I mean", "make that".
    static let backtrackPattern = try! NSRegularExpression(
        pattern: #"[,.]?\s*\b(?:actually,? no,? wait|no,? wait|actually,? no|no,? sorry|sorry,? i meant?|i meant?|or rather|make that)\b,?\s+"#,
        options: [.caseInsensitive])

    /// Words that can stand in for one another in a correction: days, months, numbers.
    static let categories: [Set<String>] = [
        ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight"],
        [
            "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
            "november", "december",
        ],
        [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "twenty", "thirty", "forty", "fifty", "hundred", "thousand",
        ],
    ]

    /// Which of `categories` a word belongs to, if any. Anything starting with a digit is a number.
    static func category(of word: String) -> Int? {
        let w = wordKey(word)
        if w.first?.isNumber == true { return 2 }
        return categories.firstIndex { $0.contains(w) }
    }

    /// Carries out the speaker's own corrections: "scratch that" drops the sentence before it, and
    /// "Thursday, no wait, Friday" keeps only "Friday" when it is clear which words were replaced.
    static func applySelfCorrections(_ input: String) -> String {
        // "…. Scratch that" removes the sentence before it.
        var text = scratchPattern.replacing(in: input, with: "")

        // "to Thursday, no wait, Friday" keeps only the corrected part when it is clear what was replaced.
        var searchFrom = 0
        while true {
            let ns = text as NSString
            guard searchFrom < ns.length,
                let m = backtrackPattern.firstMatch(
                    in: text, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            else { break }
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            // The clause being corrected runs back to the previous sentence end.
            let clauseStart = before.lastIndex { ".!?\n".contains($0) }.map { before.index(after: $0) } ?? before.startIndex
            let head = String(before[..<clauseStart])
            let clause = String(before[clauseStart...])
            var clauseWords = clause.split(separator: " ").map(String.init)
            let firstNew = after.split(separator: " ").first.map(String.init) ?? ""
            let key = wordKey(firstNew)

            var cut: Int?
            if !key.isEmpty, let i = clauseWords.lastIndex(where: { wordKey($0) == key }) {
                cut = i  // same anchor word repeated: "to Thursday no wait to Friday"
            } else if let cat = category(of: firstNew),
                let i = clauseWords.lastIndex(where: { category(of: $0) == cat })
            {
                cut = i  // same kind of word: a weekday for a weekday, a number for a number
            }
            guard let cut else {
                // Not clear what was replaced: leave the words alone rather than guess.
                searchFrom = m.range.location + m.range.length
                continue
            }
            clauseWords.removeSubrange(cut...)
            let kept = clauseWords.joined(separator: " ")
            let lead = head + (head.isEmpty || head.hasSuffix(" ") || kept.isEmpty ? "" : " ") + kept
            text = lead + (lead.isEmpty || lead.hasSuffix(" ") || lead.hasSuffix("\n") ? "" : " ") + after
            searchFrom = (lead as NSString).length
        }
        return text
    }

    // MARK: Spoken formatting

    static let newParagraph = try! NSRegularExpression(
        pattern: #"[,.]?\s*\bnew paragraph\b[,.]?\s*"#, options: [.caseInsensitive])
    static let newLine = try! NSRegularExpression(
        pattern: #"[,.]?\s*\b(?:new line|newline|next line)\b[,.]?\s*"#, options: [.caseInsensitive])

    /// "New line" and "new paragraph" become the breaks themselves.
    static func applySpokenLineBreaks(_ text: String) -> String {
        var t = newParagraph.replacing(in: text, with: "\n\n")
        t = newLine.replacing(in: t, with: "\n")
        return t
    }

    /// Marks said by name, each with the expression that finds it. Built once, not on every dictation.
    static let spokenMarks: [(regex: NSRegularExpression, mark: String)] = [
        ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"), ("full stop", "."),
        ("period", "."), ("comma", ","), ("semicolon", ";"), ("colon", ":"),
    ].map { word, mark in
        (try! NSRegularExpression(pattern: #"[,.]?\s*\b"# + word + #"\b[,.?!]?"#, options: [.caseInsensitive]), mark)
    }

    /// "Comma", "period" and the rest become the marks. Only runs when the user has switched it on,
    /// because these are also ordinary words.
    static func applySpokenPunctuation(_ text: String) -> String {
        spokenMarks.reduce(text) { $1.regex.replacing(in: $0, with: $1.mark) }
    }

    // MARK: Tidy

    static let spaceBeforeMark = try! NSRegularExpression(pattern: #"[ \t]+([,.!?;:])"#)
    static let doubledMark = try! NSRegularExpression(pattern: #"([,;:])(?:\s*[,;:])+"#)
    static let commaThenStop = try! NSRegularExpression(pattern: #",\s*([.!?])"#)
    static let multiSpace = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    static let spaceAroundBreak = try! NSRegularExpression(pattern: #"[ \t]*\n[ \t]*"#)
    static let leadingMarks = try! NSRegularExpression(pattern: #"(^|\n)[ \t]*[,;:.]+[ \t]*"#)
    static let sentenceStart = try! NSRegularExpression(pattern: #"(^|[.!?]\s+|\n)(\p{Ll})"#)
    /// "i. e." and "e. g." as speech recognition spells them, with a space after each stop.
    static let spacedLatin = try! NSRegularExpression(pattern: #"\b([iI])\.\s+([eE])\.|\b([eE])\.\s+([gG])\."#)

    /// Settles what the other rules leave behind: doubled spaces and marks, spaces before a mark or
    /// around a line break, a mark left at the start of a line, and a capital at the start of each sentence.
    static func tidy(_ input: String) -> String {
        var t = multiSpace.replacing(in: input, with: " ")
        t = spaceBeforeMark.replacing(in: t, with: "$1")
        t = doubledMark.replacing(in: t, with: "$1")
        t = commaThenStop.replacing(in: t, with: "$1")
        t = spaceAroundBreak.replacing(in: t, with: "\n")
        t = leadingMarks.replacing(in: t, with: "$1")
        t = t.trimmingCharacters(in: .whitespaces)
        // Written closed up and in lower case, so the stops are not taken for the ends of sentences.
        t = spacedLatin.replacing(in: t, with: "$1$3.$2$4.").replacingOccurrences(of: "I.E.", with: "i.e.")
            .replacingOccurrences(of: "E.G.", with: "e.g.").replacingOccurrences(of: "I.e.", with: "i.e.")
            .replacingOccurrences(of: "E.g.", with: "e.g.")
        // Capitalize the first letter of each sentence.
        let ns = NSMutableString(string: t)
        for m in sentenceStart.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: 2)
            // "3:30 p.m. on Friday": the full stop belongs to an abbreviation, not the end of a sentence.
            let before = ns.substring(to: r.location).trimmingCharacters(in: .whitespaces).lowercased()
            if ["a.m.", "p.m.", "e.g.", "i.e.", "vs."].contains(where: before.hasSuffix) { continue }
            ns.replaceCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return ns as String
    }

    // MARK: Helpers

    /// Lowercased letters and digits only.
    static func wordKey(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The token without trailing punctuation.
    static func stripped(_ token: String) -> String {
        var t = token
        while let last = t.last, ".,!?;:".contains(last) { t.removeLast() }
        return t
    }
}
