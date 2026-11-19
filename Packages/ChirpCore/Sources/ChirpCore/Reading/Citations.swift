import Foundation

/// Finds the marks in a text that point at a source and are not part of what it says: "[12]",
/// "(Smith, 2020)" and small raised note numbers. They are left out when a text is read aloud.
///
/// Only marks that can hardly be anything else are taken. Text in brackets that is part of the
/// writing stays: "[sic]", "(see below)", "(2020)", "(May 2020)", "[1987]".
public enum Citations {
    /// `text` without its citation marks. The space before a mark goes with it, so "large [3]." is "large.".
    public static func removing(from text: String) -> String {
        var s = numbered.replacing(in: text, with: "")
        s = authorYear.rewriting(in: s) { match, original in
            isAuthorYear(original.substring(with: match.range)) ? "" : nil
        }
        s = raised.replacing(in: s, with: "")
        return s
    }

    /// "[12]", "[3, 4]", "[5–7]", "[1][2]": one to three digits, so a year in brackets ("[1987]") stays.
    private static let numbered = try! NSRegularExpression(pattern: #"[ \t]*\[\d{1,3}(?:\s*[,–-]\s*\d{1,3})*\]"#)

    /// Raised digits straight after a word of three letters or more, or after the mark that ends a
    /// clause: "found¹", "found.¹²", "found,³⁻⁵". After a shorter word they are left, because that is
    /// how a unit or a letter is squared ("m²", "km²", "x²").
    private static let raised = try! NSRegularExpression(
        pattern: #"(?<=\p{L}{3}|[\p{L}\d][.,;:!?”"’')\]]|[.,;:!?][”"’')\]])[⁰¹²³⁴⁵⁶⁷⁸⁹]+(?:[,⁻][⁰¹²³⁴⁵⁶⁷⁸⁹]+)*"#)

    /// One writer's name: a capital letter and more letters, with a small word before it if it has one ("van Dijk").
    private static let name = #"(?:(?:van|von|de|del|della|der|den|di|da|la|le|al|bin|ibn)\s+)*\p{Lu}[\p{L}'’\-]+"#
    /// One or more names: "Smith", "Smith and Jones", "Smith, Jones & Lee", "Smith et al.".
    private static let names = name + #"(?:(?:\s*,\s*(?:(?:and|&)\s+)?|\s+(?:and|&)\s+)"# + name + #")*(?:,?\s+et\s+al\.?)?"#
    /// A year, with a letter after it when a writer has two in one year, and a page if one is given.
    private static let year = #"(?:1[5-9]|20)\d{2}[a-z]?(?:\s*,\s*(?:1[5-9]|20)\d{2}[a-z]?)*(?:\s*,\s*(?:pp?\.|ch\.|chap\.)\s*\d+(?:\s*[–-]\s*\d+)?)?"#
    /// One source: names, then a year.
    private static let source = names + #",?\s+"# + year
    /// Round brackets holding nothing but sources: "(Smith 2020)", "(Smith & Jones, 2019; Lee et al., 2021)",
    /// "(see Smith, 2020, p. 14)".
    private static let authorYear = try! NSRegularExpression(
        pattern: #"[ \t]*\((?:(?:see also|see|e\.g\.,?|cf\.)\s+)?"# + source + #"(?:\s*;\s*(?:(?:see also|see|and)\s+)?"# + source + #")*\)"#)

    /// Words that begin with a capital and are followed by a year without being anyone's name.
    private static let notNames: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "spring", "summer", "autumn", "fall", "winter", "easter", "christmas",
        "fiscal", "version", "edition", "circa", "since", "until", "before", "after", "during", "around", "about", "early", "late", "mid",
        "in", "by", "from", "to", "of", "est", "founded", "born", "died", "copyright", "revised", "updated", "published", "released",
        "act", "law", "census", "budget", "olympics", "expo", "election", "season", "class", "model", "windows", "office",
    ]

    /// Whether brackets that have the shape of a source really are one: not "(May 2020)" or "(Fiscal 2021)".
    private static func isAuthorYear(_ match: String) -> Bool {
        let inside = match.trimmingCharacters(in: CharacterSet(charactersIn: " \t()"))
        for part in inside.components(separatedBy: ";") {
            var words = part.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
            while let first = words.first, ["see", "also", "e.g.", "cf.", "and"].contains(first) { words.removeFirst() }
            if let first = words.first, notNames.contains(first) { return false }
        }
        return true
    }
}
