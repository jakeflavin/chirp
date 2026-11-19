import Foundation

/// The check every point the model writes for a section goes through ("source words first"),
/// in the way `RewriteCheck` reads a rewrite. A point must keep, as they are in the source sentences it came from,
/// the source's numbers (with their units, and "more than" / "less than" before them), its names, and its polarity
/// words: not, no, never, without, less, more, fewer, higher, lower, cooler, warmer, increase, only… A point that adds
/// a number or a name, adds or turns round a polarity word, drops a "not", or is mostly words the source does not
/// use, is not shown: the source's own closest sentence stands in its place.
public enum SourceCheck {
    public enum Problem: String, Sendable, Equatable {
        /// A number that is not in the sentences the point came from, or with another unit, or "more than" turned to "less than".
        case number
        /// A name that is not in them.
        case name
        /// A polarity word (not, less, cooler, increase, only…) the sentences do not have.
        case polarity
        /// The sentences say "not" (or "no", "never", "without") and the point does not.
        case negationLost
        /// The point keeps a sentence's number but not the comparison that went with it ("1.8°C cooler" → "1.8°C").
        case comparisonLost
        /// Too few of the point's words are in the source at all.
        case unsupported
    }

    /// What the check made of one point.
    public struct Verdict: Sendable, Equatable {
        public var problems: [Problem]
        /// The source sentence the point is closest to.
        public var closest: String?
        /// A second source sentence the point also drew on (a point that put two stories together), when there is one.
        public var also: String?
        public var passes: Bool { problems.isEmpty }
    }

    /// The sections with every point checked against `source` (the text of the part they were written from): a point that
    /// fails is replaced by its closest source sentence, or left out when that sentence is already shown in the section.
    /// Returns how many were replaced and left out.
    /// `kept` lists the model's own points that passed, for a further check.
    public static func checked(_ sections: [SummarySection], source: String) -> (sections: [SummarySection], replaced: Int, dropped: Int, kept: [String]) {
        let sentences = sourceSentences(source)
        var replaced = 0
        var dropped = 0
        var kept: [String] = []
        var out: [SummarySection] = []
        for var section in sections {
            var points: [String] = []
            for point in section.points {
                let verdict = check(point, sentences: sentences, source: source)
                if verdict.passes {
                    points.append(point)
                    kept.append(point)
                } else if let closest = verdict.closest.map(SummarySentence.trimmed), !points.contains(closest) {
                    // Both sentences a point joined stand in for it, in the source's order, so neither story is lost.
                    let both = [closest] + (verdict.also.map(SummarySentence.trimmed).map { [$0] } ?? [])
                    let ordered = both.sorted { (source.range(of: $0)?.lowerBound ?? source.endIndex) < (source.range(of: $1)?.lowerBound ?? source.endIndex) }
                    points += ordered.filter { !points.contains($0) }
                    replaced += 1
                } else {
                    dropped += 1
                }
            }
            section.points = points
            out.append(section)
        }
        return (out, replaced, dropped, kept)
    }

    /// One point, checked against the source.
    public static func check(_ point: String, source: String) -> Verdict {
        check(point, sentences: sourceSentences(source), source: source)
    }

