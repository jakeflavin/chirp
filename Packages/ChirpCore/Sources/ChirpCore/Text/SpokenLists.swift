import Foundation

/// Turns a list said out loud into a list on the page.
///
/// Numbered: "One, test dictation. Two, call Sam." / "First, … Second, …" / "Number one … number two …" /
/// "1 finish the report, 2 email Sam, 3 go for a run" become "1. …" lines. "Step one … step two …" keeps
/// its wording and gets one step per line. Bulleted: "Bullet point milk, bullet point eggs" becomes
/// "- Milk" and "- Eggs".
///
/// A list is only made when the markers count up in order from one and there are at least two of them
/// (three for bare numbers), each at the start of a clause, so "one of them is late" or "at 2, not at 3"
/// is left alone.
public enum SpokenLists {
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// The start of the text, a new line, or the space after a mark that ends a clause.
    private static let clauseStart = #"(?:^|(?<=\n)|(?<=[.!?:;,]\s))"#

    /// As above, but not after a comma: where a list of bare numbers can begin. (This was a pattern
    /// run at one position, which always matched: a search that starts at a position treats it as the
    /// start of the text.)
    private static func startsSentence(_ ns: NSString, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let previous = ns.character(at: location - 1)
        if previous == 10 { return true }
        guard location > 1, let space = Unicode.Scalar(previous), CharacterSet.whitespacesAndNewlines.contains(space),
            let mark = Unicode.Scalar(ns.character(at: location - 2))
        else { return false }
        return ".!?:;".unicodeScalars.contains(mark)
    }

    /// One way of saying a numbered list out loud.
    private struct Style: Sendable {
        /// Matches one marker; group 1 is its number as a word or digits.
        var pattern: String
        /// The number words this style counts with, in order from one.
        var words: [String]
        /// How many markers it takes to be a list.
        var minimum: Int
        /// The first marker must start a sentence, not just follow a comma.
        var strictFirst = false
        /// What goes in front of item `n` on the page.
        var label: @Sendable (Int) -> String = { "\($0). " }
    }

    private static let styles: [Style] = [
        Style(pattern: clauseStart + #"step\s+(\d{1,2}|"# + cardinals.joined(separator: "|") + #")\b[.,:]?\s+"#,
              words: cardinals, minimum: 2, label: { "Step \($0). " }),
        Style(pattern: clauseStart + #"number\s+(\d{1,2}|"# + cardinals.joined(separator: "|") + #")\b[.,:]?\s+"#,
              words: cardinals, minimum: 2),
        Style(pattern: clauseStart + "(" + cardinals.joined(separator: "|") + #")\s*[,:.]\s+"#, words: cardinals, minimum: 2),
        Style(pattern: clauseStart + "(" + ordinals.joined(separator: "|") + #")\s*[,:.]\s+"#, words: ordinals, minimum: 2),
        Style(pattern: clauseStart + #"(\d{1,2})[.,:)]?\s+(?=\p{L})"#, words: cardinals, minimum: 3, strictFirst: true),
    ]

    /// `text` with a spoken list laid out as one, or unchanged when it holds none. The first numbered
    /// style that fits wins; bullets inside the result are still laid out.
    public static func format(_ text: String) -> String {
        for style in styles {
            if let out = numbered(text, style) { return bulleted(out) ?? out }
        }
        return bulleted(text) ?? text
    }

    /// The number a marker stands for: its digits, or its place among the style's number words.
    private static func value(_ token: String, _ words: [String]) -> Int? {
        if let n = Int(token) { return n }
        return words.firstIndex(of: token.lowercased()).map { $0 + 1 }
    }

    /// The text as a numbered list in one style, or nil when it does not hold one.
    private static func numbered(_ text: String, _ style: Style) -> String? {
        let ns = text as NSString
        guard let regex = Patterns.regex(style.pattern, options: [.caseInsensitive]) else { return nil }
        // Keep the markers that count upward from one without a gap.
        var markers: [NSTextCheckingResult] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard value(ns.substring(with: match.range(at: 1)), style.words) == markers.count + 1 else { continue }
            if markers.isEmpty, style.strictFirst, !startsSentence(ns, at: match.range.location) { continue }
            markers.append(match)
        }
        guard markers.count >= style.minimum else { return nil }
        let items = pieces(ns, markers)
        guard !items.contains(where: \.isEmpty) else { return nil }
        return assemble(lead: ns.substring(to: markers[0].range.location), items: items, label: style.label)
    }

    private static let bulletPattern = clauseStart + #"(?:bullet point|next bullet|new bullet|bullet)(?!s)\b[,:.]?\s+"#

    private static let bulletRegex = try! NSRegularExpression(pattern: bulletPattern, options: [.caseInsensitive])

    /// The text as a bulleted list, or nil when "bullet" is not said at least twice as a marker.
    private static func bulleted(_ text: String) -> String? {
        let ns = text as NSString
        let regex = bulletRegex
        let markers = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard markers.count >= 2 else { return nil }
        let items = pieces(ns, markers)
        guard !items.contains(where: \.isEmpty) else { return nil }
        return assemble(lead: ns.substring(to: markers[0].range.location), items: items, label: { _ in "- " })
    }

    /// The text after each marker, up to the next one.
    private static func pieces(_ ns: NSString, _ markers: [NSTextCheckingResult]) -> [String] {
        markers.enumerated().map { i, marker in
            let from = marker.range.location + marker.range.length
            let to = i + 1 < markers.count ? markers[i + 1].range.location : ns.length
            var item = ns.substring(with: NSRange(location: from, length: to - from)).trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = item.last, ",;".contains(last) { item.removeLast() }
            return item
        }
    }

    /// The list on the page: what was said before it on its own line, then one labelled line per item.
    private static func assemble(lead: String, items: [String], label: (Int) -> String) -> String {
        // Items said as one comma-separated sentence end without a full stop except the last: drop that one too.
        let unfinished = items.contains { item in !(item.last.map { ".!?".contains($0) } ?? false) }
        var lines: [String] = []
        var lead = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        if lead.hasSuffix(",") { lead = String(lead.dropLast()) + ":" }
        if !lead.isEmpty { lines.append(lead) }
        for (i, raw) in items.enumerated() {
            var item = raw
            if unfinished, item.hasSuffix(".") { item.removeLast() }
            lines.append(label(i + 1) + item.prefix(1).uppercased() + item.dropFirst())
        }
        return lines.joined(separator: "\n")
    }
}
