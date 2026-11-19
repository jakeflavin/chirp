import Foundation

/// Splits the Markdown a language model writes (summaries, notes) into lines to draw: headings, list
/// points and plain paragraphs. Bold and italics inside a line are left for the view to style.
public enum MarkdownLines {
    public enum Kind: Equatable, Sendable {
        /// A heading; 1 is the largest.
        case heading(Int)
        /// A list point. `marker` is "•" for a bullet, or the number as written ("2.").
        case point(marker: String, depth: Int)
        case text
        /// A fenced block of code or commands. The line's text is the whole block, its line breaks kept.
        case code
    }

    public struct Line: Equatable, Sendable {
        public let kind: Kind
        /// The line's words, without the heading or list mark in front.
        public let text: String
    }

    /// The lines of `markdown`, in order. Blank lines and rules ("---") are dropped; a line that is only
    /// bold ("**Key points**") counts as a heading, which is how models often write one.
    public static func parse(_ markdown: String) -> [Line] {
        var out: [Line] = []
        // Inside a fence: the mark that opened it and the lines so far.
        var fence: (mark: String, lines: [String])?
        func closeFence() {
            guard let open = fence else { return }
            fence = nil
            var lines = open.lines
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if !lines.isEmpty { out.append(Line(kind: .code, text: lines.joined(separator: "\n"))) }
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                // The same mark again, alone on its line, ends the block.
                if line.hasPrefix(open.mark), line.allSatisfy({ $0 == open.mark.first }) { closeFence() } else { fence?.lines.append(raw) }
                continue
            }
            if let mark = fenceMark(line) {
                fence = (mark, [])
                continue
            }
            if line.isEmpty || isRule(line) { continue }
            if let (level, rest) = heading(line) {
                out.append(Line(kind: .heading(level), text: rest))
            } else if let (marker, rest) = point(line) {
                out.append(Line(kind: .point(marker: marker, depth: indent / 2), text: rest))
            } else if let title = boldOnly(line) {
                out.append(Line(kind: .heading(3), text: title))
            } else {
                out.append(Line(kind: .text, text: line))
            }
        }
        // A fence the model never closed still ends: what followed it is the block.
        closeFence()
        return out
    }

    /// The fence a line opens ("```" or "~~~", three or more, with an optional language after), or nil.
    static func fenceMark(_ line: String) -> String? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            let rest = line.drop { $0 == mark.first }
            // "```swift" opens a block; "```code``` in a sentence" does not.
            if !rest.contains(mark.first!) { return mark }
        }
        return nil
    }

    /// The same text as plain words, one line per heading, point or paragraph, for reading aloud or
    /// showing where Markdown is not drawn. Bold, italic and code marks are removed.
    public static func plain(_ markdown: String) -> String {
        parse(markdown).map { line in
            // Code is given as it is written: its marks are part of it.
            if line.kind == .code { return line.text }
            var text = line.text
            for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
            text = text.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+)(?<=\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
            if case .point(let marker, _) = line.kind, marker != "•" { return "\(marker) \(text)" }
            return text
        }.joined(separator: "\n")
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let rest = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        // "## **Title**" is still just the title.
        return rest.isEmpty ? nil : (hashes, boldOnly(rest) ?? rest)
    }

    private static func point(_ line: String) -> (String, String)? {
        if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
            var rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Task boxes ("- [ ] Call Sam") lose the box.
            for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) { rest = String(rest.dropFirst(box.count)) }
            return rest.isEmpty ? nil : ("•", rest)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        let rest = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : ("\(digits).", rest)
    }

    /// The words of a line that is nothing but one bold run, with an optional colon after it.
    private static func boldOnly(_ line: String) -> String? {
        var body = line
        if body.hasSuffix(":") { body.removeLast() }
        for mark in ["**", "__"] where body.hasPrefix(mark) && body.hasSuffix(mark) && body.count > 4 {
            let inner = String(body.dropFirst(2).dropLast(2))
            // The colon is as often inside the bold ("**Key points:**") as after it.
            if !inner.contains(mark) { return inner.trimmingCharacters(in: CharacterSet(charactersIn: " :")) }
        }
        return nil
    }
}
