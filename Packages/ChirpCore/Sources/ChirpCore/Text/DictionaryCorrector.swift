import Foundation

/// Rewrites words that speech recognition got nearly right into the user's own spelling.
///
/// Two passes over 1–3 word spans that never cross punctuation:
/// 1. exact match against an entry's "sounds like" aliases;
/// 2. fuzzy match against the term itself (edit distance, helped by a sounds-alike check).
public struct DictionaryCorrector: Sendable {
    /// One change the corrector made: what was heard, and the user's term it became.
    public struct Replacement: Sendable, Equatable {
        public let heard: String
        public let term: String
    }

    /// A dictionary term ready for comparing: its letters only, and how it sounds.
    struct Candidate: Sendable {
        let term: String
        let key: String
        let soundex: String
    }

    let candidates: [Candidate]
    let aliases: [String: String]  // normalized alias → term
    /// Letters-only form of each term → the term, for words that only need their capitals or spacing fixed.
    let exactTerms: [String: String]
    /// How different a heard word may be from a term and still be taken for it (0 is identical, 1 is nothing alike).
    public var threshold: Double

    public init(entries: [DictionaryEntry], threshold: Double = 0.18) {
        var cands: [Candidate] = []
        var aliasMap: [String: String] = [:]
        for e in entries where e.enabled {
            let key = Self.normalize(e.term)
            guard !key.isEmpty else { continue }
            cands.append(Candidate(term: e.term, key: key, soundex: Self.soundex(key)))
            for a in e.soundsLike {
                let k = Self.normalize(a)
                if !k.isEmpty { aliasMap[k] = e.term }
            }
        }
        candidates = cands
        aliases = aliasMap
        exactTerms = Dictionary(cands.map { ($0.key, $0.term) }, uniquingKeysWith: { first, _ in first })
        self.threshold = threshold
    }

    /// `text` with near misses rewritten as the user's terms.
    public func correct(_ text: String) -> String { correctWithLog(text).text }

    /// As `correct`, also listing each change made, so a correction can be shown or undone.
    public func correctWithLog(_ text: String) -> (text: String, replacements: [Replacement]) {
        guard !candidates.isEmpty || !aliases.isEmpty else { return (text, []) }
        var log: [Replacement] = []
        // Work line by line so line breaks survive.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < words.count {
                // Try every span length at this position and keep the closest match.
                var best: (n: Int, term: String, score: Double)?
                for n in stride(from: min(3, words.count - i), through: 1, by: -1) {
                    let span = Array(words[i..<(i + n)])
                    // Punctuation inside the span (not on its last word) means a clause boundary.
                    if span.dropLast().contains(where: { Self.hasTrailingPunctuation($0) }) { continue }
                    if span.contains(where: { $0.isEmpty }) { continue }
                    let key = Self.normalize(span.joined())
                    guard key.count >= 2, let m = match(key: key) else { continue }
                    if m.score < (best?.score ?? .infinity) { best = (n, m.term, m.score) }
                }
                if let best {
                    let span = Array(words[i..<(i + best.n)])
                    let lead = Self.split(span[0]).lead
                    let trail = Self.split(span[best.n - 1]).trail
                    let core = Self.split(span.joined(separator: " ")).core
                    if core != best.term {
                        words.replaceSubrange(i..<(i + best.n), with: [lead + best.term + trail])
                        log.append(Replacement(heard: core, term: best.term))
                    }
                }
                i += 1
            }
            return words.joined(separator: " ")
        }
        return (lines.joined(separator: "\n"), log)
    }

    /// The best dictionary term for a normalized span, with a score where lower is closer (0 is exact).
    func match(key: String) -> (term: String, score: Double)? {
        if let term = aliases[key] { return (term, 0) }
        if let term = exactTerms[key] { return (term, 0) }  // same letters as a term: fix casing and spacing only
        // Very short words are too easy to confuse; require an alias for them.
        guard key.count >= 4 else { return nil }
        let sx = Self.soundex(key)
        var best: (term: String, score: Double)?
        for c in candidates {
            let maxLen = max(c.key.count, key.count)
            let allowed = max(Int(Double(maxLen) * 0.25), 2)
            if abs(c.key.count - key.count) > allowed { continue }
            var score = Double(Self.levenshtein(key, c.key)) / Double(maxLen)
            if sx == c.soundex { score *= 0.3 }
            if score < threshold, score < (best?.score ?? .infinity) { best = (c.term, score) }
        }
        return best
    }

    // MARK: Helpers

    /// Letters and digits only, in lower case and without accents: the form words are compared in.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    static func hasTrailingPunctuation(_ w: String) -> Bool {
        guard let last = w.last else { return false }
        return ".,!?;:".contains(last)
    }

    /// Splits a token into leading punctuation, core, trailing punctuation.
    static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let isEdge: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        let lead = String(token.prefix(while: isEdge))
        let rest = token.dropFirst(lead.count)
        let trail = String(rest.reversed().prefix(while: isEdge).reversed())
        let core = String(rest.dropLast(trail.count))
        return (lead, core, trail)
    }

    /// How many single-letter changes turn one word into the other.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// A four-character code that is the same for words that sound alike ("Smith" and "Smyth").
    static func soundex(_ s: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let chars = Array(s.lowercased().filter { $0.isLetter })
        guard let first = chars.first else { return "" }
        var out = String(first).uppercased()
        var last = codes[first]
        for ch in chars.dropFirst() {
            let code = codes[ch]
            if let code, code != last { out.append(code) }
            if ch != "h" && ch != "w" { last = code }
            if out.count == 4 { break }
        }
        return out.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}

