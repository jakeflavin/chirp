import Foundation

/// Reads a web page or an e-book chapter into a document that keeps its structure: headings,
/// paragraphs, lists, bold and italic, links, quotes, simple tables and where its pictures are.
/// No scripting and no network: only the markup it is given.
public enum HTMLDocument {
    /// A page as a document.
    public struct Article: Sendable {
        public var title: String
        /// The site's own name ("Long Run Journal"), when the page gives one.
        public var site: String
        public var builder: DocBuilder
    }

    /// The main article of a page.
    public static func article(from html: String, base: URL? = nil) -> Article {
        var title = HTMLText.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map { HTMLText.decodeEntities(HTMLText.stripTags($0)) } ?? ""
        if let h1 = HTMLText.firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: html) {
            let t = HTMLText.decodeEntities(HTMLText.stripTags(h1)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty { title = t }
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var body = html
        // Prefer the element that is meant to hold the article.
        for pattern in [#"<article[^>]*>(.*)</article>"#, #"<main[^>]*>(.*)</main>"#, #"<body[^>]*>(.*)</body>"#] {
            if let inner = HTMLText.firstMatch(pattern, in: body), HTMLText.stripTags(inner).count > 200 || pattern.contains("body") {
                body = inner
                break
            }
        }
        var builder = blocks(from: body, base: base)
        // The page's own title is above the text already; it is not repeated as the first heading.
        builder.dropLeadingHeading(title)
        return Article(title: title, site: siteName(html), builder: builder)
    }

    /// The name a page gives its site: `og:site_name`, or `application-name`.
    static func siteName(_ html: String) -> String {
        for name in ["og:site_name", "application-name"] {
            let quoted = NSRegularExpression.escapedPattern(for: name)
            for pattern in [
                #"<meta[^>]*(?:property|name)=["']\#(quoted)["'][^>]*content=["']([^"']+)["']"#,
                #"<meta[^>]*content=["']([^"']+)["'][^>]*(?:property|name)=["']\#(quoted)["']"#,
            ] {
                if let found = HTMLText.firstMatch(pattern, in: html) {
                    let site = HTMLText.decodeEntities(found).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !site.isEmpty { return site }
                }
            }
        }
        return ""
    }

    /// Elements whose contents are never part of the reading text.
    private static let skipped: Set<String> = [
        "script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "button", "iframe", "head", "template", "select", "math",
    ]
    /// Elements that end the block before them and start one after.
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "ul", "ol", "dl", "dd", "dt", "table", "tbody", "thead", "tfoot", "figure", "figcaption",
        "address", "details", "summary", "hr", "center", "body", "html",
    ]

