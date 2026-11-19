import Foundation

/// Fits dictated text to the place it is being typed: spacing and capitalisation depend on what is
/// already around the cursor.
public enum Insertion {
    /// Words that are only capitalised because they began the dictation. A dictation that continues
    /// a sentence starts with one of these in lower case; names and "I" are left alone.
    static let continuers: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "then", "because", "which", "who", "that", "this", "these",
        "those", "to", "for", "with", "without", "in", "on", "at", "of", "from", "by", "as", "if", "when", "while",
        "where", "it", "we", "you", "they", "he", "she", "is", "are", "was", "were", "will", "would", "can", "could",
        "should", "my", "our", "your", "their", "his", "her", "its", "also", "not", "just", "about", "after", "before",
        "there", "what", "how", "please", "let", "maybe", "although", "though", "until", "since", "than",
    ]

    /// The dictated text with the space and capital its surroundings call for.
    /// - Parameters:
    ///   - before: the text just before the cursor, or nil when the app does not say.
    ///   - after: the text just after the cursor, or nil when the app does not say.
    public static func adapt(_ text: String, before: String?, after: String?) -> String {
        var out = text
        guard !out.isEmpty else { return out }
        if let before, let last = before.last {
            let lastSolid = before.last { !$0.isWhitespace }
            // Continuing a sentence: do not start with a capital that was only there because speech began.
            if !last.isNewline, let lastSolid, !".!?:…".contains(lastSolid), lastSolid.isLetter || lastSolid.isNumber || ",;–—-".contains(lastSolid) {
                let firstWord = out.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
                if continuers.contains(firstWord.lowercased()), firstWord.dropFirst().allSatisfy(\.isLowercase) {
                    out = out.prefix(1).lowercased() + out.dropFirst()
                }
            }
            // A space between the existing text and the new text, unless one is there or it would follow an opening mark.
            if !last.isWhitespace, !"([{“\"'‘/".contains(last) { out = " " + out }
        }
        // A trailing space lets the next dictation carry on, unless the text after the cursor already separates it.
        if let next = after?.first {
            if !next.isWhitespace, !".,;:!?)]}”".contains(next) { out += " " }
        } else {
            out += " "
        }
        return out
    }
}

/// Things said at the end of a dictation that are instructions, not words to type.
public enum SpokenCommands {
    /// "Press enter" as the last thing said, with the comma or stop around it.
    static let enterPattern = try! NSRegularExpression(pattern: #"[,.]?\s*\bpress enter[.!]?\s*$"#, options: [.caseInsensitive])

    /// Removes a final "press enter" and reports that Return should be pressed after the text.
    public static func trailingEnter(_ text: String) -> (text: String, pressEnter: Bool) {
        let ns = text as NSString
        guard let m = enterPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return (text, false) }
        var rest = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        // "Sounds good, press enter." loses its full stop along with the command; put it back.
        if let last = rest.last, last.isLetter || last.isNumber, ns.substring(with: m.range).contains(".") { rest += "." }
        return (rest, true)
    }
}
