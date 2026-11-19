import Foundation

/// How a document's text is laid out for reading: which stretch is a heading, a list point, a quote or
/// a table row, where the bold, italic and linked words are, and where its pictures sit.
///
/// The layout never holds the words themselves. Every block and span is a range (UTF-16, as the
/// reading position is) into the document's text, the same text that is read aloud, so the sentence
/// and word being spoken can be marked on the laid-out page.
public struct DocLayout: Codable, Sendable, Equatable {
    public struct Span: Codable, Sendable, Equatable {
        public enum Style: String, Codable, Sendable { case bold, italic, code, link }
        public var start: Int
        public var length: Int
        public var style: Style
        /// Where a link goes.
        public var url: String?

        public init(start: Int, length: Int, style: Style, url: String? = nil) {
            self.start = start
            self.length = length
            self.style = style
            self.url = url
        }
    }

    public struct Block: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case paragraph, heading, subheading, bullet, numbered, quote, tableHead, tableRow, image, code
        }
        public var kind: Kind
        /// Where the block's words are in the text. A picture has no words: its range is empty and marks its place.
        public var start: Int
        public var length: Int
        public var spans: [Span]
        /// For a picture: its file in the document's folder (or, until it has been fetched, its address).
        public var image: String?
        /// For a picture: the words under it, or what it shows.
        public var caption: String?
        /// For a numbered point: the number as written ("2.").
        public var marker: String?
        /// For a table row: where each cell's words are.
        public var cells: [Cell]?

        public var id: String { "\(kind.rawValue)-\(start)-\(image ?? "")" }
        public var end: Int { start + length }

        public init(
            kind: Kind, start: Int, length: Int, spans: [Span] = [], image: String? = nil, caption: String? = nil,
            marker: String? = nil, cells: [Cell]? = nil
        ) {
            self.kind = kind
            self.start = start
            self.length = length
            self.spans = spans
            self.image = image
            self.caption = caption
            self.marker = marker
            self.cells = cells
        }
    }

    public struct Cell: Codable, Sendable, Equatable {
        public var start: Int
        public var length: Int
        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    public var blocks: [Block]

    public init(blocks: [Block] = []) { self.blocks = blocks }

    /// The layout kept as JSON, or nil for text that is not one.
    public init?(json: String) {
        guard !json.isEmpty, let data = json.data(using: .utf8), let read = try? JSONDecoder().decode(DocLayout.self, from: data) else { return nil }
        self = read
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// True when every block and span lies inside a text of this length: a layout is only used with the
    /// text it was made from.
    public func fits(length: Int) -> Bool {
        blocks.allSatisfy { b in
            b.start >= 0 && b.length >= 0 && b.end <= length
                && b.spans.allSatisfy { $0.start >= b.start && $0.length >= 0 && $0.start + $0.length <= b.end }
                && (b.cells ?? []).allSatisfy { $0.start >= 0 && $0.length >= 0 && $0.start + $0.length <= b.end }
        }
    }

    /// The sentences that lie in a stretch of the text: those that overlap `start ..< start + length`.
    /// `sentences` are in order, as `ReadingText.sentences` gives them.
    public static func sentences(in start: Int, length: Int, of sentences: [ReadingSentence]) -> Range<Int> {
        guard length > 0, !sentences.isEmpty else { return 0..<0 }
        // The first sentence that ends after the stretch starts.
        var low = 0, high = sentences.count
        while low < high {
            let mid = (low + high) / 2
            if sentences[mid].offset + sentences[mid].length <= start { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sentences.count, sentences[end].offset < start + length { end += 1 }
        return low..<end
    }

    // MARK: From plain text

    /// A layout for text that came with none: a document saved before layouts were kept, a PDF's text,
    /// pasted text. Headings, list points, quotes, tables and code are told from how the lines are written.
    public static func plain(_ text: String) -> DocLayout {
        let ns = text as NSString
        var paragraphs: [NSRange] = []
        var at = 0
        // Paragraphs are separated by a blank line; a fenced block of code is one paragraph whatever is in it.
        while at < ns.length {
            let found = ns.range(of: "\n\n", range: NSRange(location: at, length: ns.length - at))
            var end = found.location == NSNotFound ? ns.length : found.location
            let piece = ns.substring(with: NSRange(location: at, length: end - at))
            if piece.hasPrefix("```"), !(piece.count > 3 && piece.hasSuffix("```") && piece.contains("\n")) {
                let close = ns.range(of: "\n```", range: NSRange(location: min(at + 3, ns.length), length: ns.length - min(at + 3, ns.length)))
                if close.location != NSNotFound { end = NSMaxRange(close) }
            }
            if end > at { paragraphs.append(NSRange(location: at, length: end - at)) }
            at = end
            while at < ns.length, ns.character(at: at) == 10 { at += 1 }
        }
        var blocks: [Block] = []
        for (n, range) in paragraphs.enumerated() {
            let para = ns.substring(with: range)
            // A paragraph may still hold several lines (table rows, list points written one under another).
            var lineStart = range.location
            let lines = para.hasPrefix("```") ? [para] : para.components(separatedBy: "\n")
            for (l, line) in lines.enumerated() {
                let length = (line as NSString).length
                defer { lineStart += length + 1 }
                let lead = (line.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let trimmedLength = (trimmed as NSString).length
                guard trimmedLength > 0 else { continue }
                let start = lineStart + lead
                func block(_ kind: Block.Kind, skip: Int, marker: String? = nil) -> Block {
                    // The mark in front ("## ", "- ") and the spaces after it are not part of the words.
                    var skip = skip
                    let t = trimmed as NSString
                    while skip < t.length, t.character(at: skip) == 32 { skip += 1 }
                    return Block(kind: kind, start: start + skip, length: trimmedLength - skip, marker: marker)
                }
                if trimmed.hasPrefix("```") {
                    // The fences are left out of what is shown.
                    let inner = (trimmed as NSString)
                    let first = inner.range(of: "\n")
                    let last = inner.range(of: "\n", options: .backwards)
                    if first.location != NSNotFound, last.location > first.location {
                        blocks.append(Block(kind: .code, start: start + first.location + 1, length: last.location - first.location - 1))
                    }
                    continue
                }
                if let cells = ReadingText.tableCells(line) {
                    // The rule under a heading row has no cells: the row above it is the heading row.
                    if cells.isEmpty {
                        if let last = blocks.indices.last, blocks[last].kind == .tableRow { blocks[last].kind = .tableHead }
                        continue
                    }
                    let first = cells[0], last = cells[cells.count - 1]
                    let from = lineStart + first.offset
                    let to = lineStart + last.offset + (last.text as NSString).length
                    blocks.append(Block(
                        kind: .tableRow, start: from, length: to - from,
                        cells: cells.map { Cell(start: lineStart + $0.offset, length: ($0.text as NSString).length) }))
                    continue
                }
                let hashes = trimmed.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                    blocks.append(block(hashes <= 2 ? .heading : .subheading, skip: hashes))
                } else if let first = trimmed.first, "-*•".contains(first), trimmed.dropFirst().first == " " {
                    blocks.append(block(.bullet, skip: 1))
                } else if trimmed.hasPrefix("> ") {
                    blocks.append(block(.quote, skip: 1))
                } else if let marker = numberMark(trimmed) {
                    blocks.append(block(.numbered, skip: marker.count, marker: marker))
                } else if lines.count == 1, l == 0, n + 1 < paragraphs.count,
                    isBareHeading(trimmed, before: ns.substring(with: paragraphs[n + 1]))
                {
                    blocks.append(block(n == 0 ? .heading : .subheading, skip: 0))
                } else {
                    blocks.append(block(.paragraph, skip: 0))
                }
            }
        }
        return DocLayout(blocks: blocks)
    }

    /// "12." or "3)" at the start of a line, when a space and words follow.
    private static func numberMark(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " ", after.count > 2 else { return nil }
        return "\(digits)\(mark)"
    }

    /// A short line of its own with no full stop, before a longer paragraph of prose: a heading as plain
    /// text gives it. Kept strict, because a wrong heading reads worse than a missed one.
    static func isBareHeading(_ line: String, before next: String) -> Bool {
        let nextLine = next.components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        guard line.count >= 3, line.count <= 70, line.split(separator: " ").count <= 10, nextLine.count >= line.count * 2, nextLine.count >= 60,
            let last = line.last, !".!?:;,…".contains(last), let lead = line.first, lead.isUppercase || lead.isNumber,
            !ReadingText.startsBlock(nextLine), !ReadingText.isTableRow(nextLine)
        else { return false }
        return true
    }

    // MARK: As Markdown

    /// The document as Markdown: for copying and exporting with its headings, lists, bold and links.
    public func markdown(_ text: String) -> String {
        let ns = text as NSString
        guard fits(length: ns.length) else { return text }
        var out: [String] = []
        // Rows of one table and points of one list go on following lines; everything else has a blank line between.
        var previous: Block.Kind?
        for block in blocks {
            var line: String
            switch block.kind {
            case .image:
                guard let caption = block.caption, !caption.isEmpty else { continue }
                line = "*\(caption)*"
            case .tableHead, .tableRow:
                let cells = (block.cells ?? []).map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
                line = "| " + cells.joined(separator: " | ") + " |"
                if block.kind == .tableHead { line += "\n|" + cells.map { _ in " --- |" }.joined() }
            case .code:
                line = "```\n" + ns.substring(with: NSRange(location: block.start, length: block.length)) + "\n```"
            default:
                let words = marked(block, in: ns)
                switch block.kind {
                case .heading: line = "## " + words
                case .subheading: line = "### " + words
                case .bullet: line = "- " + words
                case .numbered: line = (block.marker ?? "1.") + " " + words
                case .quote: line = "> " + words
                default: line = words
                }
            }
            let list: Set<Block.Kind> = [.bullet, .numbered], table: Set<Block.Kind> = [.tableHead, .tableRow]
            let joins = previous.map { (list.contains($0) && list.contains(block.kind)) || (table.contains($0) && table.contains(block.kind)) } ?? false
            if joins, let last = out.indices.last { out[last] += "\n" + line } else { out.append(line) }
            previous = block.kind
        }
        return out.joined(separator: "\n\n")
    }

    /// A block's words with its bold, italic, code and links written as Markdown.
    private func marked(_ block: Block, in ns: NSString) -> String {
        // Where a mark opens or closes, in the order they are met.
        var marks: [(at: Int, close: Bool, text: String)] = []
        for span in block.spans where span.length > 0 {
            let (open, close): (String, String)
            switch span.style {
            case .bold: (open, close) = ("**", "**")
            case .italic: (open, close) = ("*", "*")
            case .code: (open, close) = ("`", "`")
            case .link: (open, close) = ("[", "](\(span.url ?? ""))")
            }
            marks.append((span.start, false, open))
            marks.append((span.start + span.length, true, close))
        }
        // Closing marks before opening ones at the same place.
        marks.sort { ($0.at, $0.close ? 0 : 1) < ($1.at, $1.close ? 0 : 1) }
        var out = ""
        var at = block.start
        for mark in marks {
            out += ns.substring(with: NSRange(location: at, length: mark.at - at))
            out += mark.text
            at = mark.at
        }
        out += ns.substring(with: NSRange(location: at, length: block.end - at))
        return out
    }
}

/// Builds a document's text and its layout together, a block at a time, so the two always agree.
///
/// The text comes out as Chirp has always kept documents: paragraphs separated by a blank line, a list
/// point as "- words", a table row as "| a | b |". Reading aloud therefore reads it as before.
public struct DocBuilder: Sendable {
    /// A stretch of words in one style.
    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var link: String?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }
    }

    public private(set) var text = ""
    public private(set) var layout = DocLayout()
    private var length = 0

    public init() {}

    /// True when nothing with words has been added.
    public var isEmpty: Bool { !layout.blocks.contains { $0.kind != .image } }

    private mutating func write(_ s: String) {
        text += s
        length += (s as NSString).length
    }

    private mutating func separate() { if length > 0 { write("\n\n") } }

    /// Runs with their spaces tidied: runs of white space become one space, none at either end.
    private static func tidy(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        var endsWithSpace = true
        for run in runs {
            var text = ""
            for ch in run.text {
                if ch.isWhitespace || ch == "\u{00A0}" {
                    if !endsWithSpace { text.append(" ") }
                    endsWithSpace = true
                } else {
                    text.append(ch)
                    endsWithSpace = false
                }
            }
            guard !text.isEmpty else { continue }
            var r = run
            r.text = text
            out.append(r)
        }
        // The last space, if the words end on one.
        while let last = out.last, last.text.hasSuffix(" ") {
            out[out.count - 1].text.removeLast()
            if out[out.count - 1].text.isEmpty { out.removeLast() }
        }
        return out
    }

    /// Writes runs at the end of the text and returns their spans.
    private mutating func write(_ runs: [Run]) -> [DocLayout.Span] {
        var spans: [DocLayout.Span] = []
        func extend(_ style: DocLayout.Span.Style, url: String?, from start: Int, _ count: Int) {
            // A style carried from one run into the next is one span.
            if let i = spans.lastIndex(where: { $0.style == style }), spans[i].start + spans[i].length == start, spans[i].url == url {
                spans[i].length += count
            } else {
                spans.append(DocLayout.Span(start: start, length: count, style: style, url: url))
            }
        }
        for run in runs {
            let start = length
            write(run.text)
            let count = length - start
            if run.bold { extend(.bold, url: nil, from: start, count) }
            if run.italic { extend(.italic, url: nil, from: start, count) }
            if run.code { extend(.code, url: nil, from: start, count) }
            if let link = run.link, !link.isEmpty { extend(.link, url: link, from: start, count) }
        }
        return spans
    }

    /// Adds a block of words. Nothing is added when there are no words.
    public mutating func add(_ kind: DocLayout.Block.Kind, _ runs: [Run], marker: String? = nil) {
        let runs = Self.tidy(runs)
        guard !runs.isEmpty else { return }
        separate()
        switch kind {
        case .bullet: write("- ")
        case .numbered: write((marker ?? "1.") + " ")
        default: break
        }
        let start = length
        let spans = write(runs)
        layout.blocks.append(DocLayout.Block(kind: kind, start: start, length: length - start, spans: spans, marker: kind == .numbered ? (marker ?? "1.") : nil))
    }

    public mutating func add(_ kind: DocLayout.Block.Kind, _ words: String) { add(kind, [Run(words)]) }

    /// Adds a block of code, its lines kept as they are.
    public mutating func addCode(_ code: String) {
        let lines = code.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        var kept = lines
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        // A blank line inside would end the paragraph; a line with one space in it does not.
        let body = kept.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? " " : $0 }.joined(separator: "\n")
        guard !body.isEmpty else { return }
        separate()
        write("```\n")
        let start = length
        write(body)
        layout.blocks.append(DocLayout.Block(kind: .code, start: start, length: length - start))
        write("\n```")
    }

    /// Adds a table row, written with bars between its cells. Rows of one table follow each other.
    public mutating func addRow(_ cells: [[Run]], head: Bool) {
        var cells = cells.map(Self.tidy)
        // An empty cell keeps its column; empty ones at the end of a row are dropped.
        while let last = cells.last, last.isEmpty { cells.removeLast() }
        // One cell is not a row of a table: it is a line of words.
        guard cells.filter({ !$0.isEmpty }).count >= 2 else {
            if let only = cells.first(where: { !$0.isEmpty }) { add(.paragraph, only) }
            return
        }
        separate()
        var ranges: [DocLayout.Cell] = []
        var spans: [DocLayout.Span] = []
        write("|")
        for cell in cells {
            write(" ")
            let start = length
            spans += write(cell)
            ranges.append(DocLayout.Cell(start: start, length: length - start))
            write(" |")
        }
        let first = ranges.first { $0.length > 0 }!.start, last = ranges[ranges.count - 1]
        layout.blocks.append(DocLayout.Block(
            kind: head ? .tableHead : .tableRow, start: first, length: last.start + last.length - first, spans: spans, cells: ranges))
    }

    /// Adds a picture at this place. It has no words in the text.
    public mutating func addImage(_ source: String, caption: String = "") {
        let caption = caption.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // After the words before it: the mark sits at the end of the text so far.
        layout.blocks.append(DocLayout.Block(kind: .image, start: length, length: 0, image: source, caption: caption.isEmpty ? nil : caption))
    }

    /// Adds everything another builder holds, after what is here (a book's next chapter).
    public mutating func append(_ other: DocBuilder) {
        guard other.length > 0 || !other.layout.blocks.isEmpty else { return }
        separate()
        let shift = length
        write(other.text)
        for var block in other.layout.blocks {
            block.start += shift
            block.spans = block.spans.map { var s = $0; s.start += shift; return s }
            block.cells = block.cells?.map { DocLayout.Cell(start: $0.start + shift, length: $0.length) }
            layout.blocks.append(block)
        }
    }

    /// Changes each picture's source (to the file it was saved as), dropping those given nil.
    public mutating func mapImages(_ change: (String) -> String?) {
        layout.blocks = layout.blocks.compactMap { block in
            guard block.kind == .image, let source = block.image else { return block }
            guard let file = change(source) else { return nil }
            var b = block
            b.image = file
            return b
        }
    }
}
