import Foundation

/// Spots the single-line fields of a sign-in or payment form (e-mail, user name, phone, one-time code,
/// card number), where there is nothing to proofread and nothing Chirp should read. Password fields are
/// marked as secure by the app and are refused before this is asked; browsers mark only passwords that
/// way, so the rest are recognised from what the page says about the field: its label, its placeholder
/// and its id, or text that is one address being typed.
///
/// Every word is matched whole, never as part of a longer one: "Email subject", "phonebook-search" and
/// "Search email" stay ordinary fields.
public enum SignInField {
    /// Words in a field's label that name a sign-in, verification or card input.
    static let labelWords = [
        "email", "e-mail", "username", "user name", "user id", "userid", "login", "log in", "sign in",
        "phone", "mobile number", "password", "passcode", "pin", "one-time", "one time code",
        "verification code", "security code", "otp", "2fa", "two-factor", "authentication code",
        "card number", "cvc", "cvv", "expiry", "expiration",
    ]

    /// Words that make a label about writing, not about who the user is: "Email subject", "Search email".
    static let proseWords = [
        "subject", "message", "body", "preview", "title", "signature", "template", "comment", "note", "notes", "reply", "search",
    ]

    /// Parts of an id that name a credential on their own.
    static let idWords = [
        "email", "mail", "username", "userid", "login", "logon", "signin", "passwd", "password", "pwd",
        "passcode", "otp", "totp", "mfa", "2fa", "phone", "telephone", "tel", "mobile", "msisdn", "pin",
        "cvc", "cvv", "cardnumber", "identifierid", "onetimecode", "verificationcode", "securitycode", "authcode",
    ]

    /// Parts of an id that often sit beside one ("user_email", "txtPassword") and name nothing alone.
    static let idFillers = [
        "user", "account", "address", "addr", "id", "identifier", "name", "number", "num", "no", "code",
        "field", "input", "txt", "tb", "verification", "verify", "security", "auth", "onetime", "confirm",
        "current", "new", "primary", "your", "enter",
    ]

    /// Whether a field is one to leave alone. `singleLine` is true for a text field or combo box; a
    /// multi-line field labelled "email" is the body of an e-mail, which is exactly what to check.
    public static func matches(singleLine: Bool, labels: [String?], id: String?, text: String?) -> Bool {
        guard singleLine else { return false }
        if labels.contains(where: { $0.map(labelNamesSignIn) ?? false }) { return true }
        if let id, idNamesSignIn(id) { return true }
        return looksLikeAddress(text)
    }

    /// A label names a sign-in input when it has one of the words, whole, and none that make it about prose.
    public static func labelNamesSignIn(_ label: String) -> Bool {
        let label = label.lowercased()
        guard labelWords.contains(where: { hasWord($0, in: label) }) else { return false }
        return !proseWords.contains(where: { hasWord($0, in: label) })
    }

    /// An id names a sign-in input when the whole of it splits into known parts and one of them names a
    /// credential: "user_email", "loginEmail", "phonenumber2" do; "emailSearch" does not ("search" is not
    /// a known part). Case, separators and digits are ignored.
    public static func idNamesSignIn(_ id: String) -> Bool {
        let letters = Array(id.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !letters.isEmpty, letters.count <= 64 else { return false }
        // reach[i]: nil when the first i letters cannot be split, else whether a split names a credential.
        var reach = [Bool?](repeating: nil, count: letters.count + 1)
        reach[0] = false
        for start in letters.indices {
            guard let named = reach[start] else { continue }
            if letters[start].isNumber { reach[start + 1] = (reach[start + 1] ?? false) || named }
            for (word, names) in idParts where letters[start...].starts(with: word) {
                let end = start + word.count
                reach[end] = (reach[end] ?? false) || named || names
            }
        }
        return reach[letters.count] == true
    }

    /// The whole text is one address, finished or still being typed ("alice@", "alice@example.com").
    /// A slash or colon before the "@" is a link ("medium.com/@alice"), not an address.
    public static func looksLikeAddress(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return text.range(of: #"^[^\s@/:]+@[^\s@/:]*$"#, options: .regularExpression) != nil
    }

    private static let idParts: [(word: [Character], names: Bool)] = idWords.map { (Array($0), true) } + idFillers.map { (Array($0), false) }

    /// `word` is in `label` with no letter or digit right before or after it.
    private static func hasWord(_ word: String, in label: String) -> Bool {
        var range = label.startIndex..<label.endIndex
        while let found = label.range(of: word, range: range) {
            let before = found.lowerBound == label.startIndex ? nil : label[label.index(before: found.lowerBound)]
            let after = found.upperBound == label.endIndex ? nil : label[found.upperBound]
            func edge(_ c: Character?) -> Bool { c.map { !$0.isLetter && !$0.isNumber } ?? true }
            if edge(before), edge(after) { return true }
            range = found.upperBound..<label.endIndex
        }
        return false
    }
}