    /// A sentence as it is shown: one line, no citation markers ("[12]"), no list mark.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*\[\d+(,\s*\d+)*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The source's sentences, and its list items and short lines, each one thing a point may have come from.
    static func sourceSentences(_ source: String) -> [String] {
        var out: [String] = []
        for p in source.components(separatedBy: .newlines) {
            let line = p.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```"), !line.hasPrefix("~~~") else { continue }
            let plain = MarkdownLines.plain(line)
            let found = ReadingText.proseSentences(plain).map { tidy($0.text) }.filter { !$0.isEmpty }
            out += found.isEmpty ? [tidy(plain)] : found
        }
        return out
    }

    static func check(_ raw: String, sentences: [String], source: String) -> Verdict {
        let point = MarkdownLines.plain(raw).replacingOccurrences(of: "**", with: "")
        let lowerPoint = point.lowercased()
        let pContent = contentStems(point)
        let pNumbers = numbers(in: point)
        let pPolar = polarWords(in: point)
        guard !sentences.isEmpty else { return Verdict(problems: [.unsupported], closest: nil, also: nil) }
        let info = sentences.map { s in (content: contentStems(s), numbers: numbers(in: s), polar: polarWords(in: s), lower: s.lowercased()) }
        let lowerSource = source.lowercased()

        // The sentence the point is closest to: the most of its words and numbers in common. It stands in for the point if
        // the point fails.
        func score(_ k: Int) -> Double {
            Double(info[k].content.intersection(pContent).count) + 2 * Double(Set(info[k].numbers.map(\.value)).intersection(pNumbers.map(\.value)).count)
                + Double(Set(info[k].polar.map(\.family)).intersection(pPolar.map(\.family)).count)
        }
        let first = sentences.indices.max { score($0) < score($1) }!
        var problems: [Problem] = []

        // What a number or a polarity word in the point is said about: the words around it.
        func around(_ range: NSRange) -> Set<String> {
            let ns = lowerPoint as NSString
            let from = max(0, range.location - 45)
            let to = min(ns.length, range.location + range.length + 25)
            return contentStems(ns.substring(with: NSRange(location: from, length: to - from))).subtracting(pPolar.map(\.family))
        }
        // A sentence of the source that says this: it has the thing (a number, a polarity word) and something of what
        // the point says about it. "Low-income neighbourhoods were … cooler" needs a sentence with "cooler" and
        // "low-income" or "neighbourhoods", not "cooler" from one sentence and "low-income" from another.
        // The sentence before counts with it, since a sentence often goes on about the last one's subject ("It was 1.9°C
        // in Atlanta").
        func bound(_ near: Set<String>, _ has: (Int) -> Bool) -> [Int] {
            sentences.indices.filter { k in
                has(k) && (near.isEmpty || !info[k].content.union(k > 0 ? info[k - 1].content : []).intersection(near).isEmpty)
            }
        }

        // Numbers: in a sentence about the same thing, with the same unit and no "more than" turned to "less than".
        for n in pNumbers {
            let with = bound(around(n.range)) { k in info[k].numbers.contains { $0.value == n.value } }
            if with.isEmpty { problems.append(.number); break }
            let agrees = with.contains { k in
                info[k].numbers.contains { s in
                    s.value == n.value && (n.unit == nil || s.unit == nil || n.unit == s.unit) && (n.direction == nil || s.direction == nil || n.direction == s.direction)
                }
            }
            if !agrees { problems.append(.number); break }
        }
        // Names: every one is in the part.
        if names(in: point).contains(where: { !hasName($0, in: lowerSource) }) || firstWordName(point, closest: sentences[first], source: source) != nil { problems.append(.name) }
        // Polarity words: each in a sentence about the same thing.
        for w in pPolar {
            if bound(around(w.range)) { k in info[k].polar.contains { $0.family == w.family } }.isEmpty { problems.append(.polarity); break }
        }
        // A "not" says something about the word after it: that word follows a "not" in the source too ("not only cooler
        // days" is not "not cooler nights").
        let after = negated(point)
        if !after.isEmpty, !after.isSubset(of: negated(source)) { problems.append(.polarity) }
        // A "not" in the closest sentence stays when the point keeps what it was said about.
        let sourceAfter = negated(sentences[first])
        if !sourceAfter.isEmpty, !pPolar.contains(where: { $0.family == "not" }), !sourceAfter.intersection(Set(RewriteCheck.words(point).map(RewriteCheck.stem))).isEmpty {
            problems.append(.negationLost)
        }
        // The comparison written next to a number in the source goes with it: a point that keeps "1.8°C" keeps "cooler".
        for n in info[first].numbers where pNumbers.contains(where: { $0.value == n.value }) {
            let ns = info[first].lower as NSString
            let to = min(ns.length, n.range.location + n.range.length + 22)
            let next = polarWords(in: ns.substring(with: NSRange(location: n.range.location, length: to - n.range.location))).filter { $0.family != "not" }
            if !next.isEmpty, pPolar.filter({ $0.family != "not" }).isEmpty { problems.append(.comparisonLost); break }
        }
        // Mostly the model's own words: at least half of what the point says must be words the part uses.
        let sourceStems = contentStems(source)
        if pContent.count >= 4, Double(pContent.intersection(sourceStems).count) < Double(pContent.count) * 0.5 { problems.append(.unsupported) }
        // A sentence with nothing in common with the point is no stand-in for it.
        let close = info[first].content.intersection(pContent).count >= 2 || !Set(info[first].numbers.map(\.value)).intersection(pNumbers.map(\.value)).isEmpty
        // The second sentence the point drew on: the one that has most of what the closest does not (two of its words, or
        // one of its numbers, at least).
        let rest = pContent.subtracting(info[first].content)
        let restNumbers = Set(pNumbers.map(\.value)).subtracting(info[first].numbers.map(\.value))
        let second = sentences.indices.filter { $0 != first }.max { a, b in
            func gain(_ k: Int) -> Int { info[k].content.intersection(rest).count + 2 * Set(info[k].numbers.map(\.value)).intersection(restNumbers).count }
            return gain(a) < gain(b)
        }
        let also = second.flatMap { k -> String? in
            let gain = info[k].content.intersection(rest).count + 2 * Set(info[k].numbers.map(\.value)).intersection(restNumbers).count
            return gain >= 3 ? sentences[k] : nil
        }
        return Verdict(problems: problems, closest: close ? sentences[first] : nil, also: close ? also : nil)
    }

    static func contentStems(_ text: String) -> Set<String> {
        Set(RewriteCheck.words(text).filter(RewriteCheck.isContent).map(RewriteCheck.stem))
    }

    /// The polarity words of a text, each with its family and where it is.
    static func polarWords(in text: String) -> [(family: String, range: NSRange)] {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let ns = lower as NSString
        guard let regex = Patterns.regex(#"[a-z']+"#) else { return [] }
        return regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            polarity(ns.substring(with: m.range)).map { ($0, m.range) }
        }
    }

    // MARK: Numbers

    struct Number: Equatable {
        var value: String
        var unit: String?
        /// "up" after "more than", "over", "at least"…; "down" after "less than", "under", "up to"….
        var direction: String?
        /// Where it is in the text it was read from.
        var range = NSRange(location: 0, length: 0)

        static func == (a: Number, b: Number) -> Bool { a.value == b.value && a.unit == b.unit && a.direction == b.direction }
    }

    /// The numbers in a text, written as digits or as words, with the unit after each and the comparison before it.
    static func numbers(in text: String) -> [Number] {
        var out: [Number] = []
        let ns = text as NSString
        let pattern = #"(?<![\w.])(\$|£|€)?(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(?:\s?(%|°\s?[cf]\b|percentage points?|per ?cent\b|percent\b|million\b|billion\b|thousand\b|k\b|m\b|km\b|kg\b|g\b|mg\b|ms\b|s\b|gb\b|mb\b|tb\b|minutes?\b|hours?\b|days?\b|weeks?\b|months?\b|years?\b|nights?\b|metres?\b|meters?\b|miles?\b|feet\b|people\b|users?\b|x\b))?"#
        guard let regex = Patterns.regex(pattern, options: [.caseInsensitive]) else { return [] }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var value = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ",", with: "")
            value = String(value.drop { $0 == "0" })
            if value.isEmpty { value = "0" }
            if m.range(at: 3).location != NSNotFound { value += ns.substring(with: m.range(at: 3)) }
            var unit: String?
            if m.range(at: 1).location != NSNotFound { unit = ns.substring(with: m.range(at: 1)) }
            if m.range(at: 4).location != NSNotFound { unit = normalUnit(ns.substring(with: m.range(at: 4))) }
            let before = ns.substring(to: m.range.location).lowercased()
            out.append(Number(value: value, unit: unit, direction: direction(before: before), range: m.range))
        }
        // Numbers written as words ("eleven more nights"); not after a number ("3 million").
        let lower = text.lowercased()
        let lns = lower as NSString
        if let words = Patterns.regex(#"(?<![\w.])([a-z]+)\b"#) {
            for m in words.matches(in: lower, range: NSRange(location: 0, length: lns.length)) {
                let w = lns.substring(with: m.range(at: 1))
                guard let n = RewriteCheck.numberWords[w] ?? RewriteCheck.ordinalWords[w].map(String.init) else { continue }
                let before = lns.substring(to: m.range.location)
                if before.trimmingCharacters(in: .whitespaces).last?.isNumber == true { continue }
                out.append(Number(value: n, unit: nil, direction: direction(before: before), range: m.range))
            }
        }
        return out
    }

    static func normalUnit(_ u: String) -> String {
        let l = u.lowercased().replacingOccurrences(of: " ", with: "")
        if l.hasPrefix("percentage") { return "pp" }
        if l == "%" || l.hasPrefix("percent") { return "%" }
        if l.hasPrefix("°") { return l }
        if l.hasSuffix("s"), l.count > 3 { return String(l.dropLast()) }
        if l == "metre" { return "meter" }
        return l
    }

    /// The comparison written just before a number: "up" ("more than 40%", "over", "at least") or "down" ("less than",
    /// "under", "at most", "up to").
    static func direction(before: String) -> String? {
        let tail = before.split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " ")
        if tail.range(of: #"(more than|greater than|higher than|over|above|at least|exceeding|upwards of)$"#, options: .regularExpression) != nil { return "up" }
        if tail.range(of: #"(less than|fewer than|lower than|under|below|at most|up to|no more than)$"#, options: .regularExpression) != nil { return "down" }
        return nil
    }

    // MARK: Words

    /// A polarity word's family: "cooler" and "cooled" are "cool"; "fewer" is "less"; "n't" and "never" are "not".
    static func polarity(_ word: String) -> String? {
        if RewriteCheck.isNegation(word) || word == "without" || word == "none" { return "not" }
        let stem = RewriteCheck.stem(word)
        for (family, forms) in polarityFamilies where forms.contains(where: { word == $0 || stem == RewriteCheck.stem($0) }) {
            return family
        }
        return nil
    }

    static let polarityFamilies: [(String, [String])] = [
        ("more", ["more"]), ("less", ["less", "fewer"]), ("most", ["most"]), ("least", ["least"]),
        ("higher", ["higher", "highest"]), ("lower", ["lower", "lowest"]), ("cooler", ["cooler", "coolest", "colder", "coldest"]),
        ("warmer", ["warmer", "warmest", "hotter", "hottest"]), ("larger", ["larger", "largest", "bigger", "biggest", "greater", "greatest"]),
        ("smaller", ["smaller", "smallest"]), ("better", ["better", "best"]), ("worse", ["worse", "worst"]),
        ("increase", ["increase", "rise", "rose", "risen", "rising", "grew", "grow", "grown", "raise", "raised", "boost", "gain"]),
        ("decrease", ["decrease", "decline", "drop", "dropped", "fell", "fall", "falling", "reduce", "reduction", "shrank", "shrink", "cut", "cuts", "lowered", "slash", "slashed"]),
        ("only", ["only"]), ("before", ["before", "earlier"]), ("after", ["after", "later"]), ("above", ["above"]), ("below", ["below"]),
        ("faster", ["faster", "fastest"]), ("slower", ["slower", "slowest"]), ("cheaper", ["cheaper", "cheapest"]),
        ("exclude", ["exclude", "except", "excluding"]), ("include", ["include", "including"]),
    ]

    /// Words written with a capital inside a sentence (not "I"): what may be a name. The point's first word counts too
    /// when it is not a word the source uses at all ("Marcus found the crash", where the source says Tom).
    static func names(in text: String) -> [String] {
        RewriteCheck.capitals(text).filter { $0.count >= 2 && $0 != "I" }.map { $0.lowercased() }
    }

    /// The point's first word, when it looks like a name put in place of the one that starts its closest sentence:
    /// both written as names ("Marcus", "Tom"), neither used in the source in lower case, and the point's not in the
    /// source at all ("Marcus found the crash", where the source says "Tom found the crash").
    static func firstWordName(_ point: String, closest: String, source: String) -> String? {
        func first(_ text: String) -> String? {
            text.split(whereSeparator: \.isWhitespace).first.map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        }
        func titled(_ w: String) -> Bool { w.count >= 3 && w.allSatisfy(\.isLetter) && w.first!.isUppercase && w.dropFirst().allSatisfy(\.isLowercase) }
        guard let mine = first(point), let theirs = first(closest), titled(mine), titled(theirs), mine != theirs else { return nil }
        let lower = source.lowercased()
        let a = mine.lowercased(), b = theirs.lowercased()
        // A word the source writes in lower case is an ordinary word, not a name.
        if source.contains(" \(b) ") || source.contains(" \(a) ") { return nil }
        return RewriteCheck.has(a, in: lower) ? nil : a
    }

    /// The word straight after each "not", "no", "never", "n't" or "without" in a text, stemmed.
    static func negated(_ text: String) -> Set<String> {
        let w = RewriteCheck.words(text)
        var out = Set<String>()
        for (i, word) in w.enumerated() where polarity(word) == "not" && i + 1 < w.count {
            out.insert(RewriteCheck.stem(w[i + 1]))
        }
        return out
    }

    static func hasName(_ name: String, in lowered: String) -> Bool {
        RewriteCheck.has(name, in: lowered) || RewriteCheck.has(RewriteCheck.stem(name), in: lowered)
    }
}

/// A source sentence shown as a point.
public enum SummarySentence {
    /// Without a connective that only made sense where it stood ("However,", "In addition,", "First,").
    public static func trimmed(_ sentence: String) -> String {
        // A newsletter story's reading time or kind ("(2 minute read)") is not part of what it says.
        var s = sentence.replacingOccurrences(of: #"\s*\((\d+\s*min(ute)?s?\s*read|github repo|website|podcast|video)\)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let lead = s.range(of: #"^(however|moreover|furthermore|in addition|additionally|also|first|second|third|finally|then|so|but|and|thus|therefore|meanwhile|in fact|indeed),\s+"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(lead)
            if let f = s.first { s = f.uppercased() + s.dropFirst() }
        }
        return s
    }
}

/// What Mail shows above a message's body, read for its subject.
public enum MailHeader {
    /// The subject among the header's lines, in the order Mail shows them: the line after a "Subject:" label, or a
    /// "Subject: …" line; else the first line that is not the sender (the first line), a date or time, an address,
    /// or a "To:", "Cc:" or "Reply-To:" line. Nil when nothing fits.
    public static func subject(fromHeaderLines lines: [String]) -> String? {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for (i, line) in clean.enumerated() {
            let l = line.lowercased()
            if l == "subject:" || l == "subject", i + 1 < clean.count { return clean[i + 1] }
            if l.hasPrefix("subject:") { return String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        }
        for line in clean.dropFirst() {
            let l = line.lowercased()
            if l.range(of: #"^(to|cc|bcc|from|reply-to|date|sent)\s*:"#, options: .regularExpression) != nil { continue }
            if line.contains("@") || isDateOrTime(line) || TextStats.words(line) > 25 { continue }
            if l == "to" || l == "cc" || l == "reply-to" || l.hasPrefix("inbox") || l.hasSuffix("…") { continue }
            return line
        }
        return nil
    }

    /// The subject as a document's title: without "Re:" and "Fwd:".
    public static func title(_ subject: String) -> String? {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        while let reply = s.range(of: #"^(re|fwd?|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(reply) }
        return s.isEmpty ? nil : (s.count > 80 ? String(s.prefix(80)) + "…" : s)
    }

    static func isDateOrTime(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.range(of: #"^(today|yesterday)\b"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil, line.split(separator: " ").count <= 8 { return true }
        return l.range(of: #"^((mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+)?((jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}|\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|\d{1,2}/\d{1,2}/\d{2,4})"#, options: .regularExpression) != nil
    }
}

extension SourceCheck {
    /// A part's text cut at sentence ends into chunks for the sentence checker: MiniCheck uses about 400 tokens a chunk,
    /// which is about 1,600 characters of English. A sentence longer than that is a chunk on its own.
    public static func checkerChunks(_ text: String, maxCharacters: Int = 1600) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sourceSentences(text) {
            if !current.isEmpty, current.count + sentence.count + 1 > maxCharacters {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
