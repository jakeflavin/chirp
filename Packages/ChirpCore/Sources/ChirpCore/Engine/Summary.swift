import Foundation

/// How a document is cut up to be summarized into its shape: a short overview,
/// then the document's own sections in its order, each shortened. Ads and boilerplate are taken out by rule
/// first (`Boilerplate`). A small model summarizes a short stretch well and a long one badly, so each section
/// is summarized on its own (the map step of LangChain's map-reduce summary, with the document's headings as
/// the pieces, as its Markdown header splitter cuts them), and the overview is written last from those notes
/// (the reduce step). Sections are never put together: every heading of the chosen level keeps its place.
public struct SummaryPlan: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var text: String
        /// How many sentences (or list items) to ask for.
        public var points: Int
        /// The part is mostly a list in the original, so its section is a list too.
        public var list = false
        /// The first block of code or commands in the part, kept word for word in its section.
        public var code: String?
        /// The original's own heading for this part's section. Nil when the model names it (a document
        /// without headings is cut into parts by length, and each is named).
        public var heading: String?
        /// 0 for a section, 1 for a section inside one (a long section's own sub-headings).
        public var depth = 0
        /// The part carries on the section of the part before it (a long section cut in pieces).
        public var continues = false
        /// The part is short enough that its own first sentences stand for it: no model step.
        public var extractive = false

        public init(text: String, points: Int, list: Bool = false, code: String? = nil, heading: String? = nil,
                    depth: Int = 0, continues: Bool = false, extractive: Bool = false) {
            self.text = text
            self.points = points
            self.list = list
            self.code = code
            self.heading = heading
            self.depth = depth
            self.continues = continues
            self.extractive = extractive
        }
    }

    public var parts: [Part]
    /// Long enough, or with headings enough, to be set out in sections after an overview. A short text without
    /// headings is a few sentences and nothing else.
    public var sectioned: Bool
    /// Characters in the document, after its ads and boilerplate were taken out.
    public var characters: Int
    /// Characters of ads and boilerplate taken out before the model saw the text.
    public var removed = 0

    /// Up to this length a text without headings is short: a few sentences, no sections.
    public static let shortLimit = 3000
    /// The size of a part of a long text without headings, and of the pieces a long section is cut into.
    public static let part = 2000
    /// A section longer than this is cut in pieces.
    static let splitAbove = 2600
    /// A section shorter than this (without its heading) is not given to the model: its own first sentences stand for it.
    /// 500 rather than 250: on the 26 test inputs it takes the time from 406 s to 323 s with one checklist point more
    /// and two wrong statements fewer.
    public static let extractBelow = 500
    /// The most points asked of a part (`points(for:)`). 4 measured best; fewer is only for speed trials.
    public static let mostPoints = 4
    /// A section longer than this with sub-headings of its own is shown as those sub-sections.
    static let nestAbove = 6000
    /// Past this many parts they grow instead, up to `biggestPart`; past that there are more parts. All of a document is
    /// always summarized, however long: the parts are
    /// written one batch at a time and nothing held grows with the length but the text and the finished points.
    public static let mostParts = 60
    public static let biggestPart = 9000
    static let openingLimit = 1500

    /// How many points to ask for, for a stretch of text this long: one for about every 700 characters, 1 to 4.
    public static func points(for characters: Int) -> Int { points(most: mostPoints, for: characters) }
    public static func points(most: Int, for characters: Int) -> Int { min(most, max(1, (characters + 399) / 700)) }

    /// The plan for summarizing `raw`: its ads and boilerplate taken out, then cut into parts.
    public static func make(for raw: String) -> SummaryPlan {
        let most = mostPoints, below = extractBelow
        let text = Boilerplate.strip(raw)
        let removed = max(0, raw.filter { !$0.isWhitespace }.count - text.filter { !$0.isWhitespace }.count)
        let paragraphs = Self.paragraphs(text)
        let total = paragraphs.reduce(0) { $0 + $1.count }
        var target = part
        if total > part * mostParts { target = min(biggestPart, total / mostParts + 1) }
        let size = paragraphs.reduce(0) { $0 + $1.count }
        var parts: [Part] = []
        func makePart(_ lines: [String], points: Int, heading: String?, depth: Int = 0, continues: Bool = false) -> Part {
            let items = lines.filter { ReadingText.startsBlock($0) && !ReadingText.isHeadingMark($0) }
            let size = lines.reduce(0) { $0 + $1.count }
            let list = items.count >= 3 && items.reduce(0) { $0 + $1.count } * 2 >= size
            // A command is kept where running it is the point: under a heading about installing or using.
            let code = !continues && heading.map(showsCode) == true ? code(in: lines) : nil
            return Part(text: lines.joined(separator: "\n\n"), points: list ? min(max(items.count, 3), 5) : points, list: list, code: code,
                        heading: heading, depth: depth, continues: continues)
        }
        var sectioned = true
        let sections = outline(paragraphs)
        if let outline = sections {
            // The original's own sections, one after another: each keeps its heading, so the summary lines up
            // with the original and none of its sections is passed over or put with another.
            for entry in outline {
                let body = entry.heading.isEmpty ? entry.lines : Array(entry.lines.dropFirst())
                let length = body.reduce(0) { $0 + $1.count }
                if entry.heading.isEmpty {
                    // The opening before the first heading, with the title. A long one is a section of its own,
                    // named by the model.
                    if length > openingLimit {
                        for (k, piece) in pieces(body).enumerated() { parts.append(makePart(piece, points: points(most: most, for: piece.joined().count), heading: nil, continues: k > 0)) }
                    }
                    continue
                }
                if body.isEmpty || length < below {
                    // Too short to need the model (or only the heading of the sub-sections that follow).
                    var short = makePart(entry.lines, points: 2, heading: entry.heading, depth: entry.depth)
                    short.extractive = true
                    short.text = body.joined(separator: "\n\n")
                    parts.append(short)
                    continue
                }
                for (k, piece) in pieces(body).enumerated() {
                    // The heading goes with the first piece, so the model knows what the section is about.
                    let lines = k == 0 ? [entry.lines[0]] + piece : piece
                    parts.append(makePart(lines, points: points(most: most, for: piece.reduce(0) { $0 + $1.count }), heading: entry.heading, depth: entry.depth, continues: k > 0))
                }
            }
        } else if paragraphs.isEmpty {
            sectioned = false
        } else if size <= shortLimit {
            // A short text: a few sentences on all of it, in one step.
            sectioned = false
            parts = [makePart(paragraphs, points: size < 600 ? 2 : size < 2000 ? 3 : 4, heading: "")]
        } else {
            // No headings: parts by length, each named by the model, in order.
            for piece in split(paragraphs, target: target) {
                parts.append(makePart(piece.paragraphs, points: points(most: most, for: piece.text.count), heading: nil))
            }
        }
        return SummaryPlan(parts: parts, sectioned: sectioned, characters: size, removed: removed)
    }

    /// A section's paragraphs as pieces of about a part each, or as one piece when it is not long.
    static func pieces(_ lines: [String]) -> [[String]] {
        lines.reduce(0) { $0 + $1.count } > splitAbove ? split(lines, target: part).map(\.paragraphs) : [lines]
    }

    /// The text's paragraphs, none much longer than a part: one that is gets cut at sentence ends (text
    /// that arrived as a single block has no other place to cut). A fenced block of code is one paragraph.
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var fence: [String]?
        for raw in text.components(separatedBy: .newlines) {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                fence?.append(p.hasPrefix("```") ? p : raw)
                if p.hasPrefix("```") {
                    out.append(fence!.joined(separator: "\n"))
                    fence = nil
                }
                continue
            }
            if p.hasPrefix("```") {
                fence = [p]
                continue
            }
            if p.isEmpty { continue }
            if p.count > 1500 { out.append(contentsOf: TextChunker.chunks(p, maxCharacters: 600)) } else { out.append(p) }
        }
        if let open = fence { out.append(contentsOf: open.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
        return out
    }

    /// Whether a section under this heading is about running something, so that its command is worth keeping.
    static func showsCode(_ heading: String) -> Bool {
        let h = heading.lowercased()
        return ["install", "usage", "using", "quick start", "quickstart", "getting started", "get started", "build", "setup", "set up",
                "example", "run", "command", "configur", "how to"].contains { h.contains($0) }
    }

    /// The most blocks of code a summary keeps, and the most lines of each.
    public static let codeBlocks = 3
    /// The most lines of a code block that a summary keeps.
    static let codeLines = 6

    /// The first fenced block among the paragraphs, without its fence marks, cut to a few lines.
    static func code(in paragraphs: [String]) -> String? {
        guard let block = paragraphs.first(where: { $0.hasPrefix("```") }) else { return nil }
        let lines = block.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return (lines.prefix(codeLines) + (lines.count > codeLines ? ["…"] : [])).joined(separator: "\n")
    }

    /// One section of the document as the summary will show it.
    public struct Entry: Equatable, Sendable {
        /// The original's heading; empty for the opening before the first heading.
        public var heading: String
        /// 0, or 1 for a sub-section of a long section.
        public var depth: Int
        /// The section's paragraphs, its heading first.
        public var lines: [String]
    }

    /// The document as its own headed sections, when it has at least three headings. The sections are the
    /// headings of the highest level that has more than one (a lone title above them is the title); a deeper
    /// heading stays inside its section, unless that section is long, when its sub-sections are shown as
    /// sections inside it. Whatever comes before the first heading is the opening, with an empty heading.
    public static func outline(_ paragraphs: [String]) -> [Entry]? {
        // Markdown says which lines are headings; other text is judged by its shape, except an email's.
        let marked = paragraphs.filter(ReadingText.isHeadingMark).count >= 3
        if !marked, isEmail(paragraphs), let thread = messages(paragraphs) { return thread }
        var flat: [(heading: String, level: Int, lines: [String])] = []
        for (i, p) in paragraphs.enumerated() {
            let isHeading = marked ? ReadingText.isHeadingMark(p) : isHeading(p, next: i + 1 < paragraphs.count ? paragraphs[i + 1] : nil)
            if isHeading, i > 0 {
                let level = marked ? p.prefix { $0 == "#" }.count : numberedLevel(p)
                // A heading straight after another of the same level (a kicker, then the story's own title) is part of it.
                if let last = flat.last, !last.heading.isEmpty, last.lines.count == 1, last.level == level {
                    flat[flat.count - 1].lines.append(p)
                } else {
                    flat.append((SummaryNotes.heading(p), level, [p]))
                }
            } else if flat.isEmpty {
                flat.append(("", 0, [p]))
            } else {
                flat[flat.count - 1].lines.append(p)
            }
        }
        let headed = flat.filter { !$0.heading.isEmpty }
        guard headed.count >= 3 else { return nil }
        // The level the sections are made at: the highest that has two or more headings.
        let levels = Dictionary(grouping: headed, by: \.level).mapValues(\.count)
        let top = levels.keys.sorted().first { levels[$0]! >= 2 } ?? levels.keys.min()!
        var tops: [(entry: (heading: String, level: Int, lines: [String]), children: [(heading: String, level: Int, lines: [String])])] = []
        var out: [Entry] = []
        for item in flat {
            if item.heading.isEmpty {
                out.append(Entry(heading: "", depth: 0, lines: item.lines))
            } else if item.level <= top || tops.isEmpty {
                tops.append((item, []))
            } else {
                tops[tops.count - 1].children.append(item)
            }
        }
        for (entry, children) in tops {
            let size = (entry.lines + children.flatMap(\.lines)).reduce(0) { $0 + $1.count }
            if size > nestAbove, children.count >= 2 {
                out.append(Entry(heading: entry.heading, depth: 0, lines: entry.lines))
                for child in children { out.append(Entry(heading: child.heading, depth: 1, lines: child.lines)) }
            } else {
                out.append(Entry(heading: entry.heading, depth: 0, lines: entry.lines + children.flatMap(\.lines)))
            }
        }
        return out.count <= mostParts ? out : nil
    }

    /// The level of a numbered heading ("2. Methods" is 2, "2.1 Study sites" is 3); 2 for any other.
    static func numberedLevel(_ line: String) -> Int {
        guard let match = line.range(of: #"^\d+(\.\d+)*\.?\s"#, options: .regularExpression) else { return 2 }
        return line[match].split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count + 1
    }

    /// A short line with no full stop, followed by something longer: a heading. A numbered one ("2.1 Study
    /// sites") is too; an email's header line ("From: …") and a list item are not.
    static func isHeading(_ line: String, next: String?) -> Bool {
        guard let next, line.count <= 80, next.count > line.count, let end = line.last, !".,;:!".contains(end) else { return false }
        // Not a line of code, a list item or a link on its own.
        if line.hasPrefix("```") || line.hasPrefix("$ ") || line.hasPrefix("[") || line.hasPrefix("http") { return false }
        if line.range(of: #"^(from|to|cc|bcc|subject|date|sent|reply-to):"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        // A rule ("-----") is not a heading, nor a newsletter story's title ("… (3 minute read)"), which is its first line.
        if !line.contains(where: \.isLetter) || isItemTitle(line) { return false }
        // A date or a byline over an article is not a section.
        if line.range(of: #"^(posted |written )?by \S"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if TextStats.words(line) <= 6,
            line.range(of: #"((jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? +\d{1,2}|\d{1,2}(st|nd|rd|th)? +(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|\d{4}[-/]\d{1,2}[-/]\d{1,2})"#, options: [.regularExpression, .caseInsensitive]) != nil
        { return false }
        if ReadingText.startsBlock(line), !ReadingText.isHeadingMark(line) {
            guard line.range(of: #"^\d+(\.\d+)*\.?\s"#, options: .regularExpression) != nil, TextStats.words(line) <= 8 else { return false }
        }
        return TextStats.words(line) <= 10
    }

    /// A newsletter story's title line: it ends with its reading time or its kind ("(3 minute read)", "(GitHub Repo)").
    static func isItemTitle(_ line: String) -> Bool {
        line.range(of: #"\((\d+\s*min(ute)?s?\s*read|github repo|website|podcast|video|sponsor)\)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the text is an email: its header lines are at the top. A thread's sections are its messages; a
    /// single message's headings are found as in any other text.
    static func isEmail(_ paragraphs: [String]) -> Bool {
        let top = paragraphs.prefix(8).map { $0.lowercased() }
        return top.contains { $0.hasPrefix("from:") } && top.contains { $0.hasPrefix("subject:") }
    }

    /// An email thread's own sections: its messages, in the order they are shown, each headed by its sender and day
    /// as its header lines give them ("Sofia Ramirez, November 16"). Nil for a single message.
    static func messages(_ paragraphs: [String]) -> [Entry]? {
        var out: [Entry] = []
        for p in paragraphs {
            if p.lowercased().hasPrefix("from:") {
                let name = p.dropFirst(5).trimmingCharacters(in: .whitespaces).components(separatedBy: "<")[0].trimmingCharacters(in: .whitespaces)
                out.append(Entry(heading: name.isEmpty ? "Message" : name, depth: 0, lines: [p]))
            } else if out.isEmpty {
                out.append(Entry(heading: "", depth: 0, lines: [p]))
            } else {
                if p.lowercased().hasPrefix("date:"), out[out.count - 1].lines.count <= 4, !out[out.count - 1].heading.isEmpty {
                    let day = p.dropFirst(5).components(separatedBy: " at ")[0].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
                    if !day.isEmpty { out[out.count - 1].heading += ", " + day }
                }
                out[out.count - 1].lines.append(p)
            }
        }
        return out.filter { !$0.heading.isEmpty }.count >= 2 ? out : nil
    }

    /// Cuts the paragraphs into parts of about `target` characters, all near the same size (so there is
    /// no stub at the end), starting a part at a heading when one is near the cut.
    static func split(_ paragraphs: [String], target: Int) -> [(text: String, headings: Int, paragraphs: [String])] {
        guard !paragraphs.isEmpty else { return [] }
        var starts: [Int] = []
        var position = 0
        for p in paragraphs {
            starts.append(position)
            position += p.count + 2
        }
        let total = position
        let count = max(1, (total + target - 1) / target)
        let size = Double(total) / Double(count)
        let headings = paragraphs.indices.map { isHeading(paragraphs[$0], next: $0 + 1 < paragraphs.count ? paragraphs[$0 + 1] : nil) }
        var cuts: [Int] = []
        if count > 1 {
            for k in 1..<count {
                let ideal = Double(k) * size
                var best: (score: Double, index: Int)?
                for i in 1..<paragraphs.count where i > (cuts.last ?? 0) {
                    let distance = abs(Double(starts[i]) - ideal)
                    if distance > size * 0.4 { continue }
                    // Any heading in reach beats a cut in the middle of a section.
                    let score = distance - (headings[i] ? size : 0)
                    if best == nil || score < best!.score { best = (score, i) }
                }
                if let best { cuts.append(best.index) }
            }
        }
        var out: [(text: String, headings: Int, paragraphs: [String])] = []
        var from = 0
        for cut in cuts + [paragraphs.count] where cut > from {
            out.append((paragraphs[from..<cut].joined(separator: "\n\n"), headings[from..<cut].filter { $0 }.count, Array(paragraphs[from..<cut])))
            from = cut
        }
        return out
    }

    /// The two halves of a part, for asking again in smaller pieces when the model made a mess of the whole.
    public static func halves(of text: String) -> [String] {
        let paragraphs = Self.paragraphs(text)
        let total = paragraphs.reduce(0) { $0 + $1.count + 2 }
        return split(paragraphs, target: max(total / 2 + 1, 200)).map(\.text)
    }
}

/// One section of a summary: a heading, then its sentences as a paragraph (or as a list, where the
/// original is one), then a block of code if the original had one. The heading is empty in a short
/// text's summary, which is a paragraph or two.
public struct SummarySection: Equatable, Sendable {
    public var heading: String
    public var points: [String]
    public var list: Bool
    public var code: String?
    /// 0 for a section, 1 for a sub-section of a long one.
    public var depth: Int

    public init(heading: String, points: [String], list: Bool = false, code: String? = nil, depth: Int = 0) {
        self.heading = heading
        self.points = points
        self.list = list
        self.code = code
        self.depth = depth
    }
}

/// Reads what the model wrote for one part, keeps it to size, and puts the finished summary together.
public enum SummaryNotes {
    /// The sections in a model's answer. With `cut` (the answer ran into its token limit) a last line
    /// that stops mid-sentence is dropped, so nothing unfinished is shown.
    public static func sections(from output: String, cut: Bool) -> [SummarySection] {
        var text = output
        if cut { text = withoutUnfinishedEnd(text) }
        var out: [SummarySection] = []
        for line in MarkdownLines.parse(text) {
            switch line.kind {
            case .heading:
                out.append(SummarySection(heading: heading(line.text), points: []))
            case .point:
                let point = tidy(line.text)
                if point.isEmpty { continue }
                if out.isEmpty { out.append(SummarySection(heading: "", points: [])) }
                out[out.count - 1].points.append(point)
            case .code:
                // Code is taken from the document itself, never from the model's copy of it.
                continue
            case .text:
                // A lead-in ("Here are the main points:") is not a point; a sentence the model wrote
                // without its bullet mark is.
                let words = TextStats.words(line.text)
                if words < 4 || line.text.hasSuffix(":") || isPreamble(line.text) { continue }
                if out.isEmpty { out.append(SummarySection(heading: "", points: [])) }
                out[out.count - 1].points.append(tidy(line.text))
            }
        }
        // A heading the answer stopped under, or one with nothing to say.
        return out.filter { !$0.points.isEmpty }
    }

    /// Whether an answer stops mid-sentence: its last line does not end the way a sentence does.
    public static func endsUnfinished(_ output: String) -> Bool {
        guard let last = output.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        guard let end = last.trimmingCharacters(in: .whitespaces).last(where: { !"*_`".contains($0) }) else { return true }
        return !".!?…”\"’')".contains(end)
    }

    /// The answer without a last line that stops mid-sentence.
    public static func withoutUnfinishedEnd(_ output: String) -> String {
        guard endsUnfinished(output) else { return output }
        var lines = output.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Keeps one part's notes to the size asked for, without losing any stretch of the part. One section
    /// with too many points keeps points spread evenly from first to last; several sections (the model
    /// followed the part's own headings) keep their first points, and more than four are joined in order.
    /// `list` and `code` are the part's: whether its section is a list, and the code that goes with it.
    public static func fitted(_ sections: [SummarySection], points: Int, headed: Bool, list: Bool = false, code: String? = nil) -> [SummarySection] {
        var sections = sections.map { SummarySection(heading: $0.heading, points: unique($0.points)) }.filter { !$0.points.isEmpty }
        guard !sections.isEmpty else { return [] }
        if !headed {
            sections = [SummarySection(heading: "", points: spread(sections.flatMap(\.points), keep: points + 1))]
        } else if sections.count == 1 {
            sections[0].points = spread(sections[0].points, keep: points + 1)
        } else {
            // The model followed the part's own sub-headings: one section, its points spread from first to last.
            sections = [SummarySection(heading: sections[0].heading, points: spread(sections.flatMap(\.points), keep: points + 1))]
        }
        for i in sections.indices { sections[i].list = list }
        sections[0].code = code
        return sections
    }

    /// `keep` of the points, chosen evenly from the first to the last.
    static func spread(_ points: [String], keep: Int) -> [String] {
        guard points.count > keep, keep > 0 else { return points }
        if keep == 1 { return [points[0]] }
        return (0..<keep).map { points[Int((Double($0) * Double(points.count - 1) / Double(keep - 1)).rounded())] }
    }

    static func unique(_ points: [String]) -> [String] {
        var seen = Set<String>()
        return points.filter { seen.insert($0.lowercased().filter { $0.isLetter || $0.isNumber }).inserted }
    }

    /// A stand-in for a part the model gave nothing usable for: the part's own first sentences, so the
    /// part is still in the summary and nothing is made up.
    public static func fallback(for part: String, points: Int) -> SummarySection {
        let paragraphs = part.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let heading = paragraphs.indices.first { SummaryPlan.isHeading(paragraphs[$0], next: $0 + 1 < paragraphs.count ? paragraphs[$0 + 1] : nil) }.map { paragraphs[$0] } ?? ""
        let sentences = paragraphs.filter { PageText.isProse($0) }.map { tidy(firstSentence($0)) }.filter { !$0.isEmpty }
        return SummarySection(heading: heading, points: spread(sentences, keep: max(points, 1)))
    }

    /// What stands for a short section without the model: the first sentence of each of its paragraphs of
    /// prose, or, where it has none (a list, a line of facts), its first lines. Only the section's own words.
    public static func extract(_ text: String, points: Int) -> SummarySection {
        // A block of code is one paragraph (its lines joined): none of it is taken.
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .flatMap { $0.components(separatedBy: .newlines) }.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !ReadingText.isHeadingMark($0) }
        let prose = paragraphs.filter { PageText.isProse(MarkdownLines.plain($0)) && !SummaryPlan.isItemTitle($0) }.map { tidy(firstSentence(MarkdownLines.plain($0))) }.filter { !$0.isEmpty }
        if !prose.isEmpty { return SummarySection(heading: "", points: Array(prose.prefix(points))) }
        let lines = paragraphs.map { MarkdownLines.plain($0).trimmingCharacters(in: CharacterSet(charactersIn: " -*•")) }.filter { $0.split(separator: " ").count >= 2 }
        return SummarySection(heading: "", points: Array(lines.prefix(3)).map(tidy), list: lines.count > 1)
    }

    /// The finished summary as Markdown, in the agreed shape: the overview as a paragraph, then each section's
    /// heading (`###`, or `####` inside a long section) with its points as a list (one point is a sentence on its
    /// own), and its code in a fenced block. A section with nothing to show is left out, unless sub-sections follow
    /// it. `note` is a last plain line (that the end of a very long document is not covered).
    public static func compose(sentence: String, sections: [SummarySection], note: String? = nil) -> String {
        var blocks: [String] = []
        var codeLeft = SummaryPlan.codeBlocks
        if !sentence.isEmpty { blocks.append(sentence) }
        for (i, section) in sections.enumerated() {
            let hasCode = section.code.map { !$0.isEmpty } ?? false
            let parent = section.depth == 0 && sections.indices.contains(i + 1) && sections[i + 1].depth > 0
            guard !section.points.isEmpty || hasCode || (parent && !section.heading.isEmpty) else { continue }
            var lines: [String] = []
            if !section.heading.isEmpty { lines.append((section.depth > 0 ? "#### " : "### ") + section.heading) }
            if section.points.count == 1, !section.list {
                lines.append(asSentence(section.points[0]))
            } else if !section.points.isEmpty {
                lines.append(section.points.map { "- \(section.list ? leadIn($0) : asSentence($0))" }.joined(separator: "\n"))
            }
            var block = lines.joined(separator: "\n")
            if let code = section.code, hasCode, codeLeft > 0 {
                codeLeft -= 1
                // A fence longer than any run of backticks in the code, so the code cannot end it early.
                let fence = code.contains("```") ? "~~~" : "```"
                block += "\n\n\(fence)\n\(code)\n\(fence)"
            }
            blocks.append(block)
        }
        if let note, !note.isEmpty { blocks.append(note) }
        return blocks.joined(separator: "\n\n")
    }

    /// A point as a sentence in a paragraph: it ends with a full stop if it ends with nothing.
    public static func sentenceForm(_ point: String) -> String { asSentence(point) }

    static func asSentence(_ point: String) -> String {
        guard let end = point.last(where: { !"*_`”\"’')".contains($0) }) else { return point }
        return ".!?…:".contains(end) ? point : point + "."
    }

    // MARK: Tidying

    /// A heading's words: no bold marks, no label, no colon or full stop after.
    public static func heading(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        t = String(t.drop { $0 == "#" })
        for label in ["Title:", "Heading:"] where t.hasPrefix(label) { t = String(t.dropFirst(label.count)) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " :.\"“”#"))
    }

    /// A point's words on one line. One that runs on past 45 words (the model wrote a paragraph) keeps
    /// its first sentence.
    static func tidy(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.split(separator: " ").count > 45 { t = firstSentence(t) }
        return t
    }

    /// The text up to its first sentence end that leaves a real sentence (six words or more).
    public static func firstSentence(_ text: String) -> String {
        var words = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if ch == " " { words += 1 }
            if ".!?".contains(ch), words >= 5, next == text.endIndex || text[next] == " " || "”\"’".contains(text[next]) {
                // "v." and initials are not the end of a sentence.
                let before = text[..<index].split(separator: " ").last ?? ""
                if !(ch == "." && before.count == 1 && before.first?.isLetter == true) { return String(text[..<next]) }
            }
            index = next
        }
        return text
    }

    /// A short label before a colon at the start of a point ("Family goals: …") in bold, as a lead-in.
    static func leadIn(_ point: String) -> String {
        guard !point.hasPrefix("**"), let colon = point.range(of: ": ") else { return point }
        let label = point[..<colon.lowerBound]
        guard let first = label.first, first.isUppercase, label.count <= 32, label.split(separator: " ").count <= 4,
            !label.contains(where: { ".,;*\"“”".contains($0) })
        else { return point }
        return "**\(label):** \(point[colon.upperBound...])"
    }

    /// "Here is a summary", "Sure!", "I hope this helps": what a model says around its answer.
    public static func isPreamble(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["here is", "here's", "here are", "sure", "certainly", "okay", "i hope", "let me know", "in summary, here", "below is", "the following is"]
            .contains { l.hasPrefix($0) }
    }
}

extension Prompts {
    /// The standing instruction for every summary step. Kept to a line: the small model follows a short
    /// instruction and loses its way in a long list of rules.
    public func summarySystem() -> String {
        var lines = [
            "You write short, accurate notes on a document for someone who has not read it. Use only what the text says. "
                + "Leave out advertisements, sponsor messages and requests to subscribe or share. "
                + "Use \(profile.spelling == .british ? "British" : "American") English spelling."
        ]
        if !terms.isEmpty { lines.append("Spell these exactly as written: \(terms.prefix(60).joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    /// Asks for the points of one part: its section's title and sentences, each as a bullet (they are set
    /// as a paragraph afterwards), or the items of its list. The request comes after the text, where a
    /// small model heeds it most. It asks for bullets and an exact number because that is what the model
    /// keeps to: asked for a paragraph, or for "3 to 5", it rewrites the whole part instead.
    public func summaryPartRequest(part: String, points: Int, titled: Bool, list: Bool = false) -> String {
        let rules = list
            ? "Each bullet is one item from the list in the part, in at most 15 words, in the writer's own words."
            : """
                Each bullet is one sentence of at most 25 words that gives a main point with its key examples, numbers, \
                dates, decisions or requests.
                """
        if titled {
            return """
                <part>
                \(part)
                </part>

                Summarize the part above. Write a title of 3 to 6 words on the first line, starting with "### ". \
                Then write exactly \(points) bullet points, each starting with "- ". \(rules) \
                If the part has several headed sections, give every section its own bullet. \
                Together the bullets cover the whole part, from its start to its end. Output only the title and the \(points) bullets.
                """
        }
        if points == 1, !list {
            return """
                <text>
                \(part)
                </text>

                Summarize the text above in one sentence of at most 30 words that gives its main point with its key examples, \
                numbers, dates, decisions or requests. Output only that sentence.
                """
        }
        return """
            <text>
            \(part)
            </text>

            Summarize the text above in exactly \(points) bullet points, each starting with "- ". \(rules) \
            Together the bullets cover the whole text, from its start to its end. Output only the \(points) bullets.
            """
    }
}
