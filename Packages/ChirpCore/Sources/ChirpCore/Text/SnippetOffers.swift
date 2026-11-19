import Foundation

/// Snippets where the user types.
///
/// A typed cue is offered like a writing fix: it is marked quietly, its card offers the saved text, and
/// ⌥⇥ and Fix all put it in. Nothing is replaced without the user accepting, so a cue that is also an
/// ordinary phrase is safe. This is not a text expander that watches keystrokes.
public enum SnippetOffers {
    /// The rule name of a snippet offer, so dismissing one is remembered like any other suggestion.
    public static let rule = "Snippet"

    /// A problem for each place a snippet's cue is typed in `text`: whole words, any capitals, the longest
    /// cue first, and never inside another offer.
    public static func issues(in text: String, snippets: [Snippet]) -> [WritingIssue] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let usable = snippets.filter { $0.enabled && !$0.cue.trimmingCharacters(in: .whitespaces).isEmpty && !$0.text.isEmpty }
            .sorted { $0.cue.count > $1.cue.count }
        var out: [WritingIssue] = []
        for snippet in usable {
            let cueWords = snippet.cue.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !cueWords.isEmpty,
                let regex = Patterns.regex("(?<![\\p{L}\\p{N}])" + cueWords.joined(separator: "[ \\t]+") + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
            else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range
                // The saved text already there ("my address" inside its own snippet's text) is not a cue.
                if ns.substring(with: range) == snippet.text { continue }
                if out.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                out.append(
                    WritingIssue(
                        start: range.location, end: NSMaxRange(range), rule: rule, kind: "Snippet",
                        message: "Your snippet “\(snippet.cue)”.", priority: 40,
                        suggestions: [Fix(kind: .replace, text: snippet.text)]))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Something said so often it is worth saving: the words, and how many times.
    public struct Repeat: Equatable, Sendable {
        public var text: String
        public var count: Int
    }

    /// The sentence dictated most often among `dictations` (the newest first or not, it does not matter),
    /// when it has been said at least `atLeast` times, is short enough to be a snippet, and is not one
    /// already. Nothing is suggested twice: `declined` holds what the user said "Not now" to.
    public static func repeated(dictations: [String], snippets: [Snippet], declined: Set<String> = [], atLeast: Int = 3) -> Repeat? {
        var counts: [String: (text: String, count: Int)] = [:]
        for raw in dictations {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = TextStats.words(text)
            guard words >= 2, words <= 40, text.count <= 300 else { continue }
            let key = Self.key(text)
            counts[key] = (counts[key]?.text ?? text, (counts[key]?.count ?? 0) + 1)
        }
        let saved = Set(snippets.map { key($0.text) })
        return counts.filter { $0.value.count >= atLeast && !saved.contains($0.key) && !declined.contains($0.key) }
            .max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
            .map { Repeat(text: $0.value.text, count: $0.value.count) }
    }

    /// A sentence as it is compared: lower case, no punctuation, single spaces.
    public static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).joined(separator: " ")
    }
}
