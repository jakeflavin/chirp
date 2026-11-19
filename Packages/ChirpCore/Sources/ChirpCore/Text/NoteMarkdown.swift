import Foundation

/// A note's Markdown, read for showing it formatted as it is typed: where the headings, lists, bold,
/// italics, code and code blocks are, and which characters are only marks (`#`, `**`, `` ` ``, fences).
///
/// The text stays Markdown and is styled in place by patterns, line by line; marks keep their place in the
/// text and are drawn faintly in the paragraph being edited and hidden elsewhere ("concealed syntax").
/// The view does the drawing; this only says where things are, in UTF-16 units as `NSString` counts them.
public enum NoteMarkdown {
    public enum Kind: Equatable, Sendable {
        /// A heading's words; 1 is the largest.
        case heading(Int)
        case bold
        case italic
        /// Code inside a line.
        case code
        /// A fenced block: from its opening fence to its closing one (or the end of the note).
        case codeBlock
        /// A list point's line. `depth` counts its indent in steps of two spaces (or a tab).
        case listItem(depth: Int)
        /// The "-", "*", "+" or "1." in front of a list point, with the space after it.
        case listMarker(bullet: Bool)
        /// A quoted line ("> ").
        case quote
        /// Characters that are only marks: drawn faintly where the cursor is, hidden elsewhere.
        case mark
        /// A fence line of a code block (```), hidden like a mark unless the cursor is in the block.
        case fence
    }

    public struct Span: Equatable, Sendable {
        public let kind: Kind
        public let range: NSRange