    /// The blocks of an HTML fragment, in order.
    public static func blocks(from html: String, base: URL? = nil) -> DocBuilder {
        var out = DocBuilder()
        var runs: [DocBuilder.Run] = []
        var kind = DocLayout.Block.Kind.paragraph
        var bold = 0, italic = 0, code = 0
        var links: [String?] = []
        var quote = 0
        var skip: [String] = []
        // Lists that are open: nil for a bulleted one, the next number for a numbered one.
        var lists: [Int?] = []
        var marker: String?
        // A table row being gathered, and whether its cells are heading cells.
        var row: [[DocBuilder.Run]]?
        var rowIsHead = false
        var inHead = false
        var pre: String?
        var caption: String?
        // A picture inside a figure waits for its caption; one in the middle of a paragraph goes after it.
        var pendingImage: (source: String, alt: String)?
        var afterBlock: [(source: String, alt: String)] = []
        var inFigure = 0
        var cellOpen = false

        func flushImage() {
            guard let image = pendingImage else { return }
            pendingImage = nil
            out.addImage(image.source, caption: image.alt)
        }
        func flush() {
            if row != nil {
                // Inside a table, the words gathered so far are the current cell's.
                return
            }
            defer {
                runs = []
                kind = quote > 0 ? .quote : .paragraph
                marker = nil
                for image in afterBlock { out.addImage(image.source, caption: image.alt) }
                afterBlock = []
            }
            guard runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
            out.add(kind == .paragraph && quote > 0 ? .quote : kind, runs, marker: marker)
        }
        func endCell() {
            guard row != nil, cellOpen else { return }
            cellOpen = false
            row?.append(runs)
            runs = []
        }
        func text(_ raw: String) {
            guard skip.isEmpty else { return }
            if pre != nil {
                pre? += HTMLText.decodeEntities(raw)
                return
            }
            if caption != nil {
                caption? += HTMLText.decodeEntities(raw)
                return
            }
            let words = HTMLText.decodeEntities(raw)
            guard !words.isEmpty else { return }
            runs.append(DocBuilder.Run(words, bold: bold > 0, italic: italic > 0, code: code > 0, link: links.last ?? nil))
        }

        let ns = html as NSString
        var at = 0
        let count = ns.length
        while at < count {
            let open = ns.range(of: "<", range: NSRange(location: at, length: count - at))
            if open.location == NSNotFound {
                text(ns.substring(from: at))
                break
            }
            if open.location > at { text(ns.substring(with: NSRange(location: at, length: open.location - at))) }
            // A comment runs to its own end, whatever is inside.
            if ns.substring(with: NSRange(location: open.location, length: min(4, count - open.location))) == "<!--" {
                let close = ns.range(of: "-->", range: NSRange(location: open.location, length: count - open.location))
                at = close.location == NSNotFound ? count : NSMaxRange(close)
                continue
            }
            let close = ns.range(of: ">", range: NSRange(location: open.location, length: count - open.location))
            guard close.location != NSNotFound else { break }
            let tag = ns.substring(with: NSRange(location: open.location + 1, length: close.location - open.location - 1))
            at = NSMaxRange(close)
            let closing = tag.hasPrefix("/")
            let name = String(tag.dropFirst(closing ? 1 : 0).prefix { $0.isLetter || $0.isNumber }).lowercased()
            // "<" that does not start a tag ("a < b") is text.
            guard !name.isEmpty else {
                if !tag.hasPrefix("!") && !tag.hasPrefix("?") { text("<" + tag + ">") }
                continue
            }
            // Script and style hold text that is not markup: jump to their end.
            if !closing, name == "script" || name == "style" {
                let end = ns.range(of: "</\(name)", options: .caseInsensitive, range: NSRange(location: at, length: count - at))
                if end.location == NSNotFound { break }
                let after = ns.range(of: ">", range: NSRange(location: end.location, length: count - end.location))
                at = after.location == NSNotFound ? count : NSMaxRange(after)
                continue
            }
            if !skip.isEmpty {
                if closing, name == skip.last { skip.removeLast() } else if !closing, skipped.contains(name), !tag.hasSuffix("/") { skip.append(name) }
                continue
            }
            if !closing, skipped.contains(name) {
                if !tag.hasSuffix("/") { skip.append(name) }
                continue
            }
            switch name {
            case "br":
                if pre != nil { pre? += "\n" } else { text(" ") }
            case "b", "strong": bold = max(0, bold + (closing ? -1 : 1))
            case "i", "em", "cite": italic = max(0, italic + (closing ? -1 : 1))
            case "code", "kbd", "samp", "tt": if pre == nil { code = max(0, code + (closing ? -1 : 1)) }
            case "a":
                if closing {
                    if !links.isEmpty { links.removeLast() }
                } else {
                    // A link to a file on this Mac (another chapter of a book) leads nowhere once it is imported.
                    links.append(attribute("href", in: tag).flatMap { resolve($0, base: base) }.flatMap { $0.hasPrefix("file:") || !$0.contains(":") ? nil : $0 })
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { kind = name <= "h2" ? .heading : .subheading }
            case "blockquote":
                flush()
                quote = max(0, quote + (closing ? -1 : 1))
                kind = quote > 0 ? .quote : .paragraph
            case "ul", "ol":
                flush()
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    lists.append(name == "ol" ? (attribute("start", in: tag).flatMap { Int($0) } ?? 1) : nil)
                }
            case "li":
                flush()
                if !closing {
                    if let last = lists.indices.last, let n = lists[last] {
                        kind = .numbered
                        marker = "\(n)."
                        lists[last] = n + 1
                    } else {
                        kind = .bullet
                    }
                }
            case "pre":
                flush()
                if closing {
                    if let code = pre { out.addCode(code) }
                    pre = nil
                } else {
                    pre = ""
                }
            case "thead": inHead = !closing
            case "tr":
                if closing {
                    endCell()
                    if let cells = row {
                        row = nil
                        out.addRow(cells, head: rowIsHead || inHead)
                        runs = []
                    }
                } else {
                    flush()
                    row = []
                    rowIsHead = false
                    cellOpen = false
                }
            case "td", "th":
                if closing {
                    endCell()
                } else {
                    // A cell that was never closed ends where the next begins.
                    endCell()
                    if row == nil {
                        flush()
                        row = []
                        rowIsHead = false
                    }
                    // What lies between two cells is not in either.
                    runs = []
                    cellOpen = true
                    if name == "th", row?.isEmpty == true { rowIsHead = true }
                }
            case "table":
                if closing, let cells = row {
                    endCell()
                    row = nil
                    out.addRow(cells.isEmpty ? [] : cells, head: rowIsHead || inHead)
                    runs = []
                }
                flush()
            case "img":
                guard !closing, let source = attribute("src", in: tag) ?? attribute("data-src", in: tag), let address = resolve(source, base: base) else { continue }
                // A picture a few points across is a spacer or a tracker, not part of the article.
                if let w = attribute("width", in: tag).flatMap({ Int($0) }), w < 48 { continue }
                if let h = attribute("height", in: tag).flatMap({ Int($0) }), h < 48 { continue }
                let image = (source: address, alt: attribute("alt", in: tag) ?? "")
                if inFigure > 0 {
                    flushImage()
                    pendingImage = image
                } else if row == nil, runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    afterBlock.append(image)
                } else {
                    out.addImage(image.source, caption: image.alt)
                }
            case "figure":
                flush()
                inFigure = max(0, inFigure + (closing ? -1 : 1))
                if closing { flushImage() }
            case "figcaption":
                flush()
                if closing {
                    if let words = caption, pendingImage != nil, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingImage?.alt = words }
                    caption = nil
                    flushImage()
                } else if pendingImage != nil {
                    caption = ""
                }
            default:
                if blockTags.contains(name) { flush() }
            }
        }
        if let code = pre { out.addCode(code) }
        if let cells = row {
            endCell()
            out.addRow(row ?? cells, head: rowIsHead)
            row = nil
            runs = []
        }
        flush()
        flushImage()
        return out
    }

    /// The value of an attribute in a tag's inside ("a href='x' class=y").
    static func attribute(_ name: String, in tag: String) -> String? {
        let quoted = NSRegularExpression.escapedPattern(for: name)
        guard let found = HTMLText.firstMatch(#"(?:^|\s)\#(quoted)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)"#, in: tag) else { return nil }
        var value = found
        if let first = value.first, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
        value = HTMLText.decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// An address as written in a page, made whole against the page's own. Addresses that are not web
    /// or file addresses (`javascript:`, `data:` of unknown kind, `#top`) give nil.
    static func resolve(_ address: String, base: URL?) -> String? {
        if address.hasPrefix("data:image/") { return address }
        if address.hasPrefix("#") || address.lowercased().hasPrefix("javascript:") || address.lowercased().hasPrefix("data:") { return nil }
        if address.lowercased().hasPrefix("mailto:") { return address }
        let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))) ?? address
        guard let url = URL(string: address, relativeTo: base) ?? URL(string: escaped, relativeTo: base) else { return nil }
        let whole = url.absoluteURL
        guard let scheme = whole.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            // No base to make it whole with: kept as written, for a book's own files.
            return base == nil && !address.contains(":") ? address : nil
        }
        return whole.absoluteString
    }
}

