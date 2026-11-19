import Foundation

/// Tidies the text of a page read off the screen (a web page in a browser, a document in a window), which
/// arrives as one line per block with the site's menus, links and footer around the article.
public enum PageText {
    /// How many short lines in a row, before the first full sentence or after the last, count as the
    /// site's own furniture. A letter's address block or a short closing list is smaller than this.
    static let leadLines = 8
    static let tailLines = 6

    /// The article without the menus before it and the links after it. The title is kept: the longest
    /// short line just before the first full sentence. Text that is not shaped like an article (mostly
    /// short lines, or where this would drop more than two fifths) comes back unchanged.
    public static func article(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // An email (its header lines at the top) has no site around it: a list of dates at its end is the message's own.
        let header = lines.prefix(8).map { $0.lowercased() }
        if header.contains(where: { $0.hasPrefix("from:") }), header.contains(where: { $0.hasPrefix("subject:") }) { return raw }
        guard let first = lines.firstIndex(where: isProse), let last = lines.lastIndex(where: isProse) else { return raw }
        var kept = Array(lines[first...last])
        var changed = false
        if first >= leadLines {
            // The headline sits among the last few lines before the article starts, and is the longest of them.
            let near = lines[max(0, first - 12)..<first]
            if let title = near.filter({ (3...30).contains(TextStats.words($0)) }).max(by: { $0.count < $1.count }) { kept.insert(title, at: 0) }
            changed = true
        } else {
            kept.insert(contentsOf: lines[..<first], at: 0)
        }
        if lines.count - 1 - last >= tailLines {
            changed = true
        } else {
            kept.append(contentsOf: lines[(last + 1)...])
        }
        guard changed else { return raw }
        let before = lines.reduce(0) { $0 + $1.count }
        let after = kept.reduce(0) { $0 + $1.count }
        guard after * 5 >= before * 3 else { return raw }
        return kept.joined(separator: "\n")
    }

    /// Each line as a paragraph of its own (a blank line between), so that text cleaning, which joins
    /// the lines of one paragraph, leaves headings and list items apart.
    public static func paragraphs(_ raw: String) -> String {
        raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A full sentence of reading matter: eight words or more, ending the way a sentence does. Menu
    /// items, headlines, dates and link titles are not.
    static func isProse(_ line: String) -> Bool {
        guard TextStats.words(line) >= 8, let end = line.last else { return false }
        return ".!?…”\"’')".contains(end)
    }

}
