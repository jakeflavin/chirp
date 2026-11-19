import Foundation

/// The text inside PowerPoint and Excel files, and comma-separated ones. A .pptx or .xlsx is a zip of
/// XML parts; the app unpacks it (as it does an e-book) and hands the parts here. Plain text work only.
public enum OfficeText {
    /// The words on one slide (`ppt/slides/slideN.xml`), a line for each paragraph.
    public static func slide(_ xml: String) -> String {
        paragraphs(in: xml, paragraph: "a:p", run: "a:t").joined(separator: "\n")
    }

    /// The slides' file names in the order they are shown: `slide2.xml` before `slide10.xml`.
    public static func inOrder(_ names: [String]) -> [String] {
        func number(_ name: String) -> Int { Int(name.filter(\.isNumber)) ?? 0 }
        return names.sorted { number($0) < number($1) }
    }

    /// The strings a workbook's cells point at (`xl/sharedStrings.xml`), in order.
    public static func sharedStrings(_ xml: String) -> [String] {
        pieces(of: xml, tag: "si").map { item in pieces(of: item, tag: "t").map(decode).joined() }
    }

    /// One sheet (`xl/worksheets/sheetN.xml`) as lines of text, a line for each row, cells separated by tabs.
    public static func sheet(_ xml: String, strings: [String]) -> String {
        pieces(of: xml, tag: "row").compactMap { row -> String? in
            let cells = matches(#"<c\b([^>]*)>(.*?)</c>"#, in: row).compactMap { cell -> String? in
                let attributes = cell[0], inside = cell[1]
                if attributes.contains(#"t="s""#) {
                    guard let index = pieces(of: inside, tag: "v").first.flatMap({ Int($0) }), strings.indices.contains(index) else { return nil }
                    return strings[index]
                }
                if attributes.contains(#"t="inlineStr""#) { return pieces(of: inside, tag: "t").map(decode).joined() }
                return pieces(of: inside, tag: "v").first.map(decode)
            }.filter { !$0.isEmpty }
            return cells.isEmpty ? nil : cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// A comma-separated file as lines of text, cells separated by tabs. Quoted cells keep their commas.
    public static func csv(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line -> String in
            var cells: [String] = []
            var cell = ""
            var quoted = false
            var previous: Character?
            for character in line {
                if character == "\"" {
                    // A doubled quote inside a quoted cell is one quote.
                    if !quoted, previous == "\"" { cell.append("\"") }
                    quoted.toggle()
                } else if (character == "," || character == ";" || character == "\t"), !quoted {
                    cells.append(cell)
                    cell = ""
                } else {
                    cell.append(character)
                }
                previous = character
            }
            cells.append(cell)
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\t")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Reading the XML

    private static func paragraphs(in xml: String, paragraph: String, run: String) -> [String] {
        pieces(of: xml, tag: paragraph).map { pieces(of: $0, tag: run).map(decode).joined() }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What is between each `<tag …>` and `</tag>`.
    private static func pieces(of xml: String, tag: String) -> [String] {
        let name = NSRegularExpression.escapedPattern(for: tag)
        return matches("<\(name)(?:\\s[^>]*)?>(.*?)</\(name)>", in: xml).map { $0[0] }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let whole = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: whole.length)).map { match in
            (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : whole.substring(with: match.range(at: $0)) }
        }
    }

    private static func decode(_ text: String) -> String {
        var out = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#10;", "\n"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }
}
