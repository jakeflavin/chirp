import Foundation

/// Markdown as HTML, for the clipboard: what is copied from Chirp keeps its headings, lists, bold and
/// links when pasted into Mail, Notes or a document, and the Markdown itself is the plain-text form.
public enum RichText {
    /// A small, self-contained HTML fragment. Tables are written as tables; everything is escaped.
    public static func html(fromMarkdown markdown: String) -> String {
        var out: [String] = []
        // The list that is open ("ul" or "ol"), and the rows of a table being gathered.
        var list: String?
        var rows: [[String]] = []
        var headed = false
        func closeList() {
            if let open = list { out.append("</\(open)>") }
            list = nil
        }
        func closeTable() {
            guard !rows.isEmpty else { return }
            var html = "<table>"
            for (n, cells) in rows.enumerated() {
                let tag = headed && n == 0 ? "th" : "td"
                html += "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            out.append(html + "</table>")
            rows = []
            headed = false
        }
        // Table rows are taken before the Markdown lines are parsed, which knows nothing of tables.
        var pending: [String] = []
        func flushPending() {
            guard !pending.isEmpty else { return }
            for line in MarkdownLines.parse(pending.joined(separator: "\n")) {
                switch line.kind {
                case .heading(let level):
                    closeList()
                    let tag = "h\(min(max(level, 1), 4))"
                    out.append("<\(tag)>\(inline(line.text))</\(tag)>")
                case .point(let marker, _):
                    let wanted = marker == "•" ? "ul" : "ol"
                    if list != wanted {
                        closeList()
                        out.append("<\(wanted)>")
                        list = wanted
                    }
                    out.append("<li>\(inline(line.text))</li>")
                case .text:
                    closeList()
                    if line.text.hasPrefix("> ") {
                        out.append("<blockquote>\(inline(String(line.text.dropFirst(2))))</blockquote>")
                    } else {
                        out.append("<p>\(inline(line.text))</p>")
                    }
                case .code:
                    closeList()
                    out.append("<pre>\(escape(line.text))</pre>")
                }
            }
            pending = []
        }
        var fenced = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
            if !fenced, line.hasPrefix("|"), let cells = ReadingText.tableCells(line) {
                flushPending()
                closeList()
                if cells.isEmpty { headed = !rows.isEmpty } else { rows.append(cells.map(\.text)) }
                continue
            }
            if !rows.isEmpty { closeTable() }
            pending.append(raw)
        }
        flushPending()
        closeList()
        closeTable()
        return out.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// One line's words with bold, italic, code and links as tags.
    static func inline(_ text: String) -> String {
        MarkdownDocument.inline(text).map { run in
            var html = escape(run.text)
            if run.code { html = "<code>\(html)</code>" }
            if run.italic { html = "<em>\(html)</em>" }
            if run.bold { html = "<strong>\(html)</strong>" }
            if let link = run.link { html = "<a href=\"\(escape(link).replacingOccurrences(of: "\"", with: "&quot;"))\">\(html)</a>" }
            return html
        }.joined()
    }
}
