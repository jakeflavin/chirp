import Foundation

/// Symbols said out loud in technical dictation: flags, underscores, paths, file extensions, ports.
/// Each rule only fires where the words around it look technical, so "a dash of salt", "they slash
/// prices" and "I want to underscore the point" stay as words.
enum TechnicalSpeech {
    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: Flags

    /// Flags that are two words joined by a hyphen.
    private static let twoWordFlags: Set<String> = [
        "save dev", "dry run", "no verify", "no cache", "no edit", "no deps", "force with", "set upstream", "skip ci", "no build",
        "save exact", "no install", "allow empty", "no commit", "no ff", "ff only", "name only", "no color", "help all",
    ]
    /// "dash dash save dev": a long flag of one or two words.
    private static let longFlag = re(#"\bdash dash ([a-z][a-z0-9]*)(?: ([a-z][a-z0-9]*))?"#)
    /// "dash i" after another word: a one-letter flag. "A dash of salt" is ruled out by the word after.
    private static let shortFlag = re(#"(?<=[\p{L}\p{N}] )dash ([a-z])\b(?! (?:of|for|to|in|and)\b)"#)

    private static func applyFlags(_ text: String) -> String {
        let t = longFlag.rewriting(in: text) { match, ns in
            let first = ns.substring(with: match.range(at: 1))
            guard match.range(at: 2).location != NSNotFound else { return "--" + first }
            let second = ns.substring(with: match.range(at: 2))
            return twoWordFlags.contains("\(first) \(second)".lowercased()) ? "--\(first)-\(second)" : "--\(first) \(second)"
        }
        return shortFlag.replacing(in: t, with: "-$1")
    }

    // MARK: Underscores

    private static let underscore = re(#"\b([\p{L}\p{N}_]+) underscore ([\p{L}\p{N}]+)\b"#)
    /// "I want to underscore the point": the word before or after shows it is a verb.
    private static let verbBefore: Set<String> = ["to", "i", "we", "they", "you", "would", "will", "should", "must", "can", "that", "which", "also", "this", "it"]
    private static let objectAfter: Set<String> = ["the", "that", "this", "how", "why", "a", "an", "my", "our", "its", "their", "your", "what"]

    private static func applyUnderscores(_ text: String) -> String {
        var t = text
        for _ in 0..<6 {
            let next = underscore.rewriting(in: t) { match, ns in
                let left = ns.substring(with: match.range(at: 1)), right = ns.substring(with: match.range(at: 2))
                guard !verbBefore.contains(left.lowercased()), !objectAfter.contains(right.lowercased()) else { return nil }
                let joined = "\(left)_\(right)"
                // One part in capitals means a constant: DATABASE_URL.
                let shouts = [left, right].contains { $0.count > 1 && $0 == $0.uppercased() && $0.contains(where: \.isLetter) }
                return shouts ? joined.uppercased() : joined
            }
            if next == t { break }
            t = next
        }
        return t
    }

    // MARK: Paths, extensions, ports

    /// File extensions that "dot" is joined to: "controller dot swift".
    private static let extensions =
        "swift|json|md|js|ts|tsx|jsx|py|rb|go|rs|java|kt|c|h|cpp|css|html|yml|yaml|toml|txt|csv|sh|env|sql|xml|plist|lock|png|jpg|pdf"
    private static let fileExtension = re(#"\b([\p{L}\p{N}_-]+) dot ("# + extensions + #")\b"#)
    private static let slash = re(#"\b([\p{L}\p{N}_.~-]+) slash (?=[\p{L}\p{N}_.~-])"#)
    /// "They slash prices": a subject or helper verb before "slash" means it is a verb.
    private static let notAPath: Set<String> = ["they", "we", "i", "you", "he", "she", "it", "to", "will", "would", "could", "should", "can", "must", "not", "a", "the"]
    /// After these the path starts with a slash: "the endpoint /api/v2/users".
    private static let rooted: Set<String> = ["endpoint", "route", "path", "url", "uri"]
    private static let port = re(#"\b([\p{L}\p{N}.-]+) colon (\d{2,5})\b"#)
    private static let tilde = re(#"\b([\p{L}\p{N}_]+) tilde (\d+)\b"#)
    private static let homePath = re(#"\btilde slash "#)

    private static func applyPaths(_ text: String) -> String {
        var t = fileExtension.replacing(in: text, with: "$1.$2")
        t = homePath.replacing(in: t, with: "~/")
        for _ in 0..<12 {
            let next = slash.rewriting(in: t) { match, ns in
                let left = ns.substring(with: match.range(at: 1))
                if left.contains("/") { return left + "/" }
                let key = left.lowercased()
                if rooted.contains(key) { return left + " /" }
                return notAPath.contains(key) ? nil : left + "/"
            }
            if next == t { break }
            t = next
        }
        t = port.replacing(in: t, with: "$1:$2")
        return tilde.replacing(in: t, with: "$1~$2")
    }

    // MARK: Names in a stated case

    private static let cased = re(#"\b(called|named) ((?:[a-z][a-z0-9]*)(?: [a-z][a-z0-9]*){1,5}),? in (camel|pascal|snake|kebab) case\b"#)

    /// "Called max retry count in camel case" becomes "called maxRetryCount".
    private static func applyNaming(_ text: String) -> String {
        cased.rewriting(in: text) { match, ns in
            let words = ns.substring(with: match.range(at: 2)).lowercased().split(separator: " ").map(String.init)
            let name: String
            switch ns.substring(with: match.range(at: 3)).lowercased() {
            case "camel": name = words[0] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            case "pascal": name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            case "snake": name = words.joined(separator: "_")
            default: name = words.joined(separator: "-")
            }
            return ns.substring(with: match.range(at: 1)) + " " + name
        }
    }

    // MARK: Mentions

    private static let channel = re(#"\bat channel\b"#)

    /// Runs every rule. Names in a stated case go first, while their words are still plain words.
    static func apply(_ text: String) -> String {
        var t = applyNaming(text)
        t = applyFlags(t)
        t = applyUnderscores(t)
        t = applyPaths(t)
        return channel.replacing(in: t, with: "@channel")
    }
}

/// The kind of app the words are going into, from its bundle identifier.
public enum AppKind: Sendable, Equatable {
    case mail, chat, other

    /// Sorts an app by the start of its bundle identifier; an app that is not known is `other`.
    public init(bundleID: String?) {
        let id = (bundleID ?? "").lowercased()
        let mail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "it.bloop.airmail", "com.mimestream", "com.sparkmailapp", "com.freron.mailmate"]
        let chat = ["com.tinyspeck.slackmacgap", "com.hnc.discord", "com.microsoft.teams", "com.apple.mobilesms", "net.whatsapp", "ru.keepcoder.telegram", "org.whispersystems.signal"]
        if mail.contains(where: id.hasPrefix) { self = .mail } else if chat.contains(where: id.hasPrefix) { self = .chat } else { self = .other }
    }
}

/// Lays a dictated message out the way it is written in the app it is going into.
public enum MessageShape {
    private static func re(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: []) }

    private static let greeting = re(#"^(?:Hi|Hey|Hello|Dear|Good morning|Good afternoon|Good evening)(?: [\p{L}][\p{L}'’.-]*){0,3},[ \t]+(?=\S)"#)
    private static let signOff = re(
        #"[ \t]+(Best regards|Kind regards|Warm regards|Best wishes|Many thanks|Thank you|Thanks so much|Thanks|Best|Cheers|Regards|Sincerely|Talk soon),[ \t]+((?:\p{Lu}[\p{L}'’-]*)(?: \p{Lu}[\p{L}'’-]*)?)\.?$"#)
    private static let mention = try! NSRegularExpression(pattern: #"(^|[.!?,]\s+|\n)at (here|everyone)\b"#, options: [.caseInsensitive])

    /// A dictated letter ("Hi Sam, … Thanks, Alex") gets its greeting and sign-off on their own lines,
    /// and in a chat app "at here" becomes "@here". Text that already has line breaks is left as laid out.
    public static func apply(_ text: String, for kind: AppKind) -> String {
        guard !text.contains("\n") else { return kind == .chat ? mentions(text) : text }  // Already laid out by hand.
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let hello = greeting.firstMatch(in: text, range: whole)
        let bye = signOff.firstMatch(in: text, range: whole)
        // A greeting and a sign-off make a letter anywhere; in a mail app the greeting alone is enough.
        guard let hello, bye != nil || kind == .mail else { return kind == .chat ? mentions(text) : text }
        let bodyEnd = bye?.range.location ?? ns.length
        guard bodyEnd > hello.range.length else { return text }
        var body = ns.substring(with: NSRange(location: hello.range.length, length: bodyEnd - hello.range.length))
        body = body.prefix(1).uppercased() + body.dropFirst()
        var out = ns.substring(to: hello.range.length).trimmingCharacters(in: .whitespaces) + "\n\n" + body
        if let bye { out += "\n\n" + ns.substring(with: bye.range(at: 1)) + ",\n" + ns.substring(with: bye.range(at: 2)) }
        return out
    }

    /// "At here" and "at everyone" at the start of a clause, as chat apps write them.
    private static func mentions(_ text: String) -> String {
        mention.replacing(in: text, with: "$1@$2")
    }
}
