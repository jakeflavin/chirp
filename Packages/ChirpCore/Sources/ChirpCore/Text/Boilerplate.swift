import Foundation

/// Takes advertisements and boilerplate out of a text before it is summarized: sponsor blocks, newsletter
/// headers and footers, cookie notices, sign-up boxes, "Read more" lists, share buttons and the like.
/// Content extractors make these tests on a page's HTML; Chirp only has the text, so they are made on
/// lines. What goes is only ever whole lines that match, and the short block an ad line introduces.
/// Read aloud and the saved document keep the text as it was.
public enum Boilerplate {
    /// The text without its ads and boilerplate, as paragraphs (one per line, a fenced block of code as one) in their order.
    public static func strip(_ text: String) -> String {
        strip(blocks: blocks(of: text)).joined(separator: "\n\n")
    }

    /// The text's lines, without empty ones, with a fenced block of code kept whole as one.
    static func blocks(of text: String) -> [String] {
        var out: [String] = []
        var fence: [String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                fence?.append(raw)
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    out.append(fence!.joined(separator: "\n"))
                    fence = nil
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = [line]
                continue
            }
            if !line.isEmpty { out.append(line) }
        }
        if let open = fence { out.append(open.joined(separator: "\n")) }
        return out
    }

    /// The blocks that stay. A block of code always stays.
    static func strip(blocks all: [String]) -> [String] {
        // A paper's front matter (journal line, authors, affiliations, keywords) and a PDF's running header first.
        let lines = withoutFrontMatter(withoutRunningLines(all))
        let total = lines.reduce(0) { $0 + $1.count }
        var keep = [Bool](repeating: true, count: lines.count)
        func code(_ k: Int) -> Bool { lines[k].hasPrefix("```") || lines[k].hasPrefix("~~~") }
        var position = 0
        var i = 0
        while i < lines.count {
            let line = lines[i]
            var next = i + 1
            defer {
                position += lines[i..<next].reduce(0) { $0 + $1.count }
                i = next
            }
            if code(i) { continue }
            // A footer line near the end: it and everything after it go.
            if isFooter(line), position * 10 >= total * 6, TextStats.words(line) <= 40 {
                for k in i..<lines.count where !code(k) { keep[k] = false }
                next = lines.count
                continue
            }
            if startsAd(line) {
                // The sponsor line, the ad's own paragraph, and the button under it.
                keep[i] = false
                if next < lines.count, !code(next), isProse(lines[next]) || (TextStats.words(lines[next]) >= 6 && !looksLikeHeading(lines[next], after: lines[safe: next + 1])) {
                    keep[next] = false
                    next += 1
                }
                if next < lines.count, !code(next), isButton(lines[next]) {
                    keep[next] = false
                    next += 1
                }
                continue
            }
            if isLine(line) || (isPostalAddress(line) && position * 10 >= total * 5) {
                keep[i] = false
                continue
            }
            if isSignUp(line) || isCookieNotice(line) {
                // The box: the line, a short pitch after it, and its field and button.
                keep[i] = false
                if next < lines.count, !code(next), TextStats.words(lines[next]) <= 40, isPitch(lines[next]) {
                    keep[next] = false
                    next += 1
                }
                while next < lines.count, !code(next), isButton(lines[next]) || isFormField(lines[next]) {
                    keep[next] = false
                    next += 1
                }
                // A cookie notice's own heading ("We value your privacy") is the line before it.
                if isCookieNotice(line), i > 0, keep[i - 1], !code(i - 1), TextStats.words(lines[i - 1]) <= 6, !isProse(lines[i - 1]) { keep[i - 1] = false }
                continue
            }
            if isRelatedHeading(line), position >= 500 {
                // "Related posts", "Trending this week": the heading and the short link titles under it, up to prose
                // or the next heading with prose under it.
                keep[i] = false
                while next < lines.count, !code(next), !isProse(lines[next]), TextStats.words(lines[next]) <= 14,
                    !(looksLikeHeading(lines[next], after: lines[safe: next + 1]) && isProse(lines[safe: next + 1] ?? ""))
                {
                    keep[next] = false
                    next += 1
                }
                continue
            }
        }
        return lines.indices.filter { keep[$0] }.map { lines[$0] }
    }

    // MARK: What a line is

    /// A line that is boilerplate wherever it is: a newsletter's header row, a button, a counter, a page number,
    /// a read-time or a "skip to" link. Used for the title too, so a document is never named after one.
    public static func isLine(_ line: String) -> Bool {
        let l = normal(line)
        if l.isEmpty { return true }
        if isButton(line) || isNavRow(line) { return true }
        // Social counters, and reactions on their own ("👍 23").
        if l.range(of: #"^\d+\s+(likes?|comments?|shares?|retweets?|reposts?|restacks?)$"#, options: .regularExpression) != nil { return true }
        if !line.contains(where: { $0.isLetter }), line.contains(where: { $0.isNumber }) || line.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        // A page number or running page line from a PDF.
        if l.range(of: #"^page \d+( of \d+)?$"#, options: .regularExpression) != nil { return true }
        // Read-time and "listen" widgets.
        if l.range(of: #"^\d+\s*min(ute)?s?\s+read$"#, options: .regularExpression) != nil { return true }
        if ["listen to this article", "listen to this story", "skip to main content", "skip to content", "jump to navigation", "jump to search",
            "advertisement", "sponsored content", "advertising", "ad", "sponsored"].contains(l) { return true }
        // A line of only badge images or links (a README's build badges).
        if line.hasPrefix("[![") || (line.hasPrefix("![") && !line.contains(" ") ) { return true }
        if l.hasPrefix("this article needs additional citations") { return true }
        // "View this email in your browser", "Having trouble viewing this email? View it online."
        if l.range(of: #"^(view|read) (this )?(e-?mail|newsletter|issue|post)? ?(in (your|a) (web )?browser|online|on the web)\b"#, options: .regularExpression) != nil { return true }
        if l.hasPrefix("having trouble viewing") { return true }
        return false
    }

    /// A line no document should be named after: boilerplate, a sponsor line, a cookie notice or a sign-up box.
    public static func isTitleNoise(_ line: String) -> Bool {
        isLine(line) || startsAd(line) || isCookieNotice(line) || isSignUp(line) || isFooter(line) || isJournalLine(line) || isAuthorList(line)
    }

    /// A short line that is a button or a link of a page's furniture.
    static func isButton(_ line: String) -> Bool {
        let l = normal(line).trimmingCharacters(in: CharacterSet(charactersIn: " →›»>.!"))
        guard TextStats.words(l) <= 7, !l.isEmpty else { return false }
        if buttons.contains(l) { return true }
        // "Read more", "Try Quillstack free", "Claim the offer": a call to act that is not a sentence.
        if l.hasPrefix("read more") || l.hasPrefix("continue reading") { return true }
        let first = l.split(separator: " ").first.map(String.init) ?? ""
        return (2...5).contains(TextStats.words(l)) && !line.hasSuffix(".") && ["try", "claim", "get", "start", "open", "book", "shop", "download", "join", "order", "subscribe", "sign", "register", "learn", "accept", "reject", "manage", "follow", "share"].contains(first)
            && !line.contains(":")
    }

    static let buttons: Set<String> = [
        "subscribe", "subscribe now", "sign up", "sign in", "log in", "login", "register", "share", "share this", "share this article",
        "share this post", "share this story", "like", "comment", "comments", "restack", "reply", "leave a comment", "leave a reply", "follow",
        "follow us", "get the app", "start writing", "accept", "accept all", "reject all", "accept all cookies", "reject optional cookies",
        "accept optional cookies", "cookie settings", "cookie preferences", "manage settings", "manage cookies", "i accept", "i agree", "agree",
        "privacy", "privacy policy", "terms", "terms of use", "terms of service", "cookies", "contact us", "advertise", "mobile view", "yes", "no",
        "was this page helpful?", "was this page useful?", "was this page helpful", "was this page useful", "report a problem with this page",
        "facebook", "twitter", "x", "linkedin", "instagram", "pinterest", "email", "print", "search", "menu", "home", "write", "preview",
        "back to top", "view online", "view in browser", "sponsored", "advertisement", "read next", "see more", "load more", "show more",
    ]

    /// A newsletter's header or footer row: "Sign Up | Advertise | View Online", "Unsubscribe · Manage preferences".
    static func isNavRow(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 16 else { return false }
        let found = navWords.filter { l.contains($0) }.count
        let separated = line.contains("|") || line.contains("·") || line.contains("•")
        return found >= 2 && (separated || TextStats.words(l) <= 8) || (found >= 1 && separated && TextStats.words(l) <= 8 && !isProse(line))
    }

    static let navWords = [
        "sign up", "advertise", "view online", "view in browser", "view this email", "view it online", "forward to a friend",
        "forward this email", "subscribe", "unsubscribe", "manage preferences", "update your preferences", "privacy policy", "terms",
        "cookie", "contact us", "log in", "sign in", "read online", "web version",
    ]

    /// The first line of a sponsor block (a "sponsored" line, as newsletters write it).
    static func startsAd(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 16 else { return false }
        if l.range(of: #"^(together with|presented by|sponsored by|brought to you by|in partnership with|a message from|today's sponsor|this issue is sponsored)\b"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"\((sponsor|sponsored|ad|advertisement|partner)\)$"#, options: .regularExpression) != nil { return true }
        return ["sponsored", "sponsor", "advertisement", "sponsored content", "partner content", "paid post", "promoted", "ad"].contains(l)
    }

    /// A newsletter sign-up, and the ways paid newsletters ask the same.
    static func isSignUp(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 60 else { return false }
        let patterns = [
            #"\bsubscribe\b.{0,40}\bnewsletter\b"#, #"\bnewsletter\b.{0,40}\bsubscribe\b"#, #"\bsign[- ]up\b.{0,80}\b(newsletter|email alert)"#,
            #"\b(don't (want to )?miss|never miss)\b.{0,80}\b(latest|best|exclusive|reports?|updates?|source)"#,
            #"^(get|join) (the|our) .{0,40}newsletter"#, #"\bsubscribe for free\b"#, #"\bsubscribe to (receive|get)\b"#,
            #"\b(reader-supported|free or paid subscriber)\b"#, #"^did someone forward (you )?this"#,
            #"\b(forward|share) (it|this)( newsletter| email| e-mail)? (to|with) a friend\b"#, #"\breferrals?\b.{0,80}\b(friends?|rewards?)\b"#,
            #"\brefer \d+ friends?\b"#,
        ]
        return patterns.contains { l.range(of: $0, options: .regularExpression) != nil }
    }

    /// A cookie banner's paragraph.
    static func isCookieNotice(_ line: String) -> Bool {
        let l = normal(line)
        guard l.contains("cookie"), TextStats.words(l) <= 80 else { return false }
        return ["accept", "agree", "consent", "we use", "uses cookies", "use cookies", "our partners", "optional"].contains { l.contains($0) }
    }

    /// The short pitch under a sign-up line.
    static func isPitch(_ line: String) -> Bool {
        let l = normal(line)
        return ["inbox", "join ", "free", "subscribe", "newsletter", "no spam", "every week", "every sunday", "every friday", "once a month", "delivered"].contains { l.contains($0) }
    }

    /// An email field's placeholder.
    static func isFormField(_ line: String) -> Bool {
        let l = normal(line)
        return TextStats.words(l) <= 5 && (l.contains("email") || l.contains("e-mail")) && !line.hasSuffix(".")
    }

    /// Related-content and call-to-action headings.
    static func isRelatedHeading(_ line: String) -> Bool {
        let l = normal(line).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        guard TextStats.words(l) <= 8 else { return false }
        let pattern = #"^(related (posts?|articles?|content|stories|reads?|reading)|you (might|may|could) (also )?(like|enjoy|be interested in)|read (next|more|also)|further reading|more (from .*|articles?|posts?|stories|like this)|more to (read|explore)|explore more|about (the )?author|recommended( for you)?|trending( now| this week)?|most (read|popular)|popular (posts|stories|articles)|from the archive|see also|latest (news|posts|articles|stories))$"#
        return l.range(of: pattern, options: .regularExpression) != nil
    }

    /// A line that ends a page or a message: what comes after it is footer (a page's
    /// boilerplate, and the footers of emails and newsletters).
    static func isFooter(_ line: String) -> Bool {
        let l = normal(line)
        let patterns = [
            #"^©\s*(copyright\s+)?\d{4}"#, #"^copyright ©?\s*\d{4}"#, #"all rights reserved"#, #"^you (are receiving|received) this (e-?mail|message|newsletter)"#,
            #"^you're receiving this"#, #"^if you (don't|do not|no longer) want to receive"#, #"^to unsubscribe"#, #"^unsubscribe\b"#,
            #"^(update|manage) your (email )?(preferences|subscription)"#, #"^this (e-?mail|message) and any attachments"#, #"^confidentiality notice"#,
            #"^please do not reply to this (e-?mail|message)"#, #"^sent from my (iphone|ipad|android|mobile)"#, #"^want to advertise"#,
            #"^powered by\b"#, #"^leave a (comment|reply)$"#, #"^comments \(\d+\)$"#, #"^was this page (helpful|useful)\??$"#,
            #"^categories:"#, #"^this page was last edited"#, #"^text is available under the creative commons"#, #"^share this (article|post|story)$"#,
            #"^remember, contributions to this repository"#, #"^follow us on\b"#,
            // An email's footer (a promotion's "do not click" and address lines are not content).
            #"^you('re| are)? (are )?(receiving|received|getting|get) this (e-?mail|message|newsletter)?\s?because"#, #"\bthis (e-?mail|message) was sent to\b"#,
            #"^(this (e-?mail|message) was )?(sent|delivered) to [^ ]+@"#, #"\bdo not (click|forward)\b.{0,60}\b(link|e-?mail|message)"#,
            #"^if you no longer wish to"#, #"^to stop receiving"#, #"^(click|tap) here to unsubscribe"#, #"^no longer want (to receive )?these"#,
            #"^(manage|change) (your )?(e-?mail )?(preferences|settings|subscription)"#, #"^(unsubscribe|opt out)( here)?\s*[|·•]"#,
        ]
        return patterns.contains { l.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Front matter and running lines

    /// A paper's front matter, before its abstract or its first section: the journal line, the author list, the
    /// affiliations, the keywords, the received and correspondence lines. The title stays. Only taken out when the text
    /// looks like a paper (a journal line, an abstract or keywords near its start), so an email's names are never touched.
    static func withoutFrontMatter(_ lines: [String]) -> [String] {
        let head = Array(lines.prefix(16))
        guard head.contains(where: { isJournalLine($0) || isKeywords($0) || normal($0).range(of: #"^abstract\b"#, options: .regularExpression) != nil }) else { return lines }
        // The front ends at the abstract, or at the first paragraph of prose.
        let end = lines.indices.prefix(20).first { i in
            normal(lines[i]).range(of: #"^abstract\b"#, options: .regularExpression) != nil || (isProse(lines[i]) && !isAffiliation(lines[i]))
        } ?? min(lines.count, 12)
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if i < end, isJournalLine(line) || isAuthorList(line) || isAffiliation(line) { continue }
            // Keywords, and the received and correspondence lines, sit just before or after the abstract.
            if i < 30, isKeywords(line) || (isFrontLine(line) && TextStats.words(line) <= 20) { continue }
            out.append(line)
        }
        return out
    }

    /// "Journal of Urban Health Studies, Vol. 41, No. 3 (2026), pp. 211-229", "doi:10.1000/xyz", "arXiv:2401.01234".
    public static func isJournalLine(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 25 else { return false }
        if l.range(of: #"^(doi:|https?://(dx\.)?doi\.org|arxiv:|issn\b|e-?issn\b|isbn\b)"#, options: .regularExpression) != nil { return true }
        let volume = l.range(of: #"\b(vol\.?|volume)\s*\d+"#, options: .regularExpression) != nil
        let issue = l.range(of: #"\b(no\.?|issue)\s*\d+|\bpp\.?\s*\d+|\(\d{4}\)|\b\d{4};\s*\d+"#, options: .regularExpression) != nil
        return volume && issue
    }

    /// "Keywords: urban heat island, tree canopy".
    static func isKeywords(_ line: String) -> Bool {
        normal(line).range(of: #"^(keywords|key words|index terms)\s*[:—–.-]"#, options: .regularExpression) != nil
    }

    /// "Received 3 May 2025; accepted 1 June", "Correspondence: …", "*Corresponding author", an email address alone.
    static func isFrontLine(_ line: String) -> Bool {
        let l = normal(line)
        return l.range(of: #"^(received|accepted|published( online)?|correspondence|\*?\s*corresponding author|e-?mail:|orcid)\b"#, options: .regularExpression) != nil
            || (TextStats.words(l) <= 3 && l.contains("@"))
    }

    /// "Elena Vasquez¹, Thomas Albright², Grace Mbeki¹": two or more names and nothing else, marked or joined by commas.
    static func isAuthorList(_ line: String) -> Bool {
        let cleaned = line.replacingOccurrences(of: #"[¹²³⁴⁵⁶⁷⁸⁹⁰*†‡§]|\d"#, with: "", options: .regularExpression)
        let names = cleaned.components(separatedBy: CharacterSet(charactersIn: ",;")).flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count >= 2 || line.range(of: #"[¹²³⁴⁵⁶⁷⁸⁹*†]"#, options: .regularExpression) != nil, TextStats.words(cleaned) <= 30, !line.hasSuffix(".") else { return false }
        return names.allSatisfy { name in
            let parts = name.split(separator: " ")
            return (2...4).contains(parts.count) && parts.allSatisfy { p in
                p.first?.isUppercase == true || ["de", "van", "von", "der", "da", "di", "la", "le"].contains(p.lowercased())
            }
        }
    }

    /// "¹ Department of Environmental Health, Lakeshore University".
    static func isAffiliation(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 25 else { return false }
        let marked = line.range(of: #"^\s*([¹²³⁴⁵⁶⁷⁸⁹*†‡]|\d\s)"#, options: .regularExpression) != nil
        let place = l.range(of: #"\b(university|universit[äé]|institute|college|department|dept\.|school of|faculty of|laborator(y|ies)|centre for|center for|hospital|research cent(er|re))\b"#, options: .regularExpression) != nil
        return place && (marked || !line.hasSuffix("."))
    }

    /// A PDF's running header or footer: a short line that is repeated on three or more pages ("Vasquez et al. · Street
    /// Trees", "Journal of Urban Health Studies 41(3)"). Every copy goes. Only in text with page numbers.
    static func withoutRunningLines(_ lines: [String]) -> [String] {
        // Only in text laid out in pages: two or more page numbers on lines of their own.
        let pageNumbers = lines.filter { normal($0).range(of: #"^(page )?\d{1,4}( of \d+)?$"#, options: .regularExpression) != nil }.count
        guard pageNumbers >= 2 else { return lines }
        var seen: [String: Int] = [:]
        for line in lines where TextStats.words(line) <= 14 && !line.hasPrefix("```") { seen[normal(line), default: 0] += 1 }
        let running = Set(seen.filter { $0.value >= 3 && $0.key.contains(where: \.isLetter) && !$0.key.hasPrefix("#") && !$0.key.hasPrefix("-") }.keys)
        guard !running.isEmpty else { return lines }
        return lines.filter { !running.contains(normal($0)) }
    }

    /// A postal address line in an email's or a page's footer: "6050 Washington St., Culver City, CA 90232",
    /// "PO Box 123", "Suite 400, 1 Main Street".
    static func isPostalAddress(_ line: String) -> Bool {
        let l = normal(line)
        guard TextStats.words(l) <= 22, !isProse(line) || TextStats.words(l) <= 14 else { return false }
        let street = l.range(of: #"\b\d{1,6}\s+[a-z0-9.' -]{2,40}\s(st|street|ave|avenue|rd|road|blvd|boulevard|dr|drive|ln|lane|way|ct|court|pl|place|pkwy|parkway|hwy|highway|sq|square)\b\.?"#, options: .regularExpression) != nil
            || l.range(of: #"\b(p\.?\s?o\.? box|suite \d+)\b"#, options: .regularExpression) != nil
        let town = line.range(of: #",\s*[A-Z]{2}\s+\d{5}(-\d{4})?\b|\b[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2}\b"#, options: .regularExpression) != nil
        return street && (town || TextStats.words(l) <= 12) || town && TextStats.words(l) <= 12
    }

    // MARK: Helpers

    static func normal(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }


    static func isProse(_ line: String) -> Bool { PageText.isProse(line) }

    static func looksLikeHeading(_ line: String, after next: String?) -> Bool {
        SummaryPlan.isHeading(line, next: next) || ReadingText.isHeadingMark(line)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
