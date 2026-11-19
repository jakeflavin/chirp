import Foundation

/// Word-level comparison of two versions of a text.
public enum WordDiff {
    /// One step of turning the old text into the new one: a word kept, taken out or put in.
    public enum Op: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// The edit script from `old` to `new`, word by word (longest common subsequence).
    public static func diff(from old: String, to new: String) -> [Op] {
        let a = tokens(old), b = tokens(new)
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                ops.append(.same(a[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.removed(a[i]))
                i += 1
            } else {
                ops.append(.added(b[j]))
                j += 1
            }
        }
        while i < a.count {
            ops.append(.removed(a[i]))
            i += 1
        }
        while j < b.count {
            ops.append(.added(b[j]))
            j += 1
        }
        return ops
    }

    /// Places where a few words were swapped for a few other words: the corrections worth learning.
    /// Pure insertions, deletions and long rewrites are ignored.
    public static func substitutions(from old: String, to new: String, maxWords: Int = 3) -> [(heard: String, meant: String)] {
        var result: [(String, String)] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            defer {
                removed = []
                added = []
            }
            guard !removed.isEmpty, !added.isEmpty, removed.count <= maxWords, added.count <= maxWords else { return }
            let heard = removed.map(strip).joined(separator: " ")
            let meant = added.map(strip).joined(separator: " ")
            // Punctuation-only or case-only changes are not vocabulary.
            guard !heard.isEmpty, !meant.isEmpty, heard.lowercased() != meant.lowercased() else { return }
            result.append((heard, meant))
        }
        for op in diff(from: old, to: new) {
            switch op {
            case .same: flush()
            case .removed(let w): removed.append(w)
            case .added(let w): added.append(w)
            }
        }
        flush()
        return result
    }

    /// What follows each word of a text, for showing a comparison laid out like the text itself: a space,
    /// or the line breaks that end its line or paragraph (two at most). One entry per word of `tokens(s)`;
    /// the last word's is empty.
    public static func breaks(after s: String) -> [String] {
        var out: [String] = []
        var inWord = false
        var newlines = 0
        for character in s {
            if isSeparator(character) {
                if character.isNewline { newlines += 1 }
            } else {
                if !inWord {
                    // A new word begins: what lay between it and the word before is now known.
                    if !out.isEmpty { out[out.count - 1] = newlines > 0 ? String(repeating: "\n", count: min(newlines, 2)) : " " }
                    out.append("")
                    newlines = 0
                }
                inWord = true
                continue
            }
            inWord = false
        }
        return out
    }

    /// What separates one word from the next: a space or a line break of any kind.
    static func isSeparator(_ c: Character) -> Bool { c == " " || c.isNewline }

    /// The words of a text, in order.
    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: isSeparator).map(String.init)
    }

    /// Where each word of `tokens(s)` sits in `s`, in UTF-16 units. Both come from the same rule, so
    /// the nth range is always the nth word of the diff.
    static func wordRanges(_ s: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0
        var start: Int?
        for character in s {
            if isSeparator(character) {
                if let begun = start { ranges.append(NSRange(location: begun, length: offset - begun)) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += character.utf16.count
        }
        if let begun = start { ranges.append(NSRange(location: begun, length: offset - begun)) }
        return ranges
    }

    /// A word without the punctuation and symbols around it.
    static func strip(_ w: String) -> String {
        w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }
}
