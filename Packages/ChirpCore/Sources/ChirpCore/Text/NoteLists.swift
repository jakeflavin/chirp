import Foundation

/// How a note's lists behave as you type, as in Apple Notes:
/// - Return in a list point starts the next point ("- ", "* ", "+ ", or the next number);
/// - Return on an empty point ends the list: the marker goes and the line is left blank;
/// - typing a marker ("- ", "* ", "+ ", "1. ") at the start of a point that already has the continued
///   marker replaces it rather than doubling it ("- - second").
public enum NoteLists {
    /// What Return does at the end of `lineBefore` (the line's text up to the cursor).
    public enum Return: Equatable, Sendable {
        /// Not in a list: an ordinary new line.
        case plain
        /// An empty point: take away the first `markerLength` characters (UTF-16) of the line, and no new line.
        case endList(markerLength: Int)
        /// Start the next point with this text after the new line.
        case next(String)
    }

    private static let point = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|(\\d{1,3})([.)]))[ \\t]+")

    public static func onReturn(lineBefore: String) -> Return {
        let ns = lineBefore as NSString
        guard let m = point.firstMatch(in: lineBefore, range: NSRange(location: 0, length: ns.length)) else { return .plain }
        // Only spaces after the marker: the point is empty, so the list ends.
        if ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
            return .endList(markerLength: ns.length)
        }
        var next = ns.substring(with: m.range(at: 1))
        if m.range(at: 3).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 3))) {
            next += "\(n + 1)" + ns.substring(with: m.range(at: 4)) + " "
        } else {
            next += ns.substring(with: m.range(at: 2)) + " "
        }
        return .next(next)
    }

    /// The line so far is a continued marker followed by a typed marker ("- -", "1. -", "- 1."), and a
    /// space is typed: the line becomes the typed marker alone.
    private static let doubled = try! NSRegularExpression(pattern: "^([ \\t]*)(?:[-*+]|\\d{1,3}[.)])[ \\t]+([-*+]|\\d{1,3}[.)])$")

    /// When `typed` is put at the end of `lineBefore`, what the whole of `lineBefore` should become
    /// instead (the typed text included), or nil to type it as it is.
    public static func onType(_ typed: String, lineBefore: String) -> String? {
        guard typed == " " else { return nil }
        let ns = lineBefore as NSString
        guard let m = doubled.firstMatch(in: lineBefore, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + " "
    }

    /// A note closed straight after Return in a list ends in an empty point ("- "), which would be saved as
    /// a stray "-". The empty last point is dropped; anything else is kept as it is.
    public static func droppingEmptyLastPoint(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last, lines.count > 1 || !last.isEmpty else { return markdown }
        if case .endList = onReturn(lineBefore: last) {
            lines.removeLast()
            return lines.joined(separator: "\n")
        }
        // A marker with no space after it ("-") left by the same thing.
        if ["-", "*", "+"].contains(last.trimmingCharacters(in: .whitespaces)), lines.count > 1,
            case .next = onReturn(lineBefore: lines[lines.count - 2]) {
            lines.removeLast()
            return lines.joined(separator: "\n")
        }
        return markdown
    }
}