extension DocBuilder {
    /// Takes away a first heading that only repeats the document's title.
    mutating func dropLeadingHeading(_ title: String) {
        guard !title.isEmpty, let first = layout.blocks.first(where: { $0.kind != .image }), first.kind == .heading || first.kind == .subheading else { return }
        let words = (text as NSString).substring(with: NSRange(location: first.start, length: first.length))
        guard words.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return }
        // Built again without it, so every range stays right.
        var rebuilt = DocBuilder()
        let ns = text as NSString
        var dropped = false
        for block in layout.blocks {
            if !dropped, block == first {
                dropped = true
                continue
            }
            rebuilt.copy(block, from: ns)
        }
        self = rebuilt
    }

    /// Adds a block taken from another text, with its styles.
    mutating func copy(_ block: DocLayout.Block, from ns: NSString) {
        func runs(_ start: Int, _ length: Int) -> [Run] {
            // Cut where any span starts or ends, so each piece has one set of styles.
            var cuts: Set<Int> = [start, start + length]
            for s in block.spans { for c in [s.start, s.start + s.length] where c > start && c < start + length { cuts.insert(c) } }
            let sorted = cuts.sorted()
            return zip(sorted, sorted.dropFirst()).map { a, b in
                var run = Run(ns.substring(with: NSRange(location: a, length: b - a)))
                for s in block.spans where s.start <= a && s.start + s.length >= b {
                    switch s.style {
                    case .bold: run.bold = true
                    case .italic: run.italic = true
                    case .code: run.code = true
                    case .link: run.link = s.url
                    }
                }
                return run
            }
        }
        switch block.kind {
        case .image: addImage(block.image ?? "", caption: block.caption ?? "")
        case .code: addCode(ns.substring(with: NSRange(location: block.start, length: block.length)))
        case .tableHead, .tableRow: addRow((block.cells ?? []).map { runs($0.start, $0.length) }, head: block.kind == .tableHead)
        default: add(block.kind, runs(block.start, block.length), marker: block.marker)
        }
    }
}

