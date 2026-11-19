import Foundation

/// Formatting people say out loud, turned into what they meant on the page. Every rule here was written
/// against what the speech model really returns for a spoken test phrase (see `FormattingTests`).
enum SpokenFormatting {
    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // "Wait dot dot dot I am not sure" → "Wait… I am not sure". Runs before repeated words are collapsed.
    private static let ellipsis = re(#"[,.]?\s*\bdot dot dot\b[,.]?"#)

    static func applyEllipsis(_ text: String) -> String { ellipsis.replacing(in: text, with: "…") }

    // "Question mark" and "exclamation point" are almost never meant as words. "Comma", "period" and
    // "colon" often are, so they only count right before a spoken line break ("Dear Sam comma new line").
    private static let question = re(#"[,.]?\s*\bquestion mark\b[?.,]?"#)
    private static let exclamation = re(#"[,.]?\s*\bexclamation (?:point|mark)\b[!.,]?"#)
    private static let breakAhead = #"(?=[,.]?\s*(?:new line|newline|next line|new paragraph)\b)"#
    private static let beforeBreak: [(NSRegularExpression, String)] = [
        (re(#"[,.]?\s*\bcomma\b"# + breakAhead), "\u{E001}"), (re(#"[,.]?\s*\b(?:period|full stop)\b"# + breakAhead), "\u{E002}"),
        (re(#"[,.]?\s*\bcolon\b"# + breakAhead), "\u{E003}"),
    ]

    /// The line-break rule drops a comma or full stop the model put before "new line". Marks the user
    /// asked for by name are held as placeholders until that has run.
    static func restoreHeldMarks(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{E001}", with: ",").replacingOccurrences(of: "\u{E002}", with: ".")
            .replacingOccurrences(of: "\u{E003}", with: ":")
    }

    /// The marks that are safe to turn into punctuation without the user opting in.
    static func applySafePunctuation(_ text: String) -> String {
        var t = question.replacing(in: text, with: "?")
        t = exclamation.replacing(in: t, with: "!")
        for (regex, mark) in beforeBreak { t = regex.replacing(in: t, with: mark) }
        return t
    }

    // "quote … end quote", "open quote … close quote", "quote-unquote instant".
    private static let scareQuote = re(#"\bquote[- ]unquote\s+([\p{L}\p{N}'’-]+)"#)
    private static let quoted = re(#"\b(?:open quote|quote)\b[,:]?\s+([^\n]+?)[,.]?\s+\b(?:end of quote|end quote|close quote|unquote)\b"#)
    private static let parens = re(#"\bopen paren(?:thesis|theses)?\b,?\s+([^\n]+?)[,.]?\s+\bclose paren(?:thesis|theses)?\b"#)

    /// Spoken quotation marks and brackets become the marks, around the words between them.
    static func applyQuotesAndBrackets(_ text: String) -> String {
        var t = scareQuote.replacing(in: text, with: "“$1”")
        t = quoted.replacing(in: t, with: "“$1”")
        return parens.replacing(in: t, with: "($1)")
    }

    // The model writes "alex.smith at gmail.com" and "example.com slash pricing".
    private static let domain = #"((?:[a-z0-9-]+\.)+(?:com|org|net|io|co|edu|gov|dev|app|ai|me|uk|ca))"#
    private static let email = re(#"\b([a-z0-9][a-z0-9._-]*) at "# + domain + #"\b"#)
    private static let path = re(domain + #"((?:/[\w-]+)*) slash ([\w-]+)"#)
    private static let mailHosts: Set<String> = [
        "gmail", "googlemail", "outlook", "hotmail", "live", "yahoo", "icloud", "me", "mac", "aol", "proton", "protonmail", "fastmail", "hey",
    ]
    /// Words before "at example.com" that are not a mailbox name: "look at example.com".
    private static let notMailbox: Set<String> = [
        "look", "looked", "looking", "is", "was", "are", "be", "it", "up", "out", "account", "accounts", "here", "there", "go", "went",
        "check", "checked", "page", "site", "listed", "found", "available", "me", "us", "them", "him", "her", "email", "mail",
    ]

    /// Joins e-mail addresses and web paths the speech model wrote out as words.
    static func applyAddresses(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for match in email.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let local = ns.substring(with: match.range(at: 1)), host = ns.substring(with: match.range(at: 2))
            let looksLikeMailbox = local.contains { "._0123456789".contains($0) }
            let mailHost = mailHosts.contains(host.split(separator: ".").first.map { $0.lowercased() } ?? "")
            guard !notMailbox.contains(local.lowercased()), looksLikeMailbox || mailHost else { continue }
            ns.replaceCharacters(in: match.range, with: "\(local)@\(host)")
        }
        var t = ns as String
        // "example.com slash pricing slash annual" joins one step at a time.
        for _ in 0..<4 {
            let next = path.replacing(in: t, with: "$1$2/$3")
            if next == t { break }
            t = next
        }
        return t
    }

    // The model writes half past three as "3.30 p.m.".
    private static let clock = re(#"\b(\d{1,2})\.(\d{2})(?=\s?(?:a\.m\.|p\.m\.|am\b|pm\b))"#)

    static func applyTimes(_ text: String) -> String { clock.replacing(in: text, with: "$1:$2") }
}