        public init(_ kind: Kind, _ range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    // MARK: Patterns

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})([ \\t]+)(.*?)[ \\t]*$", options: .anchorsMatchLines)
    private static let list = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d{1,3}[.)])([ \\t]+)", options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: "^(>[ \\t]?)", options: .anchorsMatchLines)
    private static let fence = try! NSRegularExpression(pattern: "^[ \\t]{0,3}(```|~~~)", options: .anchorsMatchLines)
    private static let codeSpan = try! NSRegularExpression(pattern: "(`+)(?!`)(.+?)(?<!`)\\1(?!`)", options: [])
    private static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", options: [])
    private static let italic = try! NSRegularExpression(pattern: "(?<![*_\\w])([*_])(?=\\S)(?!\\1)(.+?)(?<=\\S)\\1(?![*_\\w])", options: [])

    /// Every span in `text`, in the order they start. Inside a code block nothing else is looked for, and
    /// inside a code span neither bold nor italics are.
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var out: [Span] = []

        // Code blocks first: their lines are taken out of everything else.
        var blocks: [NSRange] = []
        var open: (start: Int, mark: String)?
        ns.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            guard let found = fence.firstMatch(in: text, range: line) else { return }
            let mark = ns.substring(with: found.range(at: 1))
            if let start = open {
                guard mark == start.mark else { return }
                let block = NSRange(location: start.start, length: NSMaxRange(line) - start.start)
                blocks.append(block)
                out.append(Span(.fence, line))
                open = nil
            } else {
                open = (line.location, mark)
                out.append(Span(.fence, line))
            }
            _ = enclosing
        }
        if let start = open {
            // Not closed yet: everything after the fence is code, as it is being typed.
            blocks.append(NSRange(location: start.start, length: ns.length - start.start))
        }
        for block in blocks { out.append(Span(.codeBlock, block)) }
        func inBlock(_ r: NSRange) -> Bool { blocks.contains { NSIntersectionRange($0, r).length > 0 || ($0.location <= r.location && r.location < NSMaxRange($0)) } }

        ns.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            guard line.length > 0, !inBlock(line) else { return }
            var body = line
            if let m = heading.firstMatch(in: text, range: line) {
                let level = m.range(at: 1).length
                out.append(Span(.mark, NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length + m.range(at: 2).length)))
                if m.range(at: 3).length > 0 { out.append(Span(.heading(level), m.range(at: 3))) }
                body = m.range(at: 3)
            } else if let m = list.firstMatch(in: text, range: line) {
                let indent = ns.substring(with: m.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
                let symbol = ns.substring(with: m.range(at: 2))
                let marker = NSRange(location: m.range(at: 2).location, length: m.range(at: 2).length + m.range(at: 3).length)
                out.append(Span(.listItem(depth: indent), line))
                out.append(Span(.listMarker(bullet: !symbol.first!.isNumber), marker))
                body = NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker))
            } else if let m = quote.firstMatch(in: text, range: line) {
                out.append(Span(.quote, line))
                out.append(Span(.mark, m.range(at: 1)))
                body = NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(line) - NSMaxRange(m.range(at: 1)))
            }
            guard body.length > 0 else { return }
            var codeRanges: [NSRange] = []
            for m in codeSpan.matches(in: text, range: body) {
                let marks = m.range(at: 1).length
                out.append(Span(.mark, NSRange(location: m.range.location, length: marks)))
                out.append(Span(.code, m.range(at: 2)))
                out.append(Span(.mark, NSRange(location: NSMaxRange(m.range) - marks, length: marks)))
                codeRanges.append(m.range)
            }
            func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
            var boldRanges: [NSRange] = []
            for m in bold.matches(in: text, range: body) where !inCode(m.range) {
                out.append(Span(.mark, m.range(at: 1)))
                out.append(Span(.bold, m.range(at: 2)))
                out.append(Span(.mark, NSRange(location: NSMaxRange(m.range) - 2, length: 2)))
                boldRanges.append(m.range)
            }
            for m in italic.matches(in: text, range: body) where !inCode(m.range) {
                // The single marks of a bold pair are not italics.
                if boldRanges.contains(where: { $0.location == m.range.location || NSMaxRange($0) == NSMaxRange(m.range) }) { continue }
                out.append(Span(.mark, m.range(at: 1)))
                out.append(Span(.italic, m.range(at: 2)))
                out.append(Span(.mark, NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
            }
        }
        return out.sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
    }

    /// The parts of a note that writing checks leave alone: code, code blocks and marks.
    public static func unchecked(in spans: [Span]) -> [NSRange] {
        spans.filter {
            switch $0.kind {
            case .code, .codeBlock, .mark, .fence, .listMarker: true
            default: false
            }
        }.map(\.range)
    }

    // MARK: Title and plain text

    /// A note's title: its first line with words in it, without marks, at most 80 characters. Nil for a
    /// note with no words yet.
    public static func title(_ markdown: String) -> String? {
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            var words = plainLine(line).trimmingCharacters(in: .whitespaces)
            if words.hasPrefix("• ") { words.removeFirst(2) }
            guard !words.isEmpty else { continue }
            guard words.count > 80 else { return words }
            // Cut at a word, never in the middle of one.
            let cut = words.prefix(80)
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 40 { return String(cut[..<space]) + "…" }
            return String(cut) + "…"
        }
        return nil
    }

    /// The note's words without marks, line for line: what search finds, what is read aloud and what a
    /// plain text export holds. Code keeps its text; fences go.
    public static func plain(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            out.append(inFence ? raw : plainLine(raw))
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line without its heading, quote or bold, italic and code marks. A list point keeps a bullet.
    static func plainLine(_ line: String) -> String {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var s = line
        if let m = heading.firstMatch(in: line, range: whole) {
            s = ns.substring(with: m.range(at: 3))
        } else if let m = list.firstMatch(in: line, range: whole) {
            let symbol = ns.substring(with: m.range(at: 2))
            let indent = ns.substring(with: m.range(at: 1))
            s = indent + (symbol.first!.isNumber ? symbol + " " : "• ") + ns.substring(from: NSMaxRange(m.range))
        } else if let m = quote.firstMatch(in: line, range: whole) {
            s = ns.substring(from: NSMaxRange(m.range))
        }
        for (pattern, keep) in [(codeSpan, 2), (bold, 2), (italic, 2)] {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = pattern.stringByReplacingMatches(in: s, range: range, withTemplate: "$\(keep)")
        }
        return s
    }

    /// The note as the plain words a voice note was saved with, made into Markdown: nothing to change,
    /// since plain sentences need no marks. Kept as one place to say so.
    public static func fromPlainText(_ text: String) -> String { text }
}
