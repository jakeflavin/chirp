import Foundation

/// What a book says about itself: who wrote it and how it is divided, read from its own table of
/// contents, for the dropped-file panel ("Cal Newport. 4 parts, 15 chapters. Starts at the
/// introduction."). Worked out by rule; no model.
public enum BookContents {
    /// One line of a table of contents and how deep it sits (0 is the top level).
    public struct Entry: Equatable, Sendable {
        public var label: String
        public var depth: Int

        public init(_ label: String, depth: Int = 0) {
            self.label = label
            self.depth = depth
        }
    }

    /// What the panel says about a book.
    public struct Facts: Equatable, Sendable {
        public var author = ""
        public var parts = 0
        public var chapters = 0
        /// "introduction", "preface", "prologue" or "foreword" when the book opens with one; else empty.
        public var startsAt = ""

        public init(author: String = "", parts: Int = 0, chapters: Int = 0, startsAt: String = "") {
            self.author = author
            self.parts = parts
            self.chapters = chapters
            self.startsAt = startsAt
        }

        /// "Cal Newport. 4 parts, 15 chapters. Starts at the introduction." Whatever is not known is
        /// left out; empty when nothing is.
        public var line: String {
            var out: [String] = []
            if !author.isEmpty { out.append(author) }
            if chapters > 1 {
                let counted = "\(chapters) chapters"
                out.append(parts > 1 ? "\(parts) parts, \(counted)" : counted)
            }
            if !startsAt.isEmpty, chapters > 1 { out.append("Starts at the \(startsAt)") }
            return out.isEmpty ? "" : out.joined(separator: ". ") + "."
        }
    }

    // MARK: Reading an EPUB's own files

