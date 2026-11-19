import Foundation

/// The check every rewrite goes through after the language model has written it.
/// Chirp helps with the user's own words: a rewrite must still be their text, said by the same
/// person, asking the same questions and holding the same facts. A small model cannot be trusted to keep
/// to that because its instructions say so, so the result is read by rule, and one that fails is not offered.
///
/// What is looked for, and where each idea comes from:
/// - the result is a reply to the text, not a version of it ("as an AI" answers, and replies that start
///   with words from Chirp's own list);
/// - a question in the text is no longer a question, or the result asks one the text did not;
/// - "I" became "you", or a person appeared who was not there;
/// - a number, a name or a date that is not in the text, or one from the text that has gone;
/// - a greeting, a sign-off or a promise that is not in the text;
/// - words about things the text never mentioned (more than a rewording would bring);
/// - for "Write out", a point that was left out; for "Shorten", a result that is not shorter.
public enum RewriteCheck {
    public enum Problem: String, Sendable, Equatable, CaseIterable {
        /// Nothing came back.
        case empty
        /// The result is the text as it was.
        case unchanged
        /// The result reads as an answer to the text, or talks about it.
        case reply
        /// A question in the text is not asked in the result.
        case questionLost
        /// The result asks a question the text did not.
        case questionAdded
        /// The person changed: "I" became "you", or the other way round, or someone new speaks.
        case personChanged
        /// A number that is not in the text.
        case newNumber
        /// A number from the text is missing.
        case lostNumber
        /// A name or a date that is not in the text.
        case newName
        /// A greeting that is not in the text.
        case greeting
        /// A sign-off that is not in the text.
        case signOff
        /// A promise ("I will") that is not in the text.
        case promise
        /// A reason ("because", "therefore") that is not in the text.
        case reason
        /// A name from the text is missing, or spelled another way.
        case lostName
        /// The text says "not" and the result does not: what it says has been turned round.
        case negationLost
        /// Too much of the result is about things the text does not mention.
        case addedContent
        /// One of the text's points is not in the result ("Write out").
        case pointMissing
        /// The result is far longer than a rewrite of the text would be.
        case tooLong
        /// "Shorten" came back no shorter.
        case notShorter
    }

