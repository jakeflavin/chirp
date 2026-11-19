import Foundation

/// The words the Library says about a document: its row's second line, the source line above its
/// title, and how a page's rows are grouped. Worked out here so every page says the same thing.
public enum DocumentRows {
    /// What a document is, in a word or two: its format when one was kept, else told from where it came from.
    public static func format(_ item: SavedItem, extra: DocumentExtra?) -> String {
        if let format = extra?.format, !format.isEmpty { return format }
        guard let source = item.source, !source.isEmpty else { return "Document" }
        if host(source) != nil { return "Web page" }
        guard source.hasPrefix("/") else { return source == "Pasted text" ? "Text" : "Document" }
        return format(ofFileEnding: (source as NSString).pathExtension)
    }

    /// "PDF" for "pdf", and so on; "Document" for a kind with no name of its own.
    public static func format(ofFileEnding ending: String) -> String {
        switch ending.lowercased() {
        case "pdf": "PDF"
        case "epub": "EPUB"
        case "docx", "doc": "Word"
        case "rtf", "rtfd": "Rich text"
        case "odt": "OpenDocument"
        case "html", "htm", "xhtml": "Web page"
        case "md", "markdown": "Markdown"
        case "txt", "text", "": "Text"
        default: "Document"
        }
    }

    /// The site of a web address without "www." ("longrunjournal.com"); nil for anything that is not one.
    public static func host(_ source: String?) -> String? {
        guard let source, source.lowercased().hasPrefix("http"), let host = URL(string: source)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// How much of a document has been heard, 0 to 100.
    public static func heard(_ item: SavedItem) -> Int {
        let length = item.body.utf16.count
        return length == 0 ? 0 : min(100, Int(Double(item.position) / Double(length) * 100))
    }

    /// "42 min", "2 h 31 min", or "4 sec" for something under a minute.
    public static func length(_ seconds: Double) -> String {
        if seconds >= 1, seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// What a document is and how long: "PDF · 14 pages", "longrunjournal.com · 9 min read", "EPUB · 41%
    /// heard", "YouTube · 42 min · 2 speakers". `readSeconds` is its listening time at normal speed.
    public static func facts(_ item: SavedItem, extra: DocumentExtra?, readSeconds: Double, speakers: Int = 0) -> [String] {
        var parts: [String] = []
        let transcript = extra?.isTranscript == true
        // A saved page is known by its site; a file by its format.
        parts.append(transcript ? format(item, extra: extra) : host(item.source) ?? format(item, extra: extra))
        if transcript {
            if item.duration >= 1 { parts.append(length(item.duration)) }
            if speakers > 1 { parts.append("\(speakers) speakers") }
            return parts
        }
        let done = heard(item)
        if done >= 99 {
            parts.append("finished")
        } else if done > 0 {
            parts.append("\(done)% heard")
        } else if let pages = extra?.pages, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        } else {
            parts.append("\(length(readSeconds)) read")
        }
        return parts
    }

    /// A row's second line: the facts, then the folder it is in.
    public static func meta(_ item: SavedItem, extra: DocumentExtra?, readSeconds: Double, speakers: Int = 0, folder: String? = nil) -> String {
        (facts(item, extra: extra, readSeconds: readSeconds, speakers: speakers) + [folder].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " · ")
    }

    /// When something was saved, as the source line says it: "today 7:58", "Friday", "13 Nov".
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today " + date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days == 1 { return "yesterday" }
        if (2..<7).contains(days) { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The small line above a document's title: where it came from, as a link when it has an address,
    /// then what is known about it.
    public struct Source: Equatable, Sendable {
        /// "Long Run Journal · longrunjournal.com", "YouTube · Designing calm software"; empty for a file.
        public var linkTitle: String
        public var link: URL?
        /// What follows: "9 min read · saved today 7:58".
        public var rest: String
    }

    public static func source(
        _ item: SavedItem, extra: DocumentExtra?, readSeconds: Double, speakers: Int = 0, folder: String? = nil, now: Date = Date(),
        calendar: Calendar = .current
    ) -> Source {
        let when = day(item.createdAt, now: now, calendar: calendar)
        let link = item.source.flatMap { host($0) != nil ? URL(string: $0) : nil }
        var facts = Array(facts(item, extra: extra, readSeconds: readSeconds, speakers: speakers).dropFirst())
        if extra?.isTranscript == true {
            facts.append("transcribed \(when)")
            // A link's line names what it is and its title; a file that was transcribed has no link.
            let name = format(item, extra: extra)
            return link == nil
                ? Source(linkTitle: "", link: nil, rest: ([name] + facts).joined(separator: " · "))
                : Source(linkTitle: "\(name) · \(item.title)", link: link, rest: facts.joined(separator: " · "))
        }
        if let link, let host = host(item.source) {
            facts.append("saved \(when)")
            let site = extra?.site ?? ""
            return Source(linkTitle: site.isEmpty || site.lowercased() == host ? host : "\(site) · \(host)", link: link, rest: facts.joined(separator: " · "))
        }
        facts.append("added \(when)")
        if let folder, !folder.isEmpty { facts.append(folder) }
        return Source(linkTitle: "", link: nil, rest: ([format(item, extra: extra)] + facts).joined(separator: " · "))
    }

    /// One group of rows under a heading.
    public struct Group: Identifiable, Sendable {
        public let title: String
        public let items: [SavedItem]
        public var id: String { title }
        /// True for the pinned group, which has its own heading, count and filled pins.
        public var isPinned: Bool { title == "Pinned" }
    }

    /// Pinned first, in a group of its own; then today's, then everything earlier.
    public static func groups(_ items: [SavedItem], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let pinned = items.filter(\.starred)
        let rest = items.filter { !$0.starred }
        let today = rest.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
        let earlier = rest.filter { !calendar.isDate($0.createdAt, inSameDayAs: now) }
        return [Group(title: "Pinned", items: pinned), Group(title: "Today", items: today), Group(title: "Earlier", items: earlier)]
            .filter { !$0.items.isEmpty }
    }

    /// The grey line under the Documents title: "7 documents · 2 being read".
    public static func subtitle(_ items: [SavedItem]) -> String {
        guard !items.isEmpty else { return "No documents" }
        let reading = items.filter { (1..<99).contains(heard($0)) }.count
        return (items.count == 1 ? "1 document" : "\(items.count) documents") + (reading > 0 ? " · \(reading) being read" : "")
    }

    /// The first sentence of a summary, as plain words: the one line a folded summary panel shows.
    public static func summaryLine(_ summary: String) -> String {
        let lines = MarkdownLines.parse(summary).filter { if case .heading = $0.kind { false } else { $0.kind != .code } }
        guard let first = lines.first else { return "" }
        return MarkdownLines.plain(first.text).replacingOccurrences(of: "\n", with: " ")
    }
}

/// Tells whether a page fetched from its address is the article that was read off the screen.
public enum PageMatch {
    /// True when nearly all of the fetched article's words are in what was read, and the two are of a
    /// like length. A sign-in page, an error page or another article is not.
    public static func sameArticle(_ read: String, _ fetched: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map(String.init))
        }
        let a = words(read), b = words(fetched)
        guard b.count >= 20, a.count >= 20 else { return false }
        let shared = Double(b.intersection(a).count) / Double(b.count)
        let ratio = Double(fetched.count) / Double(max(1, read.count))
        return shared >= 0.8 && ratio >= 0.3 && ratio <= 1.6
    }
}
