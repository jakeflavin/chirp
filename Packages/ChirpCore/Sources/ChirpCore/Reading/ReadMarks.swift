import Foundation

/// Where the sentence and the word being read are in the text they came from (a page or a text field in
/// another app), and whether the page should be moved to keep up.
///
/// The text that is read out is a tidied copy of the source: spaces collapsed, lines joined. So nothing
/// is placed by counting characters from the start of the page or even of the sentence: the sentence is
/// found again in the source, and then **each word is found again inside that sentence, in order**, and
/// marked only where it was found. A word that cannot be found is not marked; nothing is guessed, and a
/// miss cannot push the words after it out of place. (Readest's `computeWordOffsets` does the same with a
/// forward search from a cursor; Kokoro's own tokens keep the source spelling for the same reason.)
public enum ReadMarks {
    /// Looks for `wanted` in one stretch of `whole`: first exactly, then as the same words with any run
    /// of spaces or line breaks between them (only the first sixty words, which is enough to place it).
    /// Forwards it gives the first place, backwards the last. `exact` says which of the two ways matched.
    public static func find(_ wanted: String, in whole: String, range: NSRange, backwards: Bool) -> (range: NSRange, exact: Bool)? {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= (whole as NSString).length else { return nil }
        let options: NSString.CompareOptions = backwards ? [.backwards] : []
        let same = (whole as NSString).range(of: wanted, options: options, range: range)
        if same.location != NSNotFound { return (same, true) }
        let words = wanted.split(whereSeparator: { $0.isWhitespace || $0 == "\u{A0}" }).prefix(60).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let regex = Patterns.regex(words.joined(separator: #"[\s\x{A0}]+"#)) else { return nil }
        if backwards {
            guard let last = regex.matches(in: whole, range: range).last else { return nil }
            return (last.range, false)
        }
        let loose = regex.rangeOfFirstMatch(in: whole, range: range)
        return loose.location == NSNotFound ? nil : (loose, false)
    }

    /// Where each word of `sentence` (as read out; see `ReadingText.wordRanges`) sits in `whole`, looking
    /// only inside `found`, the place the sentence was found. One entry per word, nil for a word that is
    /// not there. Each word is looked for after the one before it, so the same word twice in a sentence
    /// is found twice, and never before a word already placed.
    public static func words(of sentence: String, in whole: String, found: NSRange) -> [NSRange?] {
        let source = whole as NSString
        let ns = sentence as NSString
        let end = min(NSMaxRange(found), source.length)
        var cursor = max(0, found.location)
        var out: [NSRange?] = []
        // A sixty-word match covers only the start of a long sentence: its later words are looked for a
        // little past the end of what matched.
        let reach = min(source.length, end + max(0, ns.length - found.length) + 64)
        for range in ReadingText.wordRanges(sentence) {
            let word = ns.substring(with: range)
            guard cursor < reach else {
                out.append(nil)
                continue
            }
            let hit = source.range(of: word, options: [], range: NSRange(location: cursor, length: reach - cursor))
            // The next word must come straight after: only spaces may lie between. Anything else between
            // them means this is the same word further on, not this one.
            if hit.location != NSNotFound, onlySpace(source, from: cursor, to: hit.location) {
                out.append(hit)
                cursor = NSMaxRange(hit)
            } else {
                out.append(nil)
                // Step over what stands where the word should be, so the words after it can still be placed.
                var skip = cursor
                while skip < reach, isSpace(source.character(at: skip)) { skip += 1 }
                while skip < reach, !isSpace(source.character(at: skip)) { skip += 1 }
                cursor = skip
            }
        }
        return out
    }

    /// A range in a piece of text, moved to where the same words are in the text the app itself counts
    /// by. Some apps hand over a piece's text one way and count its characters another (spaces the page
    /// does not draw, say), so a place worked out in the first lands a few characters off in the second:
    /// the mark then covers the end of one word and the start of the next. `expected` is the words the
    /// range should cover, `at` where they were worked out to be, and `counted` the piece's text as the
    /// app counts it. Nil when the words are not there at all; the mark is then left out.
    public static func settled(_ expected: String, at: NSRange, in counted: String) -> NSRange? {
        let text = counted as NSString
        guard !expected.isEmpty, text.length > 0 else { return nil }
        if NSMaxRange(at) <= text.length, at.location >= 0, text.substring(with: at) == expected { return at }
        // The nearest place the same words are, looking both ways from where they were expected.
        var best: NSRange?
        var from = 0
        while from < text.length {
            let hit = text.range(of: expected, options: [], range: NSRange(location: from, length: text.length - from))
            if hit.location == NSNotFound { break }
            if best == nil || abs(hit.location - at.location) < abs(best!.location - at.location) { best = hit }
            if hit.location > at.location { break }
            from = hit.location + 1
        }
        // Far from where it should be, it is another use of the word, not this one.
        guard let best, abs(best.location - at.location) <= max(24, at.location / 8) else { return nil }
        return best
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 || c == 13 || c == 0xA0 }

    private static func onlySpace(_ text: NSString, from: Int, to: Int) -> Bool {
        guard to >= from else { return false }
        for i in from..<to where !isSpace(text.character(at: i)) { return false }
        return true
    }
}

/// Whether the page is moved to keep the sentence being read in view.
///
/// The reader scrolling away to look at something else stops it; scrolling back starts it again. What
/// must not stop it is Chirp's own request not having worked yet: a page with a picture between two
/// paragraphs takes longer to move (the picture is still loading, the page scrolls smoothly, or the
/// request stops short), and the sentence is then out of view through no doing of the reader's. So
/// "scrolled away" is only said of a sentence that **was in view and no longer is**. One that has not
/// been in view since reading reached it is asked for again, up to three times, and the next sentence
/// still gets its turn, so a picture in the page does not stop the following for good.
public struct ReadFollow: Sendable, Equatable {
    /// True while the page follows the reading.
    public private(set) var following = true
    /// The sentence being read has been in view since reading reached it.
    public private(set) var seen = false
    /// How often the page has been asked to move to it.
    public private(set) var asked = 0
    /// How long a request is given before the page is looked at again, in seconds.
    public static let settle = 0.6
    public static let mostRequests = 3

    public init() {}

    /// Reading reached a new sentence. Returns true when the page should be asked to move to it.
    public mutating func reached(inView: Bool) -> Bool {
        seen = inView
        asked = 0
        guard !inView, following else { return false }
        asked = 1
        return true
    }

    /// A look at the page between sentences. `sinceRequest` is how long ago the page was last asked to
    /// move. Returns true when it should be asked again.
    public mutating func looked(inView: Bool, sinceRequest: Double) -> Bool {
        if inView {
            seen = true
            following = true
            return false
        }
        guard sinceRequest > Self.settle else { return false }
        if seen {
            // It was in view and is not now: the reader moved the page.
            following = false
            return false
        }
        guard following, asked < Self.mostRequests else { return false }
        asked += 1
        return true
    }
}

/// Whether the box another app gives for the word being spoken is really around that word.
/// In Safari the mark was seen on "verfl" in "Overflow": the box started a letter
/// late and stopped short. The lead is a ligature or web font whose per-range boxes do not match the
/// characters. The box of the whole word is asked for in one go (not letter by letter) and checked against
/// the words beside it and the width the word should have on its line; a box that fails is not drawn,
/// so the sentence mark stays and no word is marked wrongly.
public enum WordBox {
    public enum Verdict: String, Sendable, Equatable {
        case ok
        /// Begins well past where the word before it ends: the first letters are missing.
        case startsInside
        /// Ends well before the next word starts: the last letters are missing.
        case stopsShort
        /// Much narrower than the word's letters take on this line.
        case tooNarrow
        /// Runs into the next word, or back into the one before.
        case overlaps
        /// No box at all, or one that is not a box.
        case missing
    }

    /// The word's box and what was found about it.
    public struct Result: Sendable, Equatable {
        public var box: CGRect?
        public var verdict: Verdict
        /// The neighbours' boxes and the box of the three words together, for the log.
        public var previous: CGRect?
        public var next: CGRect?
        public var span: CGRect?
    }

    /// Asks `boxes` (the app; a fake in tests) for the word at `place` among `words` (ranges in the app's
    /// text, nil for a word not found there), for the word before and after it, and for the three as one
    /// range. Each answer is one box per line. Only boxes on the word's own line are compared.
    public static func check(place: Int, words: [NSRange?], boxes: (NSRange) -> [CGRect]) -> Result {
        guard words.indices.contains(place), let range = words[place], range.length > 0 else { return Result(box: nil, verdict: .missing) }
        let found = boxes(range)
        guard found.count == 1, let box = found.first, box.width > 1, box.height > 1 else {
            // A word that wraps onto the next line (a hyphenated word) is drawn as the app gives it.
            return Result(box: found.first, verdict: found.count > 1 ? .ok : .missing)
        }
        func neighbour(_ i: Int) -> (range: NSRange, box: CGRect)? {
            guard words.indices.contains(i), let r = words[i], r.length > 0 else { return nil }
            let b = boxes(r)
            guard b.count == 1, let one = b.first, sameLine(one, box) else { return nil }
            return (r, one)
        }
        let before = neighbour(place - 1)
        let after = neighbour(place + 1)
        var result = Result(box: box, verdict: .ok, previous: before?.box, next: after?.box)
        // How wide a character is on this line, from the three words taken as one range.
        let first = before?.range ?? range
        let last = after?.range ?? range
        let spanRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var perCharacter: CGFloat?
        let spanBoxes = spanRange != range ? boxes(spanRange) : []
        if spanBoxes.count == 1, let span = spanBoxes.first, sameLine(span, box) {
            result.span = span
            perCharacter = span.width / CGFloat(spanRange.length)
        }
        // A gap is only this word's fault when the word on that side is not itself too narrow: the box of
        // "Stack" is fine even though the box of "Overflow" beside it is not.
        func narrow(_ n: (range: NSRange, box: CGRect)?) -> Bool {
            guard let n, let perCharacter else { return false }
            return verdict(box: n.box, length: n.range.length, previous: nil, next: nil, perCharacter: perCharacter) == .tooNarrow
        }
        result.verdict = verdict(
            box: box, length: range.length, previous: narrow(before) ? nil : before?.box, next: narrow(after) ? nil : after?.box,
            perCharacter: perCharacter)
        return result
    }

    /// The rules, on boxes alone. A space is about a quarter of the line's height; a gap of more than
    /// 0.6 of the height between two words on one line (a space and a wide letter) means letters were
    /// left out of the box. Justified lines with very wide spaces can fail this too: the word mark is
    /// then left off, which is the safe way to be wrong.
    public static func verdict(box: CGRect, length: Int, previous: CGRect?, next: CGRect?, perCharacter: CGFloat?) -> Verdict {
        let gap = box.height * 0.6
        if let previous {
            if previous.maxX > box.minX + 1.5 { return .overlaps }
            if box.minX - previous.maxX > gap { return .startsInside }
        }
        if let next {
            if box.maxX > next.minX + 1.5 { return .overlaps }
            if next.minX - box.maxX > gap { return .stopsShort }
        }
        // Proportional letters vary ("illicit" against "WWW"), so only a box far narrower than its
        // letters' share of the line is taken as wrong.
        if let perCharacter, length >= 3, box.width < CGFloat(length) * perCharacter * 0.7 { return .tooNarrow }
        return .ok
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < min(a.height, b.height) / 2
    }
}
