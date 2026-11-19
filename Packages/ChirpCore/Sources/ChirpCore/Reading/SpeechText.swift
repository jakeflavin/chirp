import Foundation

/// Rewrites what the voice is about to read into words it says properly.
///
/// The voice's own text front end already handles money, percentages, dates, titles ("Dr.") and most
/// units. These are the things it was heard to get wrong (checked by the sounds it produced):
/// "25 s" as the letter S, "Main St." as "stat", "## Heading" as "hash hash", phone numbers as one big
/// number, "1920x1080" digit by digit, "3:1", "10–20", "9am", "No. 5", "$400K" and version numbers.
///
/// A number with K, M or B after it is read as written ("5K" is "five K", which is right for a race and
/// understood for a count); with a currency sign before it, it is money ("$5K" is "five thousand dollars").
public enum SpeechText {
    /// `text` as the voice should be given it. Markdown marks go first, so the rules after them see
    /// plain words; numbers go before units, so "9am" is a time before "9 a" could be anything else.
    public static func spoken(_ text: String) -> String {
        var s = text
        s = markdown(s)
        s = symbols(s)
        s = numbers(s)
        s = units(s)
        s = abbreviations(s)
        s = romanNumerals(s)
        s = accents(s)
        return replace(s, #"[ \t]{2,}"#, " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Markdown and other marks that are layout, not words

    /// Removes Markdown marks, keeping the words they mark. Only spaces and tabs are taken with a mark,
    /// never a line break, so paragraphs stay apart.
    static func markdown(_ text: String) -> String {
        var s = text
        // Headings, quotes and list bullets at the start of a line.
        s = replace(s, #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, "")
        s = replace(s, #"(?m)^[ \t]{0,3}>[ \t]?"#, "")
        s = replace(s, #"(?m)^[ \t]*[-*+•◦▪][ \t]+(\[[ xX]\][ \t]+)?"#, "")
        // Images go; links keep their words.
        s = replace(s, #"!\[[^\]]*\]\([^)]*\)"#, "")
        s = replace(s, #"\[([^\]]+)\]\((?:[^)]*)\)"#, "$1")
        // Emphasis, strike-through and code marks.
        s = replace(s, #"(\*\*|__|~~|`{1,3})"#, "")
        s = replace(s, #"(?<![\w*])\*(?=\S)([^*\n]+)(?<=\S)\*(?![\w*])"#, "$1")
        s = replace(s, #"(?<![\w_])_(?=\S)([^_\n]+)(?<=\S)_(?![\w_])"#, "$1")
        // Table bars and rules.
        s = replace(s, #"(?m)^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t]*$"#, "")
        s = replace(s, #"\s*\|\s*"#, ", ")
        s = replace(s, #"(?m)^[ \t]*([-*_][ \t]?){3,}$"#, "")
        return s
    }

    /// Symbols the voice skips or misreads, as the words a person would say for them.
    static func symbols(_ text: String) -> String {
        var s = text
        // Emoji and pictographs are not read out, nor the invisible joiners that hold a group of them together.
        s = String(s.unicodeScalars.filter {
            !($0.properties.isEmojiPresentation || (0x1F300...0x1FAFF).contains($0.value) || $0.value == 0xFE0F || $0.value == 0x200D)
        })
        s = replace(s, #"\s*(→|⇒|->|=>)\s*"#, " to ")
        s = replace(s, #"(?i)\b(about|around|roughly|approximately)\s[~≈](?=\s?\$?\d)"#, "$1 ")
        s = replace(s, #"[~≈](?=\s?\$?\d)"#, "about ")
        s = replace(s, #"\bw/o\b"#, "without")
        s = replace(s, #"\bw/(?=\s|\w)"#, "with ")
        s = replace(s, #"(?<=\w)\s&\s(?=\w)"#, " and ")
        s = replace(s, #"(?<![\w&])#(\d+)\b"#, "number $1")
        s = replace(s, #"\b24/7\b"#, "twenty-four seven")
        s = replace(s, #"\b50/50\b"#, "fifty-fifty")
        return s
    }

    // MARK: Numbers written in ways the voice misreads

    /// Phone numbers, dates, sizes, versions, money, times, ratios and ranges, as they are said.
    static func numbers(_ text: String) -> String {
        var s = text
        // Phone numbers, digit by digit: 555-0199, 415-555-0199, (415) 555-0199.
        s = replacing(s, #"(?<![\d-])\(?(\d{3})\)?[-. ](\d{3})[-. ](\d{4})(?![\d-])"#) { m in
            "\(digits(m[1])), \(digits(m[2])), \(digits(m[3]))"
        }
        s = replacing(s, #"(?<![\d-])(\d{3})-(\d{4})(?![\d-])"#) { m in "\(digits(m[1])), \(digits(m[2]))" }
        // 2026-11-15 as a date.
        s = replacing(s, #"\b(\d{4})-(\d{2})-(\d{2})\b"#) { m in
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            guard let month = Int(m[2]), (1...12).contains(month), let day = Int(m[3]), (1...31).contains(day) else { return m[0] }
            return "\(months[month - 1]) \(day), \(m[1])"
        }
        // Screen sizes and the like: 1920x1080 is "1920 by 1080".
        s = replace(s, #"\b(\d+(?:\.\d+)?)\s?[x×]\s?(\d+(?:\.\d+)?)\b"#, "$1 by $2")
        // 3x is "three times".
        s = replace(s, #"\b(\d+(?:\.\d+)?)[x×](?![\w×])"#, "$1 times")
        // Versions and addresses: 2.0.1 is "two point zero point one".
        s = replacing(s, #"(?<![\d.])(\d+(?:\.\d+){2,})(?![\d.]*\d)"#) { m in m[1].replacingOccurrences(of: ".", with: " point ") }
        // Money with K, M or B is expanded: $400K, £5k, €3B.
        s = replacing(s, #"([$£€])(\d[\d,]*(?:\.\d+)?)\s?([KkMmBb])\b"#) { m in
            let word = ["k": "thousand", "m": "million", "b": "billion"][m[3].lowercased()] ?? ""
            let money = ["$": "dollars", "£": "pounds", "€": "euros"][m[1]] ?? ""
            return "\(m[2]) \(word) \(money)"
        }
        // Without a currency sign it is read as written: "5K" is "five K", the letter said as a letter
        // (a 5K is a race, and "12k people" is understood). Writing "thousand" would make "5K, 10K" come out
        // "five thousand, ten thousand" and "5-10K" "five to ten thousand". The
        // voice already says "5M" and "3B" as letters; set apart from its number, it says K as one too.
        s = replacing(s, #"\b(\d[\d,]*(?:\.\d+)?)[Kk]\b"#) { m in "\(m[1]) K" }
        // 9am, 9 pm, 5:30PM.
        // Written as two capital letters apart, which the voice spells out ("ay em"). It read both "a.m." and
        // "AM" as the word "am".
        s = replacing(s, #"\b(\d{1,2}(?::\d{2})?)\s?([AaPp])\.?[Mm]\b(\.?)"#) { m in "\(m[1]) \(m[2].uppercased()) M\(m[3])" }
        s = replace(s, #"\b(\d+)\^(\d+)\b"#, "$1 to the power of $2")
        s = replace(s, #"\bUSD\s?(\d[\d,]*(?:\.\d+)?)"#, "$1 U.S. dollars")
        // 3:1 is "three to one" (a time has two digits after the colon and is left alone).
        s = replace(s, #"\b(\d{1,3}):(\d)\b(?!:)"#, "$1 to $2")
        // Ranges: 10–20 always; 12-15 when it reads as a range and not a code or a score going down.
        s = replace(s, #"(\d)\s?[–—]\s?(?=\$?\d)"#, "$1 to ")
        s = replacing(s, #"(?<![\d-])(\d{1,4})-(\d{1,4})(?![\d-])"#) { m in
            guard let a = Int(m[1]), let b = Int(m[2]), b > a, !m[2].hasPrefix("0") else { return m[0] }
            return "\(m[1]) to \(m[2])"
        }
        // No. 5 is "number five".
        s = replace(s, #"\bNo\.\s?(?=\d)"#, "number ")
        return s
    }

    /// "555" as "5 5 5", so each digit is said on its own.
    private static func digits(_ s: String) -> String { s.map(String.init).joined(separator: " ") }

    // MARK: Units after a number

    /// Unit abbreviation, singular, plural. Matched exactly as written: "MB" is megabytes, "Mb" megabits.
    static let unitNames: [(String, String, String)] = [
        ("ms", "millisecond", "milliseconds"), ("s", "second", "seconds"), ("sec", "second", "seconds"), ("secs", "second", "seconds"),
        ("h", "hour", "hours"), ("hrs", "hour", "hours"),
        ("KB", "kilobyte", "kilobytes"), ("MB", "megabyte", "megabytes"), ("GB", "gigabyte", "gigabytes"), ("TB", "terabyte", "terabytes"),
        ("kB", "kilobyte", "kilobytes"), ("Mb", "megabit", "megabits"), ("Gb", "gigabit", "gigabits"),
        ("Mbps", "megabit per second", "megabits per second"), ("Gbps", "gigabit per second", "gigabits per second"),
        ("kbps", "kilobit per second", "kilobits per second"),
        ("px", "pixel", "pixels"), ("fps", "frame per second", "frames per second"), ("dpi", "dot per inch", "dots per inch"),
        ("Hz", "hertz", "hertz"), ("kHz", "kilohertz", "kilohertz"), ("MHz", "megahertz", "megahertz"), ("GHz", "gigahertz", "gigahertz"),
        ("W", "watt", "watts"), ("kW", "kilowatt", "kilowatts"), ("kWh", "kilowatt hour", "kilowatt hours"), ("mAh", "milliamp hour", "milliamp hours"),
        ("mm", "millimeter", "millimeters"), ("ml", "milliliter", "milliliters"), ("mL", "milliliter", "milliliters"),
        ("mg", "milligram", "milligrams"), ("g", "gram", "grams"), ("lb", "pound", "pounds"), ("lbs", "pound", "pounds"), ("oz", "ounce", "ounces"),
        ("ft", "foot", "feet"), ("yd", "yard", "yards"), ("sq ft", "square foot", "square feet"), ("bn", "billion", "billion"),
    ]

    /// One expression per unit, longest unit first so "ms" is not read as "m" and "s". Built once.
    private static let unitPatterns: [(regex: NSRegularExpression, unit: String, one: String, many: String)] =
        unitNames.sorted { $0.0.count > $1.0.count }.map { unit, one, many in
            let pattern = #"(?<![\w.])(\d[\d,]*(?:\.\d+)?)( ?)"# + NSRegularExpression.escapedPattern(for: unit) + #"(?![\w°])"#
            return (try! NSRegularExpression(pattern: pattern), unit, one, many)
        }

    /// A unit's abbreviation after a number, as its name: "25 s" is "25 seconds".
    static func units(_ text: String) -> String {
        var s = text
        for (regex, unit, one, many) in unitPatterns {
            s = replacing(s, regex) { m in
                // "the 1920s" and "the 80s" are decades, not seconds.
                if unit == "s", m[2].isEmpty, let n = Int(m[1]), m[1].count == 4 || n % 10 == 0 { return m[0] }
                return "\(m[1]) \(Double(m[1].replacingOccurrences(of: ",", with: "")) == 1 ? one : many)"
            }
        }
        return s
    }

    // MARK: Abbreviations

    /// Abbreviations the voice reads as written ("St." as "stat"), spelled out where the words around
    /// them show which meaning is meant.
    static func abbreviations(_ text: String) -> String {
        var s = text
        // After a name or number, "St." is Street; before a name it stays Saint ("St. Louis").
        s = replace(s, #"(?<=[A-Za-z0-9] )St\.(?!\s+[A-Z])"#, "Street")
        s = replace(s, #"(?<=[A-Za-z0-9] )Ave\.?(?=[\s,.;]|$)"#, "Avenue")
        s = replace(s, #"(?<=[A-Za-z0-9] )Blvd\.?(?=[\s,.;]|$)"#, "Boulevard")
        s = replace(s, #"(?<=[A-Za-z0-9] )Rd\.(?=[\s,.;]|$)"#, "Road")
        s = replace(s, #"\bapprox\.(?=\s)"#, "approximately")
        s = replace(s, #"\bRm\.\s?(?=\d)"#, "Room ")
        s = replace(s, #"\bProf\.(?=\s+[A-Z])"#, "Professor")
        s = replace(s, #"\bSr\.(?=[\s,]|$)"#, "Senior")
        s = replace(s, #"\bYoY\b"#, "year over year")
        s = replace(s, #"\bQoQ\b"#, "quarter over quarter")
        for (short, long) in [("Mon", "Monday"), ("Tue", "Tuesday"), ("Tues", "Tuesday"), ("Wed", "Wednesday"), ("Thu", "Thursday"), ("Thurs", "Thursday"), ("Fri", "Friday")] {
            s = replace(s, "\\b" + short + #"\.(?=[\s,;]|$)"#, long)
        }
        s = replace(s, #"\bmisc\.(?=\s)"#, "miscellaneous")
        s = replace(s, #"\bdept\.(?=\s)"#, "department")
        s = replace(s, #"\b[Ff]ig\.\s?(?=\d)"#, "figure ")
        s = replace(s, #"\b[Pp]p\.\s?(?=\d)"#, "pages ")
        s = replace(s, #"\b[Ee]q\.\s?(?=\d)"#, "equation ")
        s = replace(s, #"\b[Ss]ec\.\s?(?=\d)"#, "section ")
        s = replace(s, #"\b[Cc]h\.\s?(?=\d)"#, "chapter ")
        s = replace(s, #"\b[Vv]ol\.\s?(?=\d)"#, "volume ")
        return s
    }

    // MARK: Roman numerals

    /// Words after which a Roman numeral is a number ("Chapter IV" is "chapter four").
    static let numeralCues = ["Chapter", "Part", "Act", "Scene", "Book", "Volume", "Section", "Phase", "Appendix", "Article", "Title", "War", "Bowl", "Stage", "Type", "Class", "Level"]
    /// Names after which it is "the eighth" ("Henry VIII").
    static let regnalNames = ["Henry", "Louis", "Charles", "George", "Edward", "Richard", "Elizabeth", "John", "Paul", "Pius", "James", "William", "Mary", "Philip", "Benedict", "Leo", "Frederick", "Catherine", "Peter", "Nicholas", "Alexander", "Napoleon"]

    /// Roman numerals after a word that shows they are numbers, as numbers.
    static func romanNumerals(_ text: String) -> String {
        var s = text
        let numeral = #"([IVXLC]{1,7})(?![A-Za-z])"#
        // A lone "C" or "L" is a letter far more often than 100 or 50: "Appendix C", "Type C", "John L. Sullivan".
        func value(_ numeral: String) -> Int? { numeral == "C" || numeral == "L" ? nil : roman(numeral) }
        s = replacing(s, #"\b("# + numeralCues.joined(separator: "|") + #")\s"# + numeral) { m in
            guard let n = value(m[2]) else { return m[0] }
            return "\(m[1]) \(n)"
        }
        s = replacing(s, #"\b("# + regnalNames.joined(separator: "|") + #")\s"# + numeral) { m in
            // A single "I" after a name is more often the word ("John I think…").
            guard m[2] != "I", let n = value(m[2]), let word = ordinal(n) else { return m[0] }
            return "\(m[1]) the \(word)"
        }
        return s
    }

    /// The number a Roman numeral stands for, up to 399; nil when the letters are not a well-formed numeral.
    static func roman(_ s: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        var total = 0
        var previous = 0
        for ch in s.reversed() {
            guard let v = values[ch] else { return nil }
            if v < previous { total -= v } else { total += v }
            previous = max(previous, v)
        }
        // Only well-formed numerals: writing the number back gives the same letters.
        guard total > 0, total < 400 else { return nil }
        var n = total
        var back = ""
        for (v, r) in [(100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v {
                back += r
                n -= v
            }
        }
        return back == s ? total : nil
    }

    /// "eighth" for 8, "23rd" for 23; nil for anything a king or a pope has not reached.
    static func ordinal(_ n: Int) -> String? {
        let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
                     "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth"]
        if (1...20).contains(n) { return words[n - 1] }
        guard n > 0, n < 100 else { return nil }
        // Every number here is past twenty, so 11 to 13 need no special case.
        return "\(n)" + (["th", "st", "nd", "rd"][n % 10 < 4 ? n % 10 : 0])
    }

    // MARK: Accents

    /// The voice drops an accented letter altogether ("café" came out as "kaf"). A final "é" is written as
    /// the sound it makes; other accents are removed, which leaves a word the voice knows.
    static func accents(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return text }
        // "é" can arrive as "e" followed by a separate accent mark (file names and some apps write it
        // that way). Joined into one letter, the rules below see it.
        let joined = text.precomposedStringWithCanonicalMapping
        guard joined.unicodeScalars.contains(where: { $0.value > 0x7F && ($0.properties.isAlphabetic || $0.properties.generalCategory == .nonspacingMark) })
        else { return text }
        var s = replace(joined, #"(?<=\p{L})ée?(?!\p{L})"#, "ay")
        s = replace(s, #"ñ"#, "ny")
        s = s.replacingOccurrences(of: "ß", with: "ss")
        return s.applyingTransform(.stripDiacritics, reverse: false) ?? s
    }

    // MARK: Helpers

    /// `s` with every match of `pattern` replaced by `template`.
    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let regex = Patterns.regex(pattern) else { return s }
        return regex.replacing(in: s, with: template)
    }

    /// Replaces each match with what `transform` returns for its groups (group 0 is the whole match).
    private static func replacing(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = Patterns.regex(pattern) else { return s }
        return replacing(s, regex, transform)
    }

    private static func replacing(_ s: String, _ regex: NSRegularExpression, _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(groups)
            last = NSMaxRange(match.range)
        }
        out += ns.substring(from: last)
        return out
    }
}