/// Reads Markdown (a .md file) into a document that keeps its structure, with the marks taken out of the words.
public enum MarkdownDocument {
    public static func blocks(from markdown: String) -> DocBuilder {
        var out = DocBuilder()
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.add(.paragraph, inline(paragraph.joined(separator: " ")))
            paragraph = []
        }
        var fence: [String]?
        var rows: [[String]] = []
        func flushRows(headed: Bool) {
            for (n, cells) in rows.enumerated() { out.addRow(cells.map(inline), head: headed && n == 0) }
            rows = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    out.addCode(fence!.joined(separator: "\n"))
                    fence = nil
                } else {
                    fence?.append(raw)
                }
                continue
            }
            if let cells = ReadingText.tableCells(line), line.hasPrefix("|") {
                flush()
                if cells.isEmpty { flushRows(headed: true) } else { rows.append(cells.map(\.text)) }
                continue
            }
            if !rows.isEmpty { flushRows(headed: false) }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = []
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            guard let parsed = MarkdownLines.parse(line).first else {
                flush()
                continue
            }
            switch parsed.kind {
            case .heading(let level):
                flush()
                out.add(level <= 2 ? .heading : .subheading, inline(parsed.text))
            case .point(let marker, _):
                flush()
                out.add(marker == "•" ? .bullet : .numbered, inline(parsed.text), marker: marker == "•" ? nil : marker)
            case .text where line.hasPrefix(">"):
                flush()
                out.add(.quote, inline(String(line.drop { $0 == ">" || $0 == " " })))
            default:
                // A picture on its own line.
                if let image = HTMLText.firstMatch(#"^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$"#, in: line),
                    let source = HTMLText.firstMatch(#"^!\[[^\]]*\]\(([^)\s]+)"#, in: line)
                {
                    flush()
                    out.addImage(source, caption: image)
                } else {
                    paragraph.append(line)
                }
            }
        }
        if let open = fence { out.addCode(open.joined(separator: "\n")) }
        flushRows(headed: false)
        flush()
        return out
    }

    private static let marks = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)\s]+)[^)]*\)|\*\*(.+?)\*\*|__(.+?)__|(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])|(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])|`([^`]+)`"#)

    /// One line's words as runs: links, bold, italic and code, their marks removed.
    static func inline(_ text: String) -> [DocBuilder.Run] {
        let ns = text as NSString
        var runs: [DocBuilder.Run] = []
        var at = 0
        for m in marks.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { runs.append(DocBuilder.Run(ns.substring(with: NSRange(location: at, length: m.range.location - at)))) }
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if let words = group(1) {
                runs.append(DocBuilder.Run(words, link: group(2)))
            } else if let words = group(3) ?? group(4) {
                runs.append(DocBuilder.Run(words, bold: true))
            } else if let words = group(5) ?? group(6) {
                runs.append(DocBuilder.Run(words, italic: true))
            } else if let words = group(7) {
                runs.append(DocBuilder.Run(words, code: true))
            }
            at = NSMaxRange(m.range)
        }
        if at < ns.length { runs.append(DocBuilder.Run(ns.substring(from: at))) }
        return runs
    }
}