    /// The book's authors as its package file names them (`dc:creator`), in order: "Cal Newport",
    /// "Ann Lee and Raj Patel", "Ann Lee, Raj Patel and Mo Diaz". A name filed surname first
    /// ("Newport, Cal") is turned round.
    public static func epubAuthor(package: String) -> String {
        var names: [String] = []
        if let re = Patterns.regex(#"<dc:creator\b[^>]*>(.*?)</dc:creator>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = package as NSString
            for m in re.matches(in: package, range: NSRange(location: 0, length: ns.length)) {
                let name = person(HTMLText.decodeEntities(HTMLText.stripTags(ns.substring(with: m.range(at: 1)))))
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return joined(names)
    }

    /// One person's name, tidied: outer space gone, "Newport, Cal" turned into "Cal Newport". Anything
    /// that does not read as a name (very long, an address) is dropped.
    public static func person(_ raw: String) -> String {
        var name = raw.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].contains(" ") || !parts[1].contains(" ") { name = "\(parts[1]) \(parts[0])" }
        guard name.count <= 60, !name.contains("@"), !name.contains("://"), name.contains(where: \.isLetter) else { return "" }
        return name
    }

    /// "A", "A and B", "A, B and C"; more than three become "A and others".
    public static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        case 3: "\(names[0]), \(names[1]) and \(names[2])"
        default: "\(names[0]) and others"
        }
    }

    /// Where an EPUB keeps its table of contents, relative to the package file: the navigation page
    /// of a newer book (`properties="nav"`), or the older `toc.ncx`.
    public static func epubContentsPath(package: String) -> (path: String, isNCX: Bool)? {
        guard let re = Patterns.regex(#"<item\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let ns = package as NSString
        var ncx: String?
        for m in re.matches(in: package, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let href = HTMLText.firstMatch(#"\bhref="([^"]+)""#, in: tag).map({ $0.removingPercentEncoding ?? $0 }) else { continue }
            if let properties = HTMLText.firstMatch(#"\bproperties="([^"]+)""#, in: tag), properties.split(separator: " ").contains("nav") { return (href, false) }
            if tag.contains("application/x-dtbncx+xml") { ncx = href }
        }
        return ncx.map { ($0, true) }
    }

    /// The lines of a newer book's navigation page: the list inside its `toc` section, with how deep each sits.
    public static func entries(nav html: String) -> [Entry] {
        // The table of contents is the <nav> marked as "toc"; a book with one <nav> only has that one.
        var section = html
        if let re = Patterns.regex(#"<nav\b([^>]*)>(.*?)</nav>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = html as NSString
            let all = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
            let toc = all.first { ns.substring(with: $0.range(at: 1)).lowercased().contains("toc") } ?? all.first
            if let toc { section = ns.substring(with: toc.range(at: 2)) }
        }
        return walk(section, open: #"<ol\b[^>]*>"#, close: #"</ol>"#, label: #"<(?:a|span)\b[^>]*>(.*?)</(?:a|span)>"#)
    }

    /// The lines of an older book's `toc.ncx`: its `navPoint`s, with how deep each sits.
    public static func entries(ncx: String) -> [Entry] {
        let map = HTMLText.firstMatch(#"<navMap\b[^>]*>(.*)</navMap>"#, in: ncx) ?? ncx
        return walk(map, open: #"<navPoint\b[^>]*>"#, close: #"</navPoint>"#, label: #"<navLabel\b[^>]*>(.*?)</navLabel>"#)
    }

    /// Walks nested lists: each `open` goes one level down, each `close` one up, and each `label`
    /// found is a line at the level it sits on.
    private static func walk(_ text: String, open: String, close: String, label: String) -> [Entry] {
        guard let re = Patterns.regex("(\(open))|(\(close))|\(label)", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        var depth = -1
        var out: [Entry] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                depth += 1
            } else if m.range(at: 2).location != NSNotFound {
                depth -= 1
            } else if m.range(at: 3).location != NSNotFound {
                let words = HTMLText.decodeEntities(HTMLText.stripTags(ns.substring(with: m.range(at: 3)))).split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
                if !words.isEmpty { out.append(Entry(words, depth: max(0, depth))) }
            }
            if out.count >= 2000 { break }
        }
        return out
    }

    // MARK: Counting

    /// Pages around the book that are not part of it: left out of every count.
    static let around: [String] = [
        "cover", "title", "title page", "half title", "half title page", "copyright", "copyright page", "contents", "table of contents", "dedication", "epigraph",
        "acknowledgments", "acknowledgements", "acknowledgment", "acknowledgement", "notes", "endnotes", "index", "bibliography", "references", "glossary",
        "about the author", "about the authors", "about the publisher", "also by", "credits", "colophon", "praise", "newsletter", "further reading",
        "list of illustrations", "illustrations", "maps", "landmarks", "frontmatter", "backmatter", "front matter", "back matter", "start", "begin reading",
    ]
    /// How a book may open, before its first chapter.
    static let openings = ["introduction", "preface", "prologue", "foreword"]
    /// How it may close, after its last. Not chapters either.
    static let closings = ["conclusion", "epilogue", "afterword", "postscript", "appendix", "appendices", "coda"]

    /// A label without capitals, numbering or its subtitle: "INTRODUCTION: The Passion" → "introduction".
    static func key(_ label: String) -> String {
        let lowered = label.lowercased()
        let head = lowered.split(whereSeparator: { ":–—.".contains($0) }).first.map(String.init) ?? lowered
        return head.trimmingCharacters(in: .whitespaces)
    }

    private static func isAround(_ label: String) -> Bool {
        let k = key(label)
        return around.contains(k) || k.hasPrefix("also by ") || k.hasPrefix("praise for ") || k.hasPrefix("about the ") || k.hasPrefix("appendix")
    }

    private static func isPart(_ label: String) -> Bool {
        let k = label.lowercased()
        return k.hasPrefix("part ") || k.hasPrefix("book ") || k.hasPrefix("volume ")
    }

    private static func isNumberedChapter(_ label: String) -> Bool {
        let k = label.lowercased()
        return k.hasPrefix("chapter ") || k.first?.isNumber == true
    }

    /// Counts a book's parts and chapters from its table of contents.
    ///
    /// Pages around the book (cover, copyright, index, …) and its opening and closing (introduction,
    /// conclusion, …) are not chapters. When most of the top lines hold other lines under them they
    /// are the parts and the lines under them the chapters, unless the top lines are themselves
    /// numbered chapters (then what sits under them is sections, which are not counted). In a flat
    /// list, lines named "Part …" are the parts. Fewer than two chapters is no count at all, and one
    /// part is no part.
    public static func facts(author: String, entries: [Entry]) -> Facts {
        var facts = Facts(author: author)
        let body = entries.filter { !isAround($0.label) }
        if let first = body.first(where: { $0.depth == 0 }), let opening = openings.first(where: { key(first.label) == $0 }) { facts.startsAt = opening }
        let counted = body.filter { e in !openings.contains(key(e.label)) && !closings.contains(key(e.label)) }
        let top = counted.filter { $0.depth == 0 }
        // Which top lines have lines under them, and how many.
        var holders = 0
        var under = 0
        for (i, entry) in counted.enumerated() where entry.depth == 0 {
            let kids = counted[(i + 1)...].prefix { $0.depth > 0 }.filter { $0.depth == 1 }.count
            if kids > 0 {
                holders += 1
                under += kids
            }
        }
        let numberedTop = top.filter { isNumberedChapter($0.label) }.count
        if holders > 0, numberedTop * 2 < top.count, holders * 2 >= top.count {
            // Parts with chapters under them. A top line with nothing under it, beside the parts, is
            // more often a page around the book than a chapter, so it is not counted.
            facts.parts = holders
            facts.chapters = under
        } else if top.contains(where: { isPart($0.label) }) {
            facts.parts = top.filter { isPart($0.label) }.count
            facts.chapters = top.count - facts.parts
        } else {
            facts.chapters = top.count
        }
        if facts.chapters < 2 {
            facts.chapters = 0
            facts.parts = 0
        }
        if facts.parts < 2 { facts.parts = 0 }
        return facts
    }
}
