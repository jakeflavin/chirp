import Foundation

/// Spots text that is keys, tokens or passwords rather than writing, so it is never checked, shown in a
/// suggestion or kept. (Found the hard way: a note of API keys got spelling underlines.)
public enum Secrets {
    /// Starts of well-known credentials.
    static let prefixes = [
        "sk-", "pk_live_", "sk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-",
        "xoxa-", "AKIA", "ASIA", "AIza", "ya29.", "eyJ", "hc_pat_", "npm_", "shpat_", "SG.", "-----BEGIN",
    ]

    /// A single word that looks like a credential: a known prefix, or long with the mix of letters and
    /// digits that words do not have.
    public static func isSecret(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;()[]{}<>"))
        guard w.count >= 16 else { return false }
        if prefixes.contains(where: { w.hasPrefix($0) }) { return true }
        guard w.count >= 20, !w.contains("://"), !w.contains("@") else { return false }
        var letters = 0, digits = 0, upper = 0, lower = 0, other = 0
        for scalar in w.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            } else if CharacterSet.uppercaseLetters.contains(scalar) {
                upper += 1
                letters += 1
            } else if CharacterSet.lowercaseLetters.contains(scalar) {
                lower += 1
                letters += 1
            } else if "-_+/=.".unicodeScalars.contains(scalar) {
                other += 1
            } else {
                return false
            }
        }
        // Hex, base64 and the like: digits among the letters, or capitals scattered through lower case.
        // A file path, a date or a dotted name ("com.example.app.settings") has neither.
        let mixedCase = upper >= 3 && lower >= 3
        return letters >= 6 && (digits >= 4 || (mixedCase && digits >= 1) || (mixedCase && w.count >= 32)) && other <= w.count / 4
    }

    /// Whether `text` holds a credential anywhere.
    public static func contains(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    /// The parts of `text` that are credentials, as UTF-16 ranges.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        let separators = CharacterSet(charactersIn: " \n\t:=")
        var start = 0
        for i in 0...ns.length {
            let atEnd = i == ns.length
            if atEnd || Unicode.Scalar(ns.character(at: i)).map(separators.contains) == true {
                if i > start, isSecret(ns.substring(with: NSRange(location: start, length: i - start))) {
                    out.append(NSRange(location: start, length: i - start))
                }
                start = i + 1
            }
        }
        return out
    }
}
