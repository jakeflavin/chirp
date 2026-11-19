import Foundation

/// Regular expressions written as pattern strings where they are used. Building one is slow next to
/// running it, and the text rules run on every dictation and every sentence read aloud, so each
/// pattern is built once and kept.
enum Patterns {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var built: [String: NSRegularExpression] = [:]

    /// The expression for `pattern`, or nil when the pattern is not valid.
    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue) \(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let regex = built[key] { return regex }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        built[key] = regex
        return regex
    }
}

extension NSRegularExpression {
    /// `text` with every match replaced by `template` ("$1" stands for the first group).
    func replacing(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// `text` with each match replaced by what `transform` returns for it; a match it returns nil for
    /// is left as it is. Works from the end so the earlier matches' positions stay valid.
    func rewriting(in text: String, _ transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            if let new = transform(match, original) { result.replaceCharacters(in: match.range, with: new) }
        }
        return result as String
    }
}
