import Foundation

/// "Say it as" while reading: a name the voice got wrong is fixed where it is
/// heard. The words just spoken are offered, the last one picked; the user types how it should sound,
/// hears it, and it is saved to the Dictionary and used from the next sentence on.
public enum SayItAs {
    /// A word as it is offered and saved: without the punctuation around it or a possessive ending.
    public static func bare(_ word: String) -> String {
        var s = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        for ending in ["'s", "’s"] where s.hasSuffix(ending) { s = String(s.dropLast(2)) }
        return s
    }

    /// The words to offer, oldest first, so the last is the one most likely meant. `spoken` is the words
    /// heard so far, in order (the sentence before and the one being read, up to the word being spoken).
    /// Names come first to mind when something sounds wrong, so the last few words with a capital that
    /// does not just start a sentence are offered; when there are fewer than `count`, the longest of the
    /// other recent words fill in. Words the user has already given a pronunciation are still offered (it
    /// may need changing).
    static func candidates(spoken: [(word: String, startsSentence: Bool)], count: Int, lastName: inout String?) -> [String] {
        // Only what was just heard: the last twenty words.
        let recent = Array(spoken.suffix(20))
        var picked: [(at: Int, word: String)] = []
        // Where the names among them are, so the newest name can be the one picked.
        var names: Set<Int> = []
        func add(_ at: Int, _ word: String) {
            guard word.count >= 2, word.contains(where: \.isLetter),
                !picked.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame })
            else { return }
            picked.append((at, word))
        }
        // Names, newest first.
        for (at, entry) in recent.enumerated().reversed() where picked.count < count {
            let word = bare(entry.word)
            guard let first = word.first, first.isUppercase, word.count > 1 else { continue }
            // A capital that only starts the sentence is not a name for certain, unless the word has another inside it.
            if entry.startsSentence, !word.dropFirst().contains(where: \.isUppercase) { continue }
            let before = picked.count
            add(at, word)
            if picked.count > before { names.insert(at) }
        }
        // Then a word that starts a sentence and may be a name ("Chepngetich won…"), unless it is one of
        // the small words sentences start with.
        for (at, entry) in recent.enumerated().reversed() where picked.count < count && entry.startsSentence {
            let word = bare(entry.word)
            if word.count >= 4, word.first?.isUppercase == true, !RewriteCheck.function.contains(word.lowercased()) { add(at, word) }
        }
        // Then the other recent words of some length, newest first.
        for (at, entry) in recent.enumerated().reversed() where picked.count < count {
            let word = bare(entry.word)
            if word.count >= 5 { add(at, word) }
        }
        // The word being spoken is always there, whatever it is.
        if let last = recent.last.map({ bare($0.word) }), !last.isEmpty,
            !picked.contains(where: { $0.word.caseInsensitiveCompare(last) == .orderedSame })
        {
            if picked.count >= count { picked.removeLast() }
            picked.append((recent.count - 1, last))
        }
        lastName = picked.filter { names.contains($0.at) }.max { $0.at < $1.at }?.word
        return picked.sorted { $0.at < $1.at }.map(\.word)
    }

    /// The words to offer and the one to pick: the newest name among them (the voice has usually moved a
    /// few words on by the time the button is pressed), or the word being spoken when no name was heard.
    public static func offer(spoken: [(word: String, startsSentence: Bool)], count: Int = 3) -> (words: [String], picked: String) {
        var name: String?
        let words = candidates(spoken: spoken, count: count, lastName: &name)
        return (words, name ?? words.last ?? "")
    }

    public static func candidates(spoken: [(word: String, startsSentence: Bool)], count: Int = 3) -> [String] {
        var name: String?
        return candidates(spoken: spoken, count: count, lastName: &name)
    }

    /// What "Say it as" offers for the word the mark is on: that word first and
    /// picked, and the few words before it as the other chips, oldest first so the picked one is last.
    /// A capitalised two-word name the marked word is part of ("Stack Overflow") is one chip and is the
    /// one picked. `marked` is the marked word's index among the sentence's words; `before` is the
    /// sentence read before this one, used when the marked word is near the start. `range` is the picked
    /// chip's place in `sentence`.
    public static func offer(sentence: String, marked: Int, before: String? = nil, count: Int = 3)
        -> (words: [String], picked: String, range: NSRange?)
    {
        let ns = sentence as NSString
        let ranges = ReadingText.wordRanges(sentence)
        guard !ranges.isEmpty else { return ([], "", nil) }
        let m = min(max(0, marked), ranges.count - 1)
        func raw(_ i: Int) -> String { ns.substring(with: ranges[i]) }
        func word(_ i: Int) -> String { bare(raw(i)) }
        // A word that could be part of a name: a capital, more than one letter, not one of the small words.
        func capital(_ i: Int) -> Bool {
            let w = word(i)
            guard w.count > 1, w.first?.isUppercase == true else { return false }
            return !RewriteCheck.function.contains(w.lowercased()) && !["a", "an", "i"].contains(w.lowercased())
        }
        // Two words join only when nothing but a space is between them (no comma, full stop or dash).
        func joins(_ a: Int) -> Bool {
            guard let last = raw(a).unicodeScalars.last else { return false }
            return CharacterSet.alphanumerics.contains(last) && raw(a + 1).first?.isLetter == true
        }
        var first = m
        var last = m
        if capital(m) {
            if m > 0, capital(m - 1), joins(m - 1) { first = m - 1 }
            else if m + 1 < ranges.count, capital(m + 1), joins(m) { last = m + 1 }
        }
        var picked = first == last ? word(m) : word(first) + " " + word(last)
        var range: NSRange? = NSRange(location: ranges[first].location, length: NSMaxRange(ranges[last]) - ranges[first].location)
        if picked.isEmpty || !picked.contains(where: \.isLetter) {
            // A mark on a number or a dash: the word itself is still offered as written.
            picked = raw(m).trimmingCharacters(in: .whitespaces)
            range = ranges[m]
        }
        // The few words before it, nearest first: this sentence, then the one before. A capitalised
        // two-word name among them is one chip too, though the mark has moved past it ("Stack
        // Overflow" when the mark is on "meetup").
        var pool: [String] = chips(sentence, upTo: first)
        if let before { pool += chips(before, upTo: nil) }
        var others: [String] = []
        for w in pool where others.count < count - 1 {
            guard w.count >= 3, w.contains(where: \.isLetter), !RewriteCheck.function.contains(w.lowercased()),
                w.caseInsensitiveCompare(picked) != .orderedSame,
                !others.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame })
            else { continue }
            others.append(w)
        }
        return (others.reversed() + [picked], picked, range)
    }

    /// The words of `sentence` before word `upTo` (all of them when nil), nearest first, with two capitalised
    /// words side by side ("Stack Overflow") as one chip: the same rule as for the marked word.
    static func chips(_ sentence: String, upTo: Int?) -> [String] {
        let ns = sentence as NSString
        let ranges = ReadingText.wordRanges(sentence)
        let end = min(upTo ?? ranges.count, ranges.count)
        func raw(_ i: Int) -> String { ns.substring(with: ranges[i]) }
        func word(_ i: Int) -> String { bare(raw(i)) }
        func capital(_ i: Int) -> Bool {
            let w = word(i)
            guard w.count > 1, w.first?.isUppercase == true else { return false }
            return !RewriteCheck.function.contains(w.lowercased()) && !["a", "an", "i"].contains(w.lowercased())
        }
        func joins(_ a: Int) -> Bool {
            guard let last = raw(a).unicodeScalars.last else { return false }
            return CharacterSet.alphanumerics.contains(last) && raw(a + 1).first?.isLetter == true
        }
        var out: [String] = []
        var i = end - 1
        while i >= 0 {
            if i > 0, capital(i), capital(i - 1), joins(i - 1) {
                out.append(word(i - 1) + " " + word(i))
                i -= 2
            } else {
                out.append(word(i))
                i -= 1
            }
        }
        return out
    }

    /// The spoken words of some sentences, each marked when it starts its sentence. `upTo` is how many
    /// words of the last sentence have been said.
    public static func spokenWords(sentences: [String], upTo: Int) -> [(word: String, startsSentence: Bool)] {
        var out: [(String, Bool)] = []
        for (n, sentence) in sentences.enumerated() {
            let ns = sentence as NSString
            var ranges = ReadingText.wordRanges(sentence)
            if n == sentences.count - 1 { ranges = Array(ranges.prefix(max(1, upTo))) }
            for (i, range) in ranges.enumerated() { out.append((ns.substring(with: range), i == 0)) }
        }
        return out
    }
}
