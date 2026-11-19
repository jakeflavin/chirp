import Foundation

/// Pulls readable text out of a web page or an e-book chapter. Deliberately simple: no scripting,
/// no network, just the article's words in order.
public enum HTMLText {
    /// A page reduced to what is read aloud.
    public struct Article: Sendable, Equatable {
        public var title: String
        /// The paragraphs, separated by blank lines.
        public var text: String
    }

    /// The main article of a page: its title and paragraphs, without navigation, ads or scripts.
    public static func article(from html: String) -> Article {
        var title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map { decodeEntities(stripTags($0)) } ?? ""
        if let h1 = firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: html) {
            let t = decodeEntities(stripTags(h1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }
        var body = html
        // Prefer the element that is meant to hold the article.
        for pattern in [#"<article[^>]*>(.*)</article>"#, #"<main[^>]*>(.*)</main>"#, #"<body[^>]*>(.*)</body>"#] {
            if let inner = firstMatch(pattern, in: body), stripTags(inner).count > 200 || pattern.contains("body") {
                body = inner
                break
            }
        }
        return Article(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text(from: body))
    }

    /// Text of an HTML fragment with paragraphs separated by blank lines.
    public static func text(from html: String) -> String {
        var s = html
        // Things that are never part of the reading text.
        for tag in ["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "figure", "button", "iframe"] {
            s = replace(#"<\#(tag)\b[^>]*>.*?</\#(tag)>"#, in: s, with: " ")
        }
        s = replace(#"<!--.*?-->"#, in: s, with: " ")
        // Block elements become paragraph breaks; line breaks become newlines.
        s = replace(#"<br\s*/?>"#, in: s, with: "\n")
        s = replace(#"<li\b[^>]*>"#, in: s, with: "\n\n- ")  // "\b" so that "<link …>" is not taken for a list item
        // A table row is written with bars between its cells ("| Name | Pace |"), so it is read a cell at
        // a time (`ReadingText.tableCells`). Without them a row's cells ran together as one sentence.
        s = replace(#"<t[dh]\b[^>]*>"#, in: s, with: " | ")
        s = replace(#"</tr>"#, in: s, with: " |\n\n")
        s = replace(#"</?(p|div|section|article|h[1-6]|ul|ol|li|blockquote|tr|table|pre)\b[^>]*>"#, in: s, with: "\n\n")
        s = decodeEntities(stripTags(s))
        let paragraphs = s.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && $0 != "-" }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The text with every remaining tag removed.
    static func stripTags(_ s: String) -> String {
        replace(#"<[^>]+>"#, in: s, with: "")
    }

    /// The named entities that turn up in articles. Numbered ones ("&#8217;") are worked out.
    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
        "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™",
    ]

    private static let entity = try! NSRegularExpression(pattern: #"&(#x?[0-9a-fA-F]+|[a-zA-Z]+);"#)

    /// "&amp;" and the like as the characters they stand for. One that is not known is left as written.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let re = entity
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = entities[name]
            }
            out += replacement ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The first group of the first match of `pattern`, ignoring case and with "." matching line breaks too.
    public static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = Patterns.regex(pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), m.numberOfRanges > 1
        else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    /// `s` with every match of `pattern` replaced, under the same options as `firstMatch`.
    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = Patterns.regex(pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        return re.replacing(in: s, with: template)
    }

    // MARK: EPUB

    /// The path of the package file named in an EPUB's `META-INF/container.xml`.
    public static func epubPackagePath(container: String) -> String? {
        firstMatch(#"<rootfile[^>]*full-path="([^"]+)""#, in: container)
    }

    /// Chapter file paths of an EPUB in reading order, relative to the package file, plus the book's title.
    public static func epubSpine(package: String) -> (title: String, chapters: [String]) {
        let title = firstMatch(#"<dc:title[^>]*>(.*?)</dc:title>"#, in: package).map { decodeEntities(stripTags($0)) } ?? ""
        var hrefs: [String: String] = [:]
        if let re = Patterns.regex(#"<item\b[^>]*>"#, options: [.caseInsensitive]) {
            let ns = package as NSString
            for m in re.matches(in: package, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: m.range)
                if let id = firstMatch(#"\bid="([^"]+)""#, in: tag), let href = firstMatch(#"\bhref="([^"]+)""#, in: tag) {
                    hrefs[id] = href.removingPercentEncoding ?? href
                }
            }
        }
        var chapters: [String] = []
        if let re = Patterns.regex(#"<itemref\b[^>]*\bidref="([^"]+)""#, options: [.caseInsensitive]) {
            let ns = package as NSString
            for m in re.matches(in: package, range: NSRange(location: 0, length: ns.length)) {
                if let href = hrefs[ns.substring(with: m.range(at: 1))] { chapters.append(href) }
            }
        }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), chapters)
    }
}
