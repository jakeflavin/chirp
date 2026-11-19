import Foundation

/// When one spoken word (one space-separated group of the voice's phonemes) is said, in seconds from
/// the start of the sentence's audio.
public struct SpokenSpan: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Works out when each word on the page is spoken, from the lengths the voice model itself gave every
/// sound. The same sums as Kokoro's own pipeline (`KPipeline.join_timestamps`): times are counted from
/// the start of the audio, the silence before the first word is left out of it, and the gap between two
/// words is shared between them.
public enum WordTiming {
    /// The voice model works in frames of 25 ms (600 samples at 24 kHz).
    public static let framesPerSecond = 40.0
    /// Kokoro's pipeline starts the first word this many frames before the opening silence ends.
    static let leadFrames = 3.0

    /// When each space-separated group of `phonemes` is spoken. `durations` is the model's length for
    /// every sound in frames, with one more at each end for its start and end marks. Nil when the two do
    /// not line up (a sound the model has no symbol for, or a sentence made in several pieces).
    public static func spans(phonemes: String, durations: [Int32]) -> [SpokenSpan]? {
        let scalars = Array(phonemes.unicodeScalars)
        guard !scalars.isEmpty, durations.count == scalars.count + 2 else { return nil }
        var spans: [SpokenSpan] = []
        // Frames so far, and where the word now being read began.
        var cursor = max(0, Double(durations[0]) - leadFrames)
        var wordStart = cursor
        var hasWord = false
        for (i, scalar) in scalars.enumerated() {
            let d = Double(durations[i + 1])
            if scalar == " " {
                // Half the gap belongs to the word before it and half to the word after.
                let boundary = cursor + d / 2
                if hasWord { spans.append(SpokenSpan(start: wordStart / framesPerSecond, end: boundary / framesPerSecond)) }
                cursor += d
                wordStart = boundary
                hasWord = false
            } else {
                cursor += d
                // A mark the voice keeps apart from its word (an opening quotation mark at the start of a
                // sentence comes out as a group of its own: “ wˈAt,”) is not a word. Counted as one, the
                // groups were one more than the words, no word could take the extra, and the whole sentence
                // fell back to times shared out by length: 0.6 s out on average, a second at worst.
                if !marks.contains(scalar) { hasWord = true }
            }
        }
        if hasWord { spans.append(SpokenSpan(start: wordStart / framesPerSecond, end: cursor / framesPerSecond)) }
        return spans.isEmpty ? nil : spans
    }

    /// Marks that are not sounds: a group made only of these is not a spoken word.
    static let marks: Set<Unicode.Scalar> = ["“", "”", "\"", "'", "‘", "’", "(", ")", "[", "]", ".", ",", ";", ":", "!", "?", "—", "–", "-", "…", "«", "»"]

    /// When each word of `sentence` (as shown) is spoken.
    ///
    /// `spokenText` is what the voice was really given after numbers and symbols were written out
    /// ("$45" became "forty five dollars"), and `spans` is when each of its words is said. Words that are
    /// the same on the page and in the spoken text are matched one to one; a stretch that differs (a
    /// number, a symbol, a name with its own pronunciation) shares the time its spoken words take.
    /// Nil when the spoken words cannot be lined up with their times.
    public static func wordTimings(sentence: String, spokenText: String, spans: [SpokenSpan]) -> [SpokenWord]? {
        let ranges = ReadingText.wordRanges(sentence)
        guard !ranges.isEmpty, !spans.isEmpty else { return nil }
        let ns = sentence as NSString
        let shown = ranges.map { key(ns.substring(with: $0)) }
        // A mark on its own ("—", "&") is not a word to the voice: it is said with the word before it or not at all.
        let spokenWords = spokenText.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty }
        guard let wordSpans = spansByWord(spokenWords, spans: spans) else { return nil }
        let spoken = spokenWords.map(key)