/// Replaces spoken cues with saved text.
public struct SnippetExpander: Sendable {
    /// The switched-on snippets, longest cue first, each cue as its words in comparing form.
    let snippets: [(cueWords: [String], text: String)]

    public init(snippets: [Snippet]) {
        self.snippets = snippets.filter(\.enabled)
            .map { (Self.words($0.cue), $0.text) }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }  // longest cue first
    }

    /// A cue as the words it is matched by.
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { DictionaryCorrector.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// `text` with each spoken cue replaced by its saved text. Punctuation around the cue is kept.
    public func expand(_ text: String) -> String {
        guard !snippets.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (cue, replacement) in snippets {
            var i = 0
            while i + cue.count <= tokens.count {
                let span = tokens[i..<(i + cue.count)]
                if zip(span, cue).allSatisfy({ DictionaryCorrector.normalize($0) == $1 }) {
                    let lead = DictionaryCorrector.split(span.first!).lead
                    var trail = DictionaryCorrector.split(span.last!).trail
                    // A snippet that is the whole utterance, or ends in its own punctuation, takes no extra stop.
                    if cue.count == tokens.count || (replacement.last.map { ".!?\n".contains($0) } ?? false) {
                        trail = ""
                    }
                    tokens.replaceSubrange(i..<(i + cue.count), with: [lead + replacement + trail])
                }
                i += 1
            }
        }
        return tokens.joined(separator: " ")
    }
}

/// The full rule-based dictation pipeline: cleanup, then the user's dictionary, then snippets.
public struct DictationPipeline: Sendable {
    public let cleaner: TextCleaner
    public let corrector: DictionaryCorrector
    public let expander: SnippetExpander

    public init(profile: WritingProfile, dictionary: [DictionaryEntry], snippets: [Snippet]) {
        cleaner = TextCleaner(profile: profile)
        corrector = DictionaryCorrector(entries: dictionary)
        expander = SnippetExpander(snippets: snippets)
    }

    /// The pipeline as the user has it set up now.
    public init(engine: PersonalLanguage) throws {
        try self.init(profile: engine.profile(), dictionary: engine.dictionary(), snippets: engine.snippets())
    }

    /// Turns what the speech model heard into what goes on the page. `app` is where it is going.
    public func process(_ raw: String, app: AppKind = .other) -> String {
        MessageShape.apply(SpokenLists.format(expander.expand(corrector.correct(cleaner.clean(raw)))), for: app)
    }
}