    /// What is wrong with `result` as `task` done to `original`. Empty when it can be offered.
    /// A summary is not a rewrite and is not checked.
    public static func problems(task: WritingTask, original: String, result: String) -> [Problem] {
        if task == .summarize { return [] }
        let before = tidy(original)
        let after = tidy(result)
        guard !after.isEmpty else { return [.empty] }
        let old = words(before)
        let new = words(after)
        // The same words in the same order, whatever happened to the capitals, the bullets and the stops.
        if squashed(before) == squashed(after) || (task != .fix && old == new) {
            // A proofread that changes nothing is an answer: there was nothing to correct.
            return task == .fix ? [] : (task == .shorten ? [.notShorter] : [.unchanged])
        }
        var found: [Problem] = []
        let oldSet = Set(old)

        // A reply, or talk about the text.
        let lower = after.lowercased()
        let oldLower = before.lowercased()
        if replyOpenings.contains(where: { lower.hasPrefix($0) && !oldLower.hasPrefix($0) })
            || replyPhrases.contains(where: { lower.contains($0) && !oldLower.contains($0) })
        {
            found.append(.reply)
        }

        // Questions. One typed without its mark ("How do I make an expenses claim.") is a question too.
        let asked = questions(before)
        let asks = questions(after)
        if asks < asked { found.append(.questionLost) }
        if asked == 0, asks > 0 { found.append(.questionAdded) }

        // The person. Whoever speaks, is spoken to or is spoken of in the text still is in the result, and
        // nobody new: "I" does not become "you", "you said you would" does not go, "they" does not become
        // "the client".
        let (i0, you0, they0) = persons(old)
        let (i1, you1, they1) = persons(new)
        let politeYou = Patterns.regex("\\b(could|would|can|will) you\\b", options: [.caseInsensitive])?
            .numberOfMatches(in: after, range: NSRange(location: 0, length: (after as NSString).length)) ?? 0
        // Notes leave their subject out ("booked it myself", "bring a head torch"): written out, "I" and
        // "you" come back, and that is not a change of person.
        let notes = task == .writeOut
        let newFirst = i0 == 0 && i1 > 0 && !(notes ? you0 == 0 : impliedFirstPerson(before))
        let newSecond = you0 == 0 && you1 > politeYou && (notes ? (new.first.map(second.contains) ?? false) || (i0 > 0 && i1 == 0) : true)
        // "They are asking for a second quote", when the notes never said who: someone new.
        let newThird = they0 == 0 && they1 > 0
        if (i0 > 0 && i1 == 0) || (you0 > 0 && you1 == 0) || (they0 > 0 && they1 == 0) || newFirst || newSecond || newThird {
            found.append(.personChanged)
        }

        // Numbers, both ways. A proofread may not touch one either.
        let n0 = numbers(old)
        let n1 = numbers(new)
        if !n1.subtracting(n0).isEmpty { found.append(.newNumber) }
        if !n0.subtracting(n1).isEmpty { found.append(.lostNumber) }

        // Names and dates: a capital that does not start a sentence, or the name of a day or a month.
        let stems0 = Set(old.map(stem))
        func known(_ word: String) -> Bool {
            oldSet.contains(word) || stems0.contains(stem(word)) || (word.count >= 5 && old.contains { near($0, word) })
        }
        // "Has not finished" must not come back as "finished".
        if task != .fix, old.contains(where: isNegation), !new.contains(where: isNegation) { found.append(.negationLost) }
        // A word with a capital in the text ("Garmin", wherever it stands) that comes back one or two letters
        // different ("Garman") is a name spelled wrong.
        if task != .fix {
            let newSet = Set(new)
            for name in Set(properWords(before)) where !newSet.contains(name) {
                if new.contains(where: { $0.count >= 4 && $0 != name && stem($0) != stem(name) && abs($0.count - name.count) <= 1 && distance(Array($0), Array(name)) <= 2 && !oldSet.contains($0) }) {
                    found.append(.lostName)
                    break
                }
            }
        }
        // A name in the text is in the result, spelled as it was.
        if task != .fix, capitals(before).contains(where: { name in !function.contains(name.lowercased()) && !after.contains(name) }) {
            found.append(.lostName)
        }
        if capitals(after).contains(where: { !known($0.lowercased()) && !function.contains($0.lowercased()) }) {
            found.append(.newName)
        } else if new.contains(where: { calendar.contains($0) && !known($0) }) { found.append(.newName) }

        // Courtesies and promises.
        if let first = new.first, greetings.contains(first), old.first != first { found.append(.greeting) }
        else if courtesies.contains(where: { lower.contains($0) && !oldLower.contains($0) }) { found.append(.greeting) }
        let tail = String(lower.suffix(70))
        if signOffs.contains(where: { tail.contains($0) && !oldLower.contains($0) }) { found.append(.signOff) }
        if task != .fix, !old.contains(where: promises.contains), new.contains(where: promises.contains) { found.append(.promise) }
        // A reason nobody gave: two points joined by "because" say more than the points did.
        if task != .fix, reasons.contains(where: { has($0, in: lower) && !has($0, in: oldLower) }), !reasons.contains(where: { has($0, in: oldLower) }) {
            found.append(.reason)
        }

        // What the result is about. A proofread changes spellings, so its words are not compared.
        if task != .fix {
            let content1 = new.filter(isContent)
            let fresh = content1.filter { !known($0) }
            let allowed: Double
            let floor: Int
            switch task {
            // Written out, the notes gain connecting words and nothing else.
            case .writeOut: (allowed, floor) = (0, 0)
            case .shorten: (allowed, floor) = (0.15, 1)
            default: (allowed, floor) = (0.6, 1)
            }
            if !content1.isEmpty, fresh.count > max(floor, Int((Double(content1.count) * allowed).rounded(.down))) {
                found.append(.addedContent)
            }
            // A rewording still shares most of what the text was about; an answer does not.
            let content0 = Set(old.filter(isContent).map(stem))
            let stems1 = Set(new.map(stem))
            if task != .shorten, content0.count >= 3 {
                let kept = content0.filter { s in stems1.contains(s) || new.contains { near($0, s) } }.count
                if Double(kept) < Double(content0.count) * (task == .writeOut ? 0.6 : 0.3) { found.append(.addedContent) }
            }
            // Every point of the notes is in what was written out.
            if task == .writeOut {
                for point in points(before) {
                    let wanted = Set(words(point).filter(isContent).map(stem))
                    guard !wanted.isEmpty else { continue }
                    let there = wanted.filter { s in stems1.contains(s) || new.contains { near($0, s) } }.count
                    // Most of a point's words: both of two, two of three, three of four.
                    if there < Int((Double(wanted.count) * 0.6).rounded(.up)) {
                        found.append(.pointMissing)
                        break
                    }
                }
            }
        }

        // Length.
        switch task {
        case .shorten:
            if after.count >= before.count { found.append(.notShorter) }
        case .writeOut:
            if new.count > old.count * 2 + 12 { found.append(.tooLong) }
        case .fix:
            if new.count > old.count * 5 / 4 + 5 || new.count < old.count * 3 / 4 - 5 { found.append(.tooLong) }
        default:
            if new.count > old.count * 8 / 5 + 10 { found.append(.tooLong) }
        }
        var seen = Set<Problem>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Whether `result` can be offered as `task` done to `original`.
    public static func passes(task: WritingTask, original: String, result: String) -> Bool {
        problems(task: task, original: original, result: result).isEmpty
    }

    /// What to say in place of a rewrite that failed, in a few plain words.
    public static func message(task: WritingTask, problems: [Problem]) -> String {
        if problems == [.unchanged] || problems == [.notShorter] || problems == [.unchanged, .notShorter] {
            return task == .shorten ? "Nothing to shorten here." : "Nothing to change here."
        }
        let verb: String
        switch task {
        case .fix: verb = "proofread"
        case .shorten: verb = "shorten"
        case .writeOut: verb = "write this out"
        case .rephrase: verb = "rephrase"
        case .summarize: verb = "summarize"
        }
        return task == .writeOut
            ? "Chirp could not write this out without adding to it. Your text is as it was."
            : "Chirp could not \(verb) this without changing what it says. Your text is as it was."
    }

    /// One more line for the model's instructions when its first answer failed: what went wrong, said as a rule.
    public static func reminder(for problems: [Problem]) -> String {
        var lines: [String] = []
        if problems.contains(.reply) || problems.contains(.questionLost) || problems.contains(.questionAdded) {
            lines.append("Do not answer the text. A question in it stays a question, in the author's words.")
        }
        if problems.contains(.personChanged) { lines.append("Keep the point of view: \"I\" stays \"I\", \"my\" stays \"my\".") }
        if problems.contains(.newNumber) || problems.contains(.lostNumber) || problems.contains(.newName) {
            lines.append("Keep every number, name and date exactly, and add none.")
        }
        if problems.contains(.greeting) || problems.contains(.signOff) || problems.contains(.promise) {
            lines.append("No greeting, no sign-off, no \"will\" that is not in the text.")
        }
        if problems.contains(.reason) { lines.append("Do not say why (\"because\", \"so\", \"therefore\") unless the text does.") }
        if problems.contains(.lostName) { lines.append("Keep every name, spelled as it is.") }
        if problems.contains(.negationLost) { lines.append("Keep every \"not\": do not turn round what the text says.") }
        if problems.contains(.addedContent) || problems.contains(.tooLong) { lines.append("Use only what the text says. Add nothing.") }
        if problems.contains(.pointMissing) { lines.append("Include every point, in the same order.") }
        if problems.contains(.notShorter) {
            lines.append("That was not shorter. Say the same in fewer words: cut words that add nothing, and keep every question, request, name and number.")
        } else if problems.contains(.unchanged) {
            lines.append("That was the text unchanged. Change the wording, and keep what it says.")
        }
        return lines.joined(separator: "\n")
    }

    /// A model's answer without the wrapping a small model sometimes adds: quotes around all of it, or a
    /// label before it ("Rewritten:").
    public static func tidy(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["rewritten:", "shortened:", "result:", "output:", "written out:", "rephrased:", "corrected:"] where s.lowercased().hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”")]
        for (open, close) in pairs where s.count > 2 && s.first == open && s.last == close && !s.dropFirst().dropLast().contains(open) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: Reading the words

    /// The text in lower case with one space between words, for telling "the same" from "changed".
    static func squashed(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The words of a text in lower case: letters, digits and apostrophes ("i'm", "412", "30th").
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            let c = ch == "’" ? "'" : ch
            if c.isLetter || c.isNumber || (c == "'" && !current.isEmpty) {
                current.append(c)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.hasSuffix("'") ? String($0.dropLast()) : $0 }
    }

    /// How many questions the text asks: its question marks, and the sentences that start the way a
    /// question does but were typed without one.
    static func questions(_ text: String) -> Int {
        var count = text.filter { $0 == "?" }.count
        for sentence in text.split(whereSeparator: { ".!\n".contains($0) }) where !sentence.contains("?") {
            // "How do I…", "Can you…", "Is it…": a question word, or a helping verb with its subject after it.
            // ("will tell customers on Monday" and "do not merge" are notes, not questions.)
            let said = words(String(sentence))
            guard let head = said.first else { continue }
            if askWords.contains(head) || (askers.contains(head) && said.count > 1 && subjects.contains(said[1])) { count += 1 }
        }
        return count
    }

    /// Whether `phrase` is in `text` as whole words (both in lower case).
    static func has(_ phrase: String, in text: String) -> Bool {
        guard let regex = Patterns.regex("(?<![a-z])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![a-z])") else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// How often the text speaks as "I", to "you", and of someone else.
    static func persons(_ words: [String]) -> (Int, Int, Int) {
        (words.filter(first.contains).count, words.filter(second.contains).count, words.filter(third.contains).count)
    }

    /// Notes often leave "I" out ("booked it myself", "need it paid back"): writing them out puts it back,
    /// and that is not a change of person. True when the text has no subject of its own to speak as.
    static func impliedFirstPerson(_ text: String) -> Bool {
        let all = words(text)
        guard !all.contains(where: second.contains) else { return false }
        // A line that starts with a bare verb the writer would do, or says "myself".
        if all.contains("myself") { return true }
        return points(text).contains { point in
            guard let head = words(point).first else { return false }
            return bareVerbs.contains(head)
        }
    }

    /// The numbers in the text, as digits: "412", "30" from "30th", "2" from "two", "42" from
    /// "forty-two", "28" from "twenty-eighth".
    static func numbers(_ words: [String]) -> Set<String> {
        var out = Set<String>()
        var i = 0
        while i < words.count {
            let word = words[i]
            if let tens = tensWords[word] {
                // "forty two", "twenty eighth": the hyphen has already split them.
                if i + 1 < words.count, let unit = unitWords[words[i + 1]] ?? ordinalWords[words[i + 1]], unit < 10 {
                    out.insert(String(tens + unit))
                    i += 2
                    continue
                }
                out.insert(String(tens))
            } else if let n = numberWords[word] {
                out.insert(n)
            } else if let n = ordinalWords[word] {
                out.insert(String(n))
            } else if word.first?.isNumber == true {
                let digits = String(word.prefix { $0.isNumber })
                let bare = String(digits.drop { $0 == "0" })
                out.insert(bare.isEmpty ? "0" : bare)
            }
            i += 1
        }
        return out
    }

    static func isNegation(_ word: String) -> Bool {
        word == "not" || word == "no" || word == "never" || word == "cannot" || word.hasSuffix("n't") || word == "nor" || word == "nobody" || word == "nothing"
    }

    /// Every word of five letters or more written with a capital, wherever it stands, in lower case:
    /// what may be a name. (Only used to notice one coming back misspelled.)
    static func properWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 5 && $0.first?.isUppercase == true }
            .map { $0.lowercased() }.filter { !function.contains($0) }
    }

    /// Words written with a capital that do not begin a sentence or a line (and are not "I").
    static func capitals(_ text: String) -> [String] {
        var out: [String] = []
        // Line by line: the first word of a line starts a sentence too (notes, a list).
        for line in text.split(whereSeparator: \.isNewline) {
            var startsSentence = true
            for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                // A bullet or a dash on its own is not a word.
                guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’()[]-–—•*"))
                let word = String(token.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
                if !startsSentence, let f = word.first, f.isUppercase, word.count > 1, !word.hasPrefix("I'"), !word.hasPrefix("I’") {
                    out.append(word.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'s", with: ""))
                }
                if let last = raw.last { startsSentence = ".!?:".contains(last) || raw.hasSuffix(".\"") || raw.hasSuffix(".”") }
            }
        }
        return out
    }

    /// The separate points of some notes: its lines, or its sentences when it is one line.
    static func points(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*–—")) }
            .filter { !$0.isEmpty }
        if lines.count > 1 { return lines }
        return text.split(whereSeparator: { ".!?;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A word cut down to the part that stays the same when it is used another way ("booked", "booking", "books").
    static func stem(_ word: String) -> String {
        var w = word
        if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
        for suffix in ["ing", "ed", "es", "ly", "s"] where w.count - suffix.count >= 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        if w.count > 3, w.hasSuffix("e") { w = String(w.dropLast()) }
        if w.count > 3, let last = w.last, w.dropLast().last == last, !"aeiouls".contains(last) { w = String(w.dropLast()) }
        return w
    }

    /// Whether two words are the same word spelled or used a little differently ("recieved" and "received").
    static func near(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (sa, sb) = (stem(a), stem(b))
        if sa == sb { return true }
        let common = zip(sa, sb).prefix { $0 == $1 }.count
        if common >= 4, common >= min(sa.count, sb.count) - 1 { return true }
        guard min(a.count, b.count) >= 5, abs(a.count - b.count) <= 2 else { return false }
        return distance(Array(a), Array(b)) <= 2
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where j <= b.count {
                let keep = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = keep
            }
        }
        return row[b.count]
    }

    /// A word that says what the text is about, as opposed to one that only joins the others.
    static func isContent(_ word: String) -> Bool {
        word.count >= 3 && word.first?.isLetter == true && !function.contains(word) && numberWords[word] == nil
    }

    static let first: Set<String> = [
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves", "i'm", "i've", "i'll", "i'd", "we're", "we've",
        "we'll", "we'd",
    ]
    static let second: Set<String> = ["you", "your", "yours", "yourself", "yourselves", "you're", "you've", "you'll", "you'd"]
    static let third: Set<String> = [
        "he", "she", "him", "her", "his", "hers", "they", "them", "their", "theirs", "he's", "she's", "they're", "they've",
        "they'll", "he'll", "she'll", "they'd", "he'd", "she'd", "himself", "herself", "themselves",
    ]
    static let numberWords: [String: String] = [
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60",
        "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000", "million": "1000000",
    ]
    static let tensWords: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let unitWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let ordinalWords: [String: Int] = [
        "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]
    /// Words a question starts with, and helping verbs that start one when their subject follows.
    static let askWords: Set<String> = ["how", "what", "why", "where", "who", "which", "whose"]
    static let askers: Set<String> = ["can", "could", "do", "does", "did", "is", "are", "should", "would", "will", "shall", "may", "has", "have"]
    static let subjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "anyone", "anybody", "someone", "there", "this", "that"]
    /// Words that give a reason.
    static let reasons = ["because", "therefore", "thus", "hence", "consequently", "due to", "as a result", "which means", "in order to", "so that"]
    static let calendar: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
        "june", "july", "august", "september", "october", "november", "december", "tomorrow", "yesterday", "tonight",
    ]
    static let greetings: Set<String> = ["hi", "hello", "hey", "dear", "greetings"]
    static let courtesies = [
        "i hope this", "hope you're well", "hope you are well", "hope you're doing well", "hope you are doing well", "good morning",
        "good afternoon", "good evening",
    ]
    static let signOffs = [
        "thanks", "thank you", "regards", "best,", "best wishes", "cheers", "sincerely", "let me know", "looking forward", "talk soon",
        "take care", "yours,",
    ]
    static let promises: Set<String> = ["will", "i'll", "we'll", "promise", "guarantee", "shall", "won't"]
    static let replyOpenings = [
        "sure", "certainly", "of course", "got it", "understood", "no problem", "here is", "here's", "here are", "okay", "ok,", "ok.", "yes,", "yes.", "no,", "no.",
        "i'm sorry", "i am sorry", "sorry,", "to make ", "to do this", "you can ", "you should ", "you need ", "you'll need ",
        "the text", "this text", "the author", "the sentence", "note:", "answer:", "i'd recommend", "i would recommend", "i recommend",
        "i suggest", "it seems", "it looks like", "it sounds like", "unfortunately", "great question", "based on",
    ]
    static let replyPhrases = [
        "as an ai", "as a language model", "i cannot help", "i can't help", "i'm not sure what you mean", "i don't understand the question",
        "i'm unable to", "i am unable to", "here is the", "here's the", "rewritten version", "shortened version", "hope this helps",
        "let me know if", "feel free to",
    ]
    /// Verbs a note often starts with, the "I" left out.
    static let bareVerbs = Set<String>([
        "need", "needs", "booked", "want", "wanted", "paid", "sent", "got", "have", "had", "am", "will", "can", "called", "asked",
        "spoke", "talked", "met", "finished", "started", "bought", "ordered", "signed", "checked", "tried", "fixed", "moved",
        "going", "planning", "hoping", "think", "thought", "ran", "did", "made", "took", "saw", "found",
    ])
    /// Words that join and shape a sentence without saying anything of their own.
    static let function = Set<String>([
        "the", "and", "but", "for", "nor", "yet", "with", "without", "from", "into", "onto", "over", "under", "about", "after",
        "before", "between", "through", "during", "until", "since", "while", "when", "where", "which", "who", "whom", "whose",
        "what", "why", "how", "that", "this", "these", "those", "then", "than", "there", "here", "also", "too", "both", "either",
        "neither", "each", "every", "all", "any", "some", "none", "one", "ones", "such", "same", "other", "another", "more", "most",
        "less", "least", "much", "many", "few", "very", "just", "only", "even", "still", "already", "again", "now", "soon", "not",
        "are", "was", "were", "been", "being", "has", "have", "had", "having", "does", "did", "doing", "done", "can", "could", "would",
        "should", "may", "might", "must", "will", "shall", "it's", "its", "itself", "i'm", "i've", "i'll", "i'd", "you", "your",
        "yours", "you're", "you've", "you'll", "you'd", "our", "ours", "we're", "we've", "we'll", "we'd", "she", "her", "hers", "his",
        "him", "they", "them", "their", "theirs", "they're", "mine", "myself", "yourself", "because", "although", "though", "however",
        "therefore", "thus", "hence", "so", "since", "unless", "whether", "once", "per", "via", "off", "out", "down", "upon", "within",
        "along", "across", "around", "against", "among", "toward", "towards", "well", "please", "isn't", "aren't", "wasn't", "weren't",
        "don't", "doesn't", "didn't", "can't", "couldn't", "wouldn't", "shouldn't", "won't", "hasn't", "haven't", "hadn't", "that's",
        "there's", "here's", "what's", "let's", "it'll", "that'll", "additionally", "meanwhile", "afterwards", "afterward", "first",
        "second", "third", "next", "last", "finally", "lastly", "overall", "currently", "total", "together", "furthermore", "moreover",
        "besides", "likewise", "otherwise", "instead", "though", "plus", "nor", "whereas", "while", "been", "get", "got",
        "gets", "getting", "make", "makes", "made", "making", "take", "takes", "took", "taking", "like", "need", "needs", "needed",
        "want", "wants", "wanted", "use", "uses", "used", "using", "way", "thing", "things", "really", "quite", "rather", "always",
        "never", "often", "sometimes", "usually", "back", "them", "for", "own", "been", "able", "going", "went", "come", "came",
        "comes", "coming", "put", "let", "set", "say", "says", "said", "its", "who's", "whom", "per", "yes", "know", "think",
    ])
}