        // Longest run of words the two have in common, in order.
        let n = shown.count, m = spoken.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = !shown[i].isEmpty && shown[i] == spoken[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out = ranges.map { SpokenWord(range: $0, start: 0, end: 0) }
        // Gives the words shown from `a` up to `b` the time the spoken words from `c` up to `d` take.
        func share(_ a: Int, _ b: Int, _ c: Int, _ d: Int, at time: Double) {
            guard a < b else {
                // Words said that are not on the page: the word before them stays marked while they are said.
                if c < d, a > 0 { out[a - 1].end = wordSpans[d - 1].end }
                return
            }
            guard c < d else {
                // Words on the page that are not said (a citation mark, an aside that is skipped): no time.
                for i in a..<b { out[i].start = time; out[i].end = time }
                return
            }
            let from = wordSpans[c].start, to = wordSpans[d - 1].end
            let weights = (a..<b).map { Double(ranges[$0].length) + 1.5 }
            let total = weights.reduce(0, +)
            var t = from
            for (k, i) in (a..<b).enumerated() {
                let span = (to - from) * weights[k] / total
                out[i].start = t
                out[i].end = t + span
                t += span
            }
        }
        var i = 0, j = 0, a = 0, c = 0
        while i < n, j < m {
            if !shown[i].isEmpty, shown[i] == spoken[j], table[i][j] == table[i + 1][j + 1] + 1 {
                share(a, i, c, j, at: wordSpans[j].start)
                out[i].start = wordSpans[j].start
                out[i].end = wordSpans[j].end
                i += 1; j += 1
                a = i; c = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        share(a, n, c, m, at: c > 0 ? wordSpans[c - 1].end : wordSpans[0].start)
        // Times never go backwards, whatever the matching did.
        var last = 0.0
        for k in out.indices {
            out[k].start = max(out[k].start, last)
            out[k].end = max(out[k].end, out[k].start)
            last = out[k].end
        }
        return out
    }

    /// A word reduced to its letters and digits in lower case, so "Hello," and "hello" are the same word.
    static func key(_ word: String) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// One span for each spoken word. The voice says most words as one group of sounds, but spells out
    /// short runs of capitals letter by letter ("FBI" is three groups) and may say a hyphenated word part
    /// by part; when the counts differ, the words that can take more than one group are given theirs.
    /// Nil when no reading of the words adds up to the number of groups.
    static func spansByWord(_ words: [String], spans: [SpokenSpan]) -> [SpokenSpan]? {
        if words.count == spans.count { return spans }
        guard !words.isEmpty, spans.count > words.count else { return nil }
        // How many groups each word may be: one, or its letters or parts.
        let other: [Int] = words.map { word in
            let letters = word.filter { $0.isLetter || $0.isNumber }
            if (2...5).contains(letters.count), letters.count == word.filter({ !".,;:!?\"'()".contains($0) }).count,
                letters.allSatisfy({ $0.isASCII && $0.isUppercase }) { return letters.count }
            let parts = word.split(separator: "-", omittingEmptySubsequences: true).count
            return parts > 1 ? parts : 1
        }
        // reach[k][s]: words from k on can take exactly s groups.
        let target = spans.count
        var reach = [[Bool]](repeating: [Bool](repeating: false, count: target + 1), count: words.count + 1)
        reach[words.count][0] = true
        for k in stride(from: words.count - 1, through: 0, by: -1) {
            for s in 1...target {
                reach[k][s] = reach[k + 1][s - 1] || (other[k] > 1 && s >= other[k] && reach[k + 1][s - other[k]])
            }
        }
        guard reach[0][target] else { return nil }
        var out: [SpokenSpan] = []
        var left = target, at = 0
        for k in words.indices {
            // The spelled-out reading first: a run of capitals is far more often spelled than said as a word.
            let take = other[k] > 1 && left >= other[k] && reach[k + 1][left - other[k]] ? other[k] : 1
            out.append(SpokenSpan(start: spans[at].start, end: spans[at + take - 1].end))
            at += take
            left -= take
        }
        return out
    }
}
