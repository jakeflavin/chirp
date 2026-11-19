import Foundation

/// A sentence of a document, with where it sits in the full text.
public struct ReadingSentence: Sendable, Equatable, Identifiable {
    /// Its place among the document's sentences, from zero.
    public var index: Int
    /// Character offset (UTF-16) of the sentence in the document text.
    public var offset: Int
    public var text: String
    /// True when this sentence starts a new paragraph.
    public var startsParagraph: Bool
    /// True for one cell of a table row. A table is read row by row, a cell at a time: each cell is
    /// marked on its own, with a short pause after it and a longer one at the end of its row.
    public var isCell = false

    public var id: Int { index }
    public var length: Int { (text as NSString).length }
}

/// When one word is spoken, relative to the start of its sentence.
public struct SpokenWord: Sendable, Equatable {
    /// UTF-16 range of the word within the sentence text.
    public var range: NSRange
    /// Seconds from the start of the sentence's audio.
    public var start: Double
    public var end: Double
}

/// Getting a document ready to be read aloud: cleaning imported text, splitting it into sentences,
/// and working out pauses and word timings.
public enum ReadingText {
    // MARK: Cleaning imported text

    /// Makes extracted document text pleasant to listen to: rejoins words hyphenated across lines,
    /// unwraps hard line breaks inside paragraphs, and drops page numbers and running headers.
    public static func clean(_ raw: String, pages: [String]? = nil) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let pages, pages.count >= 3 {
            text = removeRunningLines(pages).joined(separator: "\n\n")
        }
        // Lines that are only a page number go.
        let lines = text.components(separatedBy: "\n").filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || !(line.count <= 4 && line.allSatisfy(\.isNumber))
        }
        var paragraphs: [String] = []
        var current = ""
        // How many lines have been joined onto `current`.
        var joined = 0
        // Inside a fenced block of code ("```"): its lines are kept as they are, in one paragraph.
        var fence: [String]?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                // Code keeps the spaces it is indented with.
                fence?.append(line.hasPrefix("```") ? line : raw)
                if line.hasPrefix("```") {
                    paragraphs.append(fence!.joined(separator: "\n"))
                    fence = nil
                }
                continue
            }
            if line.hasPrefix("```") {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
                fence = [line]
                continue
            }
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
                joined = 0
            } else if current.isEmpty {
                current = line
                joined = 0
            } else if startsBlock(line) || isHeadingMark(current) || isTableRow(line) || isTableRow(current)
                || (joined == 0 && isBareHeading(current, before: line))
            {
                // A list item or a heading is a line of its own, not the rest of the sentence before it.
                paragraphs.append(current)
                current = line
                joined = 0
            } else if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current.removeLast()  // "exam-" + "ple" → "example"
                current += line
                joined += 1
            } else {
                current += " " + line
                joined += 1
            }
        }
        // A fence that never closed: its lines are ordinary text after all.
        if let open = fence { paragraphs.append(contentsOf: open.filter { !$0.isEmpty }) }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.map { $0.hasPrefix("```") ? $0 : collapseSpaces($0) }.joined(separator: "\n\n")
    }

    /// A title or heading as a PDF gives it: a short line of its own with no full stop, followed by a
    /// longer line that starts a sentence. Without this it ran into the sentence after it
    /// ("How Birds Learn to Sing Most songbirds are…") and was read without a pause.
    static func isBareHeading(_ line: String, before next: String) -> Bool {
        // Lines of one wrapped paragraph are about as long as each other; a heading is much shorter than what follows.
        guard line.count <= 70, line.split(separator: " ").count <= 10, line.count * 10 <= next.count * 6,
            let last = line.last, !".!?:;,-–—…".contains(last), let lead = line.first, lead.isUppercase || lead.isNumber,
            let first = next.first, first.isUppercase || first.isNumber || "\"“‘'(".contains(first)
        else { return false }
        return true
    }

    /// A Markdown heading line ("## Setup").
    static func isHeadingMark(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " "
    }

    /// A line that starts a list item ("- ", "* ", "• ", "1. ") or a heading ("## ").
    static func startsBlock(_ line: String) -> Bool {
        if isHeadingMark(line) { return true }
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " { return true }
        let digits = line.prefix { $0.isNumber }
        guard (1...2).contains(digits.count) else { return false }
        let after = line.dropFirst(digits.count)
        return (after.first == "." || after.first == ")") && after.dropFirst().first == " "
    }

    /// Drops lines that repeat at the top or bottom of most pages (headers and footers).
    static func removeRunningLines(_ pages: [String]) -> [String] {
        func key(_ line: String) -> String {
            // Ignore digits so "Page 3" and "Page 4" count as the same line.
            String(line.lowercased().filter { !$0.isNumber && !$0.isWhitespace })
        }
        var counts: [String: Int] = [:]
        let split = pages.map { $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        for lines in split where lines.count >= 5 {
            var seen = Set<String>()
            for line in lines.prefix(2) + lines.suffix(2) where line.count < 90 {
                let k = key(line)
                if !k.isEmpty, seen.insert(k).inserted { counts[k, default: 0] += 1 }
            }
        }
        let threshold = max(3, pages.count * 6 / 10)
        let running = Set(counts.filter { $0.value >= threshold }.keys)
        return split.map { lines in
            lines.enumerated().filter { i, line in
                lines.count < 5 || !((i < 2 || i >= lines.count - 2) && running.contains(key(line)))
            }.map(\.element).joined(separator: "\n")
        }
    }

    /// Runs of spaces as one space, with none at either end.
    static func collapseSpaces(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: Sentences

    /// Words whose full stop does not end a sentence, in lower case without that stop.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "fig", "no", "inc", "ltd", "co",
        "u.s", "u.k", "a.m", "p.m", "approx", "est", "dept", "gen", "col", "lt", "sgt", "rev", "vol", "pp", "ch",
        "ave", "blvd", "rd", "rm", "sec", "eq", "corp", "misc", "mon", "tue", "tues", "wed", "thu", "thurs", "fri",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mt", "ft", "min", "max",
    ]

    // MARK: Tables

    /// The cells of a line that is a row of a table, each with where it starts in the line (UTF-16);
    /// nil for any other line. A row is written with bars ("| Name | Pace |"), as Markdown and Chirp's
    /// own import of a web page write it, or with tabs between its cells, as a table copied or selected
    /// in another app arrives. The rule under a Markdown heading row ("|---|---|") is a row with no cells.
    static func tableCells(_ line: String) -> [(offset: Int, text: String)]? {
        let ns = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: unichar
        if trimmed.hasPrefix("|"), trimmed.filter({ $0 == "|" }).count >= 2 {
            separator = 124
            if trimmed.allSatisfy({ "|:- \t".contains($0) }), trimmed.contains("-") { return [] }
        } else if trimmed.contains("\t") {
            separator = 9
        } else {
            return nil
        }
        var cells: [(offset: Int, text: String)] = []
        var start = 0
        func take(_ end: Int) {
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cells.append((start + raw.prefix { $0.isWhitespace }.utf16.count, text)) }
        }
        for i in 0..<ns.length where ns.character(at: i) == separator {
            take(i)
            start = i + 1
        }
        take(ns.length)
        // One cell is not a table: a line of prose with a stray tab, or "| a note".
        return cells.count >= 2 ? cells : nil
    }

    /// Whether a line is a row of a table (the rule under a heading row included).
    static func isTableRow(_ line: String) -> Bool { tableCells(line) != nil }

    /// Splits text into sentences, keeping each sentence's position in the original text. A row of a
    /// table becomes one sentence a cell, the first of them starting a paragraph.
    public static func sentences(_ text: String) -> [ReadingSentence] {
        let ns = text as NSString
        var out: [ReadingSentence] = []
        // What comes first, and what follows a table, starts a paragraph.
        var paragraphStart = true
        // The lines since the last table row, to be split as prose.
        var prose: NSRange?
        func flushProse() {
            guard let range = prose else { return }
            prose = nil
            let found = proseSentences(ns.substring(with: range), startsParagraph: paragraphStart)
            for sentence in found {
                var s = sentence
                s.index = out.count
                s.offset += range.location
                out.append(s)
            }
            if !found.isEmpty { paragraphStart = false }
        }
        var at = 0
        while at < ns.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            if let cells = tableCells(ns.substring(with: line)) {
                flushProse()
                for (n, cell) in cells.enumerated() {
                    out.append(ReadingSentence(index: out.count, offset: line.location + cell.offset, text: cell.text, startsParagraph: n == 0, isCell: true))
                }
                paragraphStart = true
            } else {
                // A blank line before the prose that follows is kept with it, so it still starts a paragraph.
                prose = prose.map { NSUnionRange($0, line) } ?? line
            }
            at = NSMaxRange(line)
        }
        flushProse()
        return out
    }

    /// Splits prose into sentences. `startsParagraph` says whether its first sentence starts one.
    static func proseSentences(_ text: String, startsParagraph: Bool = true) -> [ReadingSentence] {
        let ns = text as NSString
        var out: [ReadingSentence] = []
        var start = 0
        var paragraphStart = startsParagraph
        var i = 0
        func flush(_ end: Int) {
            guard end > start else { return }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let leading = raw.prefix { $0.isWhitespace }.utf16.count
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(ReadingSentence(index: out.count, offset: start + leading, text: trimmed, startsParagraph: paragraphStart))
                paragraphStart = false
            }
            start = end
        }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 10 {  // newline ends a sentence; a blank line starts a paragraph
                flush(i + 1)
                if i + 1 < ns.length, ns.character(at: i + 1) == 10 { paragraphStart = true }
                if out.isEmpty || i == 0 { paragraphStart = true }
            } else if c == 46 || c == 33 || c == 63 {  // . ! ?
                var end = i + 1
                // Take closing quotes and brackets with the sentence.
                while end < ns.length, [34, 39, 41, 93, 8217, 8221].contains(Int(ns.character(at: end))) { end += 1 }
                let atEnd = end >= ns.length
                let followedBySpace = !atEnd && (ns.character(at: end) == 32 || ns.character(at: end) == 10)
                if atEnd || followedBySpace {
                    var isBoundary = true
                    if c == 46 {
                        // "Dr." and "3.5" and "U.S." are not sentence ends.
                        var wordStart = i
                        while wordStart > start, ns.character(at: wordStart - 1) != 32, ns.character(at: wordStart - 1) != 10 { wordStart -= 1 }
                        let word = ns.substring(with: NSRange(location: wordStart, length: i - wordStart)).lowercased()
                        if abbreviations.contains(word) || (word.count == 1 && word.first!.isLetter && word != "i") { isBoundary = false }
                        // Next word starting lowercase means the sentence continues.
                        var next = end
                        while next < ns.length, ns.character(at: next) == 32 { next += 1 }
                        if next < ns.length, let scalar = Unicode.Scalar(ns.character(at: next)),
                            CharacterSet.lowercaseLetters.contains(scalar)
                        { isBoundary = false }
                    }
                    if isBoundary {
                        flush(end)
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }
        flush(ns.length)
        return out
    }

    /// What the voice should say for a sentence: bare links are dropped and dictionary pronunciations
    /// are substituted. With `skipCitations`, marks that point at a source are left out ("[12]",
    /// "(Smith, 2020)", raised note numbers: see `Citations`); with `skipBrackets`, everything in brackets is.
    ///
    /// `pronunciations` maps a term to how it should be said. A term is matched as a whole word, whatever
    /// its capitals; when two terms overlap the longer one is used.
    public static func spoken(
        _ sentence: String, pronunciations: [String: String] = [:], skipBrackets: Bool = false, skipCitations: Bool = true
    ) -> String {
        var s = sentence
        if skipBrackets {
            // Asides in round or square brackets, such as "(Smith, 2019)" or "[see Figure 2]".
            s = roundAside.replacing(in: s, with: "")
            s = squareAside.replacing(in: s, with: "")
        }
        if skipCitations { s = Citations.removing(from: s) }
        s = bareLink.replacing(in: s, with: "link")
        // Units, phone numbers, Markdown marks and the other things the voice misreads.
        s = SpeechText.spoken(s)
        s = collapseSpaces(s)
        // A heading or a list item has no full stop. Read as it stands, the voice leaves its tone hanging,
        // as if the sentence went on; with one, it comes down the way a person ends a line.
        if let last = s.last, last.isLetter || last.isNumber { s += "." }
        // Longest term first, so "Anna Lee" is not half replaced by the entry for "Anna" (and so the result
        // does not depend on the order a dictionary happens to hand its entries over in).
        for (term, said) in pronunciations.sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) where !said.isEmpty && !term.isEmpty {
            // "Not next to a letter or digit" rather than a word boundary: a boundary never matches after
            // the last "+" of "C++" or before the "." of ".NET".
            guard let regex = Patterns.regex(#"(?<!\w)"# + NSRegularExpression.escapedPattern(for: term) + #"(?!\w)"#, options: [.caseInsensitive])
            else { continue }
            // The pronunciation is put in as written; "$" and "\" in it are not instructions.
            s = regex.replacing(in: s, with: NSRegularExpression.escapedTemplate(for: said))
        }
        return collapseSpaces(s)
    }

    private static let roundAside = try! NSRegularExpression(pattern: #"\s*\([^()]*\)"#)
    private static let squareAside = try! NSRegularExpression(pattern: #"\s*\[[^\[\]]*\]"#)
    private static let bareLink = try! NSRegularExpression(pattern: #"https?://\S+"#)

    // MARK: Pauses

    /// The pause after a cell of a table, and after the last cell of a row.
    public static let cellPause = 0.35
    public static let rowPause = 0.7

    /// How long to wait after sentence `i`, in seconds at normal speed. A person reading aloud takes a
    /// breath between sentences, longer between paragraphs, and longest after a heading; one fixed gap
    /// everywhere is a large part of what makes read-aloud sound like a machine.
    public static func pause(after i: Int, in sentences: [ReadingSentence]) -> Double {
        guard sentences.indices.contains(i) else { return 0.25 }
        let text = sentences[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsParagraph = i + 1 >= sentences.count || sentences[i + 1].startsParagraph
        // A table: a short pause after each cell, a longer one at the end of the row.
        if sentences[i].isCell { return endsParagraph ? rowPause : cellPause }
        let last = text.last
        if endsParagraph {
            // A short line with no full stop, alone in its paragraph: a heading or a title.
            let heading = sentences[i].startsParagraph && text.count <= 80 && !(last.map { ".!?:;,".contains($0) } ?? false)
            return heading ? 0.75 : 0.6
        }
        switch last {
        case "?", "!": return 0.32
        case ":", ";": return 0.22
        default: return 0.26
        }
    }

    // MARK: Word timing

    /// Ranges of the words in a sentence (anything between whitespace). A non-breaking space counts as
    /// a space: web editors put them between ordinary words.
    public static func wordRanges(_ sentence: String) -> [NSRange] {
        let ns = sentence as NSString
        var ranges: [NSRange] = []
        var start: Int?
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            let isSpace = c == 32 || c == 10 || c == 9 || c == 13 || c == 0xA0
            if isSpace {
                if let s = start { ranges.append(NSRange(location: s, length: i - s)) }
                start = nil
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(NSRange(location: s, length: ns.length - s)) }
        return ranges
    }

    /// Works out when each displayed word is spoken.
    ///
    /// `spokenWeights` is one weight per spoken word (its share of the audio, e.g. summed phoneme durations).
    /// When the spoken words line up one-to-one with the displayed words they are used directly;
    /// otherwise time is shared out by word length, which stays close enough to follow along.
    public static func wordTimings(sentence: String, spokenWeights: [Double], duration: Double) -> [SpokenWord] {
        let ranges = wordRanges(sentence)
        guard !ranges.isEmpty, duration > 0 else { return [] }
        let weights: [Double]
        if spokenWeights.count == ranges.count, spokenWeights.reduce(0, +) > 0 {
            weights = spokenWeights
        } else {
            weights = ranges.map { Double($0.length) + 1.5 }  // every word takes some time, long words more
        }
        let total = weights.reduce(0, +)
        var t = 0.0
        return zip(ranges, weights).map { range, w in
            let span = duration * w / total
            defer { t += span }
            return SpokenWord(range: range, start: t, end: t + span)
        }
    }

    /// The index of the word being spoken at `time`.
    public static func wordIndex(at time: Double, in timings: [SpokenWord]) -> Int? {
        guard !timings.isEmpty else { return nil }
        if let i = timings.firstIndex(where: { time < $0.end }) { return i }
        return timings.count - 1
    }

    /// Estimated listening time in seconds at normal speed.
    public static func estimatedDuration(_ text: String) -> Double {
        Double(text.split { $0.isWhitespace }.count) / 165.0 * 60.0
    }
}
