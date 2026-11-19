import Foundation

/// One word of a transcript with its time in the recording, in seconds.
public struct SaidWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

extension MeetingText {
    /// Transcript lines from words that carry their own times: a new line where the speaker changes, after a
    /// pause, or at the end of a sentence once a line has run long. Each word goes to the speaker talking
    /// while it was said, so a line never holds two people's turns. With one voice or none in `turns`, every
    /// line is `label`'s.
    public static func lines(
        from words: [SaidWord], turns: [SpeakerTurn], label: String = "Me", pause: Double = 1.0, longest: Double = 20
    ) -> [TranscriptSegment] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return [] }
        let several = Set(turns.map(\.speaker)).count > 1
        // Who was talking while each word was said: the turn that covers most of it, else the nearest one.
        var who: [String?] = words.map { word -> String? in
            guard several else { return nil }
            var best: (speaker: String, overlap: Double)?
            var nearest: (speaker: String, gap: Double)?
            for turn in turns {
                let overlap = min(word.end, turn.end) - max(word.start, turn.start)
                if overlap > 0 {
                    if overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
                } else if -overlap < (nearest?.gap ?? .infinity) {
                    nearest = (turn.speaker, -overlap)
                }
            }
            if let best { return best.speaker }
            if let nearest, nearest.gap <= 1 { return nearest.speaker }
            return nil
        }
        if several {
            // A word between two turns takes the speaker of the word before it (or the next, at the start).
            for i in who.indices where who[i] == nil { who[i] = i > 0 ? who[i - 1] : nil }
            for i in who.indices.reversed() where who[i] == nil { who[i] = i + 1 < who.count ? who[i + 1] : nil }
            // One or two words given to somebody else in the middle of a person's sentence are a slip of
            // the speaker step, not a turn: they go back to the person around them.
            var i = 0
            while i < who.count {
                var j = i
                while j + 1 < who.count, who[j + 1] == who[i] { j += 1 }
                let short = j - i + 1 <= 2 && words[j].end - words[i].start < 0.8
                if short, i > 0, j + 1 < who.count, who[i - 1] == who[j + 1], words[i].start - words[i - 1].end < pause,
                    words[j + 1].start - words[j].end < pause
                {
                    for k in i...j { who[k] = who[i - 1] }
                }
                i = j + 1
            }
        }
        var names: [String: String] = [:]
        func name(_ speaker: String?) -> String {
            guard several, let speaker else { return label }
            if names[speaker] == nil { names[speaker] = "Speaker \(names.count + 1)" }
            return names[speaker]!
        }
        var out: [TranscriptSegment] = []
        var current: [SaidWord] = []
        var currentWho: String?
        func close() {
            guard let first = current.first, let last = current.last else { return }
            out.append(
                TranscriptSegment(
                    itemID: 0, speaker: name(currentWho), start: first.start, end: max(last.end, first.start),
                    text: current.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
            current = []
        }
        for (i, word) in words.enumerated() {
            if let last = current.last, let first = current.first {
                let sentenceEnd = last.text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
                if who[i] != currentWho || word.start - last.end > pause || (sentenceEnd && last.end - first.start > longest) { close() }
            }
            if current.isEmpty { currentWho = who[i] }
            current.append(word)
        }
        close()
        return out
    }
}
