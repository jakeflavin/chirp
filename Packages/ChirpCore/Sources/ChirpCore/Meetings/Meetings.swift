import Foundation

/// Cuts a live audio stream into pieces at pauses, so each piece can be transcribed while the
/// meeting is still running. Pure arithmetic on samples: no model involved.
public struct PauseSegmenter: Sendable {
    /// A stretch of audio ready to be transcribed.
    public struct Piece: Sendable, Equatable {
        /// Seconds from the start of the stream.
        public var start: Double
        public var samples: [Float]
        /// Seconds from the start of the stream, taking the audio as 16 kHz.
        public var end: Double { start + Double(samples.count) / 16_000 }
    }

    public var sampleRate = 16_000
    /// Do not cut before this much audio has gathered.
    public var minSeconds = 4.0
    /// Always cut by this length, pause or not.
    public var maxSeconds = 14.0
    /// A stretch this quiet for this long counts as a pause.
    public var pauseSeconds = 0.45
    /// Loudness (root mean square of a 20 ms frame) below which a frame counts as quiet.
    public var quietLevel: Float = 0.008

    private var buffer: [Float] = []
    private var bufferStart = 0  // sample index of buffer[0] in the stream

    public init() {}

    /// Seconds of audio received so far.
    public var received: Double { Double(bufferStart + buffer.count) / Double(sampleRate) }

    /// Adds audio and returns any pieces that are now ready.
    public mutating func append(_ samples: [Float]) -> [Piece] {
        buffer.append(contentsOf: samples)
        var out: [Piece] = []
        while let cut = cutPoint() {
            out.append(take(cut))
        }
        return out
    }

    /// Samples of audio received so far, counting stretches skipped over.
    public var receivedSamples: Int { bufferStart + buffer.count }

    /// Moves the stream's clock on to `sample` with no sound in between: this side started late, or its
    /// capture was set up again. What was waiting comes back as a piece, and the next sound is timed from
    /// `sample`. Does nothing when the stream is already there.
    public mutating func skip(to sample: Int) -> Piece? {
        guard sample > receivedSamples else { return nil }
        let piece = buffer.isEmpty ? nil : take(buffer.count)
        bufferStart = sample
        return piece
    }

    /// Returns whatever is left at the end of the stream.
    public mutating func finish() -> Piece? {
        guard !buffer.isEmpty else { return nil }
        return take(buffer.count)
    }

    /// Removes the first `count` samples from the buffer as a piece.
    private mutating func take(_ count: Int) -> Piece {
        let piece = Piece(start: Double(bufferStart) / Double(sampleRate), samples: Array(buffer[..<count]))
        buffer.removeFirst(count)
        bufferStart += count
        return piece
    }

    /// Where to cut the buffer, if it is time to.
    private func cutPoint() -> Int? {
        let minCount = Int(minSeconds * Double(sampleRate))
        let maxCount = Int(maxSeconds * Double(sampleRate))
        guard buffer.count >= minCount else { return nil }
        let window = Int(pauseSeconds * Double(sampleRate))
        let frame = sampleRate / 50  // 20 ms
        // Look for the first pause that ends after the minimum length; cut in the middle of it.
        var quietRun = 0
        var i = max(0, minCount - window)
        while i + frame <= min(buffer.count, maxCount) {
            if Self.rms(buffer[i..<(i + frame)]) < quietLevel {
                quietRun += frame
                if quietRun >= window, i + frame >= minCount { return i + frame - window / 2 }
            } else {
                quietRun = 0
            }
            i += frame
        }
        return buffer.count >= maxCount ? maxCount : nil
    }

    /// How loud a stretch of samples is (root mean square); zero for none.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// A stretch of time attributed to one speaker by speaker recognition.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Everything done to a meeting's words without a model: naming speakers, dropping echoes, merging
/// lines, laying out the notes, and finding who said they would do what.
public enum MeetingText {
    /// Relabels transcript segments spoken by `label` (e.g. "Them") using speaker turns:
    /// each segment gets the speaker who talks for most of it. Speakers are named
    /// "Speaker 1", "Speaker 2"… in order of first appearance. With one speaker or none, nothing changes.
    /// `startingAt` numbers the speakers after ones already named, for when both sides of a call hold several people.
    public static func assignSpeakers(
        _ segments: [TranscriptSegment], turns: [SpeakerTurn], replacing label: String, startingAt first: Int = 1
    ) -> [TranscriptSegment] {
        guard Set(turns.map(\.speaker)).count > 1 else { return segments }
        var names: [String: String] = [:]
        var result = segments
        for (i, segment) in segments.enumerated() where segment.speaker == label {
            var overlap: [String: Double] = [:]
            for turn in turns {
                let o = min(segment.end, turn.end) - max(segment.start, turn.start)
                if o > 0 { overlap[turn.speaker, default: 0] += o }
            }
            guard let best = overlap.max(by: { $0.value < $1.value })?.key else { continue }
            if names[best] == nil { names[best] = "Speaker \(names.count + first)" }
            result[i].speaker = names[best]!
        }
        return result
    }

    /// The turns of people who really spoke: a voice heard for only a moment (a cough, a door, one voice
    /// briefly taken for another) is left out, so one person is not split in two.
    public static func significant(_ turns: [SpeakerTurn], minimumSeconds: Double = 4, minimumShare: Double = 0.05) -> [SpeakerTurn] {
        var spoke: [String: Double] = [:]
        for turn in turns { spoke[turn.speaker, default: 0] += max(0, turn.end - turn.start) }
        let total = spoke.values.reduce(0, +)
        let real = Set(spoke.filter { $0.value >= max(minimumSeconds, total * minimumShare) }.keys)
        return turns.filter { real.contains($0.speaker) }
    }

    /// Removes "Me" segments that are really the other side of the call picked up by the microphone
    /// from the speakers: same time, mostly the same words as a "Them" segment.
    public static func dropEchoes(_ segments: [TranscriptSegment], me: String = "Me") -> [TranscriptSegment] {
        let others = segments.filter { $0.speaker != me }
        return segments.filter { $0.speaker != me || !isEcho($0, of: others) }
    }

    /// Merges consecutive segments by the same speaker that are close in time, for reading.
    public static func merged(_ segments: [TranscriptSegment], gap: Double = 2.0) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for s in segments.sorted(by: { $0.start < $1.start }) where !s.text.isEmpty {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end <= gap, last.text.count < 600 {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// The transcript as plain lines: "Sam: text".
    public static func script(_ segments: [TranscriptSegment]) -> String {
        merged(segments).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// A meeting as a Markdown document: notes, the user's own notes, and the transcript.
    public static func markdown(item: SavedItem, segments: [TranscriptSegment]) -> String {
        var md = "# \(item.title)\n\n"
        let date = item.createdAt.formatted(date: .long, time: .shortened)
        md += "\(date) · \(item.duration.clock)\n\n"
        if !item.summary.isEmpty { md += item.summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
        // A voice note's body is its words as clean text. An older meeting's body holds notes typed as one text.
        if !item.body.isEmpty { md += (item.kind == .voiceNote ? "" : "## My notes\n\n") + "\(item.body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n" }
        let given = RecordingContext(json: item.context)
        // What the user kept at a moment of it: typed lines and pictures, with their times.
        if !given.notes.isEmpty {
            md += (item.kind == .voiceNote || item.body.isEmpty ? "## My notes\n\n" : "")
            md += given.notes.sorted { $0.at < $1.at }.map { "- \($0.clock) \($0.line)" }.joined(separator: "\n") + "\n\n"
        }
        // The files kept with it, by name (the files themselves stay in Chirp).
        let files = given.attachments.map(\.name)
        if !files.isEmpty { md += "## Files\n\n" + files.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !segments.isEmpty {
            md += "## Transcript\n\n"
            for s in merged(segments) { md += "**\(s.speaker)** (\(s.start.clock)): \(s.text)\n\n" }
        }
        return md
    }

    /// Splits a Markdown notes document into its "## Heading" sections, keeping only bullet lines.
    public static func sections(of markdown: String) -> [(title: String, bullets: [String])] {
        var out: [(String, [String])] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                out.append((line.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces), []))
            } else if line.hasPrefix("- ") || line.hasPrefix("* "), !out.isEmpty {
                out[out.count - 1].1.append(String(line.dropFirst(2)))
            }
        }
        return out.map { (title: $0.0, bullets: $0.1) }
    }

    /// Builds the notes document for `wanted` sections from a model draft, substituting separately
    /// written sections (the decisions of a long meeting) and filling any the draft left out.
    ///
    /// `limit` is how many points a section the model wrote may hold (a short meeting's stay at a length a
    /// person would read; a long one's are already kept to a few a part, and none of its parts is dropped).
    /// `additions` are points worked out by rule (what people said they would do) that go at the end of a
    /// section, after the model's own; they are never cut, so nothing somebody took on is lost.
    public static func assembleNotes(
        wanted: [String], draft: String, replacements: [String: [String]], additions: [String: [String]] = [:], limit: Int = 12,
        taskSection: (String) -> Bool = { _ in false }
    ) -> String {
        let drafted = sections(of: draft)
        // A small model writing a long list can fall into repeating itself, and likes to say the same thing
        // under two headings. Each point is kept once, where it first appears, and a section stops at a
        // length a person would still read. Tasks are their own list and are not counted against the rest.
        var said: [String] = []
        return wanted.map { title in
            let bullets = replacements[title]
                ?? drafted.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }?.bullets ?? []
            var kept: [String]
            if replacements[title] != nil || taskSection(title) {
                kept = unique(bullets)
            } else {
                kept = Array(unique(said + bullets).dropFirst(unique(said).count).prefix(limit))
                said += kept
            }
            if let more = additions[title], !more.isEmpty {
                // "None noted" is not a point once there is one.
                kept = unique(kept.filter { !isNothing($0) } + more)
            }
            let lines = kept.isEmpty ? ["None noted"] : kept
            return "## \(title)\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Notes written part by part

    /// What the model wrote for one part of a transcript, as sections of points. More forgiving than
    /// `sections(of:)`: a heading may be bold instead of "##", and a sentence written without its bullet
    /// mark is still a point (a paragraph keeps its first sentence). With `cut` (the answer ran into its
    /// token limit) a last line that stops mid-sentence is dropped.
    public static func partSections(of answer: String, cut: Bool) -> [(title: String, bullets: [String])] {
        var out: [(title: String, bullets: [String])] = []
        for line in MarkdownLines.parse(cut ? SummaryNotes.withoutUnfinishedEnd(answer) : answer) {
            switch line.kind {
            case .heading:
                out.append((SummaryNotes.heading(line.text), []))
            case .point:
                if !out.isEmpty { out[out.count - 1].bullets.append(line.text) }
            case .text:
                let words = TextStats.words(line.text)
                if out.isEmpty || words < 4 || line.text.hasSuffix(":") || SummaryNotes.isPreamble(line.text) { continue }
                out[out.count - 1].bullets.append(words > 40 ? SummaryNotes.firstSentence(line.text) : line.text)
            case .code:
                continue
            }
        }
        return out
    }

    /// A transcript up to this long has its notes written in one pass (measured on a 7,700-character meeting:
    /// one pass caught the decisions said in the closing recap, which notes on its halves put together did not).
    public static let onePass = 9000
    /// The size of a part of a longer one.
    public static let partSize = 6000

    /// The transcript as the parts its notes are written from: whole when it is short; otherwise parts of
    /// near-equal size, cut between speakers, so that no part is a stub the model has little to say about.
    public static func transcriptParts(_ script: String) -> [String] {
        guard script.count > onePass else { return script.isEmpty ? [] : [script] }
        let count = (script.count + partSize - 1) / partSize
        var parts: [String] = []
        var current: [String] = []
        var done = 0
        for line in script.components(separatedBy: "\n") {
            current.append(line)
            done += line.count + 1
            // Cut where this part's share of the whole has been reached.
            if parts.count < count - 1, done * count >= script.count * (parts.count + 1) {
                parts.append(current.joined(separator: "\n"))
                current = []
            }
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        // One speaker going on for longer than a part (a talk, a voice note): cut at sentences.
        return parts.flatMap { $0.count > partSize * 2 ? TextChunker.chunks($0, maxCharacters: partSize) : [$0] }
    }

    /// The draft without the instructions' own example, when the model wrote it in and the recording never said it.
    public static func withoutExample(_ draft: String, example: String, transcript: String) -> String {
        let key = meaningful(example)
        // Said in the recording (most of its words are there): it stays.
        let said = meaningful(transcript)
        if Double(key.intersection(said).count) >= 0.8 * Double(key.count) { return draft }
        return draft.components(separatedBy: "\n").filter { line in
            let words = meaningful(line)
            return words.isEmpty || Double(key.intersection(words).count) < 0.8 * Double(key.count)
        }.joined(separator: "\n")
    }

    /// The section an answer was in when it ran out of room: the last heading it wrote.
    public static func lastSection(of answer: String) -> String? {
        partSections(of: answer, cut: false).last?.title
    }

    // MARK: Decisions in a long recording

    /// Something a part of a meeting was noted as deciding, or as leaving open.
    public struct DecisionNote: Sendable, Equatable {
        public var text: String
        /// Left open, or waiting on something (cost, research), rather than settled.
        public var open: Bool

        public init(_ text: String, open: Bool = false) {
            self.text = text
            self.open = open
        }
    }

    /// The most notes taken from one answer: past this the model is listing everything that was mentioned.
    static let decisionNotesPerAnswer = 8

    /// The "- Decided: …" and "- Open: …" lines of the model's answer for one part. A line said twice
    /// (the model loops on long lists) is kept once, "None" is nothing, and with `cut` an unfinished last line goes.
    public static func decisionNotes(of answer: String, cut: Bool) -> [DecisionNote] {
        var out: [DecisionNote] = []
        for line in MarkdownLines.parse(cut ? SummaryNotes.withoutUnfinishedEnd(answer) : answer) {
            guard case .point = line.kind else { continue }
            var text = line.text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            var open = false
            for label in ["Decided:", "Decision:", "Open:", "Still open:"] where text.lowercased().hasPrefix(label.lowercased()) {
                open = label.lowercased().contains("open")
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            }
            // "The group decided to use rubber buttons" says the same as "Use rubber buttons".
            for lead in ["The group ", "The team ", "They ", "We "] where text.hasPrefix(lead) {
                let rest = text.dropFirst(lead.count)
                for verb in ["decided to ", "decided on ", "decided that ", "settled on ", "agreed to ", "agreed on ", "agreed that ", "left open "]
                where rest.hasPrefix(verb) {
                    text = String(rest.dropFirst(verb.count))
                    text = text.prefix(1).uppercased() + text.dropFirst()
                }
            }
            if isNothing(text) || text.split(separator: " ").count < 2 { continue }
            if out.contains(where: { TextCleaner.wordKey($0.text) == TextCleaner.wordKey(text) }) { continue }
            out.append(DecisionNote(text, open: open))
            if out.count == decisionNotesPerAnswer { break }
        }
        return out
    }

    /// The decisions a long meeting ended with, from the notes taken on each of its parts, in order.
    ///
    /// The model is good at noting what a part seems to settle and bad at choosing among those notes (asked
    /// to, it copies them all, or only the last part's), so the choosing is done here by rule:
    /// - a decision counts when the last part states it (meetings end by summing up), or when an earlier
    ///   part states it and a later part states it again; what one part proposes and nobody returns to is left out;
    /// - on the same subject the later statement is the one kept;
    /// - a subject whose latest part leaves it open is written "Still open: …", never as decided.
    /// Two notes are on the same subject when they share most of their telling words (`sameSubject`).
    /// `tasks` are what people took on, found separately: a note that only repeats one of those is a task, not a decision.
    public static func decisions(parts: [[DecisionNote]], tasks: [String] = []) -> [String] {
        let parts = parts.map { $0.filter { note in !tasks.contains { sameThing($0, note.text) } } }
        let all = parts.flatMap { $0 }
        guard !all.isEmpty else { return [] }
        // Words in most of the notes ("remote", "control", "group") tell nothing about which subject a note is on.
        var counts: [String: Int] = [:]
        for note in all { for word in telling(note.text) { counts[word, default: 0] += 1 } }
        let common = Set(counts.filter { all.count >= 5 && $0.value * 5 > all.count * 2 }.keys)
        struct Entry {
            var part: Int
            var index: Int
            var note: DecisionNote
            var words: Set<String>
        }
        var clusters: [[Entry]] = []
        var index = 0
        for (p, notes) in parts.enumerated() {
            for note in notes {
                let entry = Entry(part: p, index: index, note: note, words: telling(note.text).subtracting(common))
                index += 1
                if let c = clusters.firstIndex(where: { $0.contains { sameSubject($0.words, entry.words) } }) {
                    clusters[c].append(entry)
                } else {
                    clusters.append([entry])
                }
            }
        }
        let last = parts.count - 1
        var kept: [(index: Int, text: String, open: Bool)] = []
        for cluster in clusters {
            let latestPart = cluster.map(\.part).max() ?? 0
            // Stated in the last part, or stated in two parts.
            guard latestPart == last || Set(cluster.map(\.part)).count > 1 else { continue }
            let latest = cluster.filter { $0.part == latestPart }
            // Open in its latest part: open, whatever else that part said of it.
            let open = latest.contains { $0.note.open }
            guard let chosen = latest.first(where: { $0.note.open == open }) else { continue }
            // Two subjects can end up worded the same way: once is enough.
            if kept.contains(where: { sameThing($0.text, chosen.note.text) }) { continue }
            kept.append((chosen.index, chosen.note.text, open))
        }
        kept.sort { $0.index < $1.index }
        return kept.filter { !$0.open }.map(\.text) + kept.filter(\.open).map { "Still open: " + $0.text.prefix(1).lowercased() + $0.text.dropFirst() }
    }

    /// A note's meaningful words with British and American spellings brought together ("colours" and
    /// "colors", "rubberised" and "rubberized"): the transcript and the model do not always agree on them.
    static func telling(_ text: String) -> Set<String> {
        Set(meaningful(text).map { $0.replacingOccurrences(of: "our", with: "or").replacingOccurrences(of: "is", with: "iz") })
    }

    /// Whether two notes' telling words put them on the same subject: at least two shared, and at least
    /// half of the shorter note's. (One shared word is enough when the shorter note has only one or two.)
    static func sameSubject(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shared = a.intersection(b).count, small = min(a.count, b.count)
        guard small > 0 else { return false }
        if small <= 2 { return shared == small }
        return shared >= 2 && shared * 2 >= small
    }

    /// Whether a point says there is nothing ("None noted").
    static func isNothing(_ point: String) -> Bool {
        let key = point.lowercased().filter(\.isLetter)
        if key.isEmpty || ["notapplicable", "na"].contains(key) { return true }
        // "None noted", "No decision noted.", "Nothing was decided": short, and starting with a no.
        return key.count <= 32 && ["none", "nodecision", "nothing", "noaction", "notasks", "nokeypoints"].contains { key.hasPrefix($0) }
    }

    /// Whether two points say the same thing: most of the shorter one's meaningful words are in the other.
    static func sameThing(_ a: String, _ b: String) -> Bool {
        let x = meaningful(a), y = meaningful(b)
        guard x.count >= 3, y.count >= 3 else { return TextCleaner.wordKey(a) == TextCleaner.wordKey(b) }
        return Double(x.intersection(y).count) >= 0.8 * Double(min(x.count, y.count))
    }

    /// One notes draft from the drafts written for each part of a long transcript, in order: under each
    /// wanted heading, every part's points for it, so the end of the recording is in the notes as surely as
    /// the start. Each part gives at most `perPart(title)` points to a section (its first, which the model
    /// puts the weightiest in); a point that says what an earlier one said is left out, and "None noted"
    /// only stays when no part had anything. Nothing here asks the model to combine: asked to, it copies
    /// the first part's points until it runs out of room.
    public static func mergedDraft(parts: [[(title: String, bullets: [String])]], wanted: [String], perPart: (String) -> Int) -> String {
        wanted.map { title in
            var kept: [String] = []
            for part in parts {
                let bullets = part.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }?.bullets ?? []
                var taken = 0
                for bullet in bullets where taken < perPart(title) && !isNothing(bullet) {
                    let text = bullet.trimmingCharacters(in: .whitespaces)
                    if kept.contains(where: { sameThing($0, text) }) { continue }
                    kept.append(text)
                    taken += 1
                }
            }
            return "## \(title)\n" + (kept.isEmpty ? ["None noted"] : kept).map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The words of a line that carry its meaning, in a form that matches across small changes of ending.
    static func meaningful(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word -> String in
            // "testers" and "tester", "sending" and "send" count as the same word.
            var w = String(word)
            for ending in ["ing", "ed", "es", "s"] where w.count > ending.count + 3 && w.hasSuffix(ending) {
                w.removeLast(ending.count)
                break
            }
            return w
        }.filter { $0.count > 2 && !plain.contains($0) })
    }

    /// The notes as one document: each line the user typed, with what Chirp wrote about the same thing
    /// placed under it, then the rest of what Chirp wrote under its own headings. The user's words are
    /// never changed and Chirp's are never mixed into them, so the two can be shown apart (the user's
    /// text in full colour, Chirp's fainter). Tasks stay together in their own section.
    public struct WovenNotes: Sendable, Equatable {
        /// One line the user typed.
        public struct Mine: Sendable, Equatable {
            public var text: String
            /// Points Chirp wrote that are about this line.
            public var added: [String]
        }

        /// A heading of Chirp's notes with the points that stayed under it.
        public struct Section: Sendable, Equatable {
            public var title: String
            public var points: [String]
        }

        public var mine: [Mine]
        public var sections: [Section]
    }

    /// Places each point of `summary` under the line of `userNotes` it is about, at most `perLine` to a
    /// line; points about none of the lines stay under their own headings.
    public static func weave(userNotes: String, summary: String, perLine: Int = 3) -> WovenNotes {
        var mine = userNotes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•*")).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { WovenNotes.Mine(text: $0, added: []) }
        let lineWords = mine.map { meaningful($0.text) }
        var sections: [WovenNotes.Section] = []
        for section in MeetingText.sections(of: summary) {
            var kept: [String] = []
            for point in section.bullets {
                // A list of tasks is kept whole, and "None noted" belongs to its heading.
                guard !Prompts.isTaskSection(section.title), point.caseInsensitiveCompare("None noted") != .orderedSame else {
                    kept.append(point)
                    continue
                }
                let words = meaningful(point)
                var best: (line: Int, shared: Int)?
                for (i, mineWords) in lineWords.enumerated() where mine[i].added.count < perLine {
                    let shared = words.intersection(mineWords).count
                    // A sparse note ("Budget is mine") matches on one word; a fuller one needs two.
                    let needed = mineWords.count <= 3 ? 1 : 2
                    if shared >= needed, shared > (best?.shared ?? 0) { best = (i, shared) }
                }
                if let best { mine[best.line].added.append(point) } else { kept.append(point) }
            }
            // A heading whose every point moved under the user's own lines has nothing left to say.
            if !kept.isEmpty || section.bullets.isEmpty { sections.append(.init(title: section.title, points: kept)) }
        }
        return WovenNotes(mine: mine, sections: sections)
    }

    /// Where in the transcript a point in the notes came from: the line that shares the most of its
    /// meaningful words, or nil when nothing is close enough to point at.
    public static func source(of point: String, in segments: [TranscriptSegment]) -> Int? {
        let words = meaningful
        let wanted = words(point)
        guard wanted.count >= 2 else { return nil }
        var best: (index: Int, shared: Int)?
        for (index, segment) in segments.enumerated() {
            let shared = wanted.intersection(words(segment.text)).count
            if shared > (best?.shared ?? 0) { best = (index, shared) }
        }
        guard let best, best.shared >= 2, Double(best.shared) / Double(wanted.count) >= 0.4 else { return nil }
        return best.index
    }

    /// Words too common to show that two lines are about the same thing.
    private static let plain: Set<String> = [
        "the", "and", "for", "with", "that", "this", "will", "was", "are", "has", "have", "from", "they", "them", "their", "our",
        "you", "your", "not", "but", "can", "need", "needs", "speaker", "group", "team", "meeting", "about", "into", "than",
    ]

    /// A recording with nobody else in it is a voice note; anything with another speaker, or people invited, is a meeting.
    public static func kind(of segments: [TranscriptSegment], invited: [String]) -> ItemKind {
        segments.contains { $0.speaker != "Me" } || !invited.isEmpty ? .meeting : .voiceNote
    }

    /// How many words were spoken.
    public static func wordCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { $0 + TextStats.words($1.text) }
    }

    /// A title for a short voice note from its own opening words.
    public static func openingTitle(_ segments: [TranscriptSegment], maxWords: Int = 8) -> String {
        let words = segments.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "" }
        let head = words.prefix(maxWords).joined(separator: " ")
        // Stop at the end of the first sentence when it comes early.
        let sentence = head.firstIndex(where: { ".?!".contains($0) }).map { String(head[..<$0]) } ?? head
        let text = (TextStats.words(sentence) >= 3 ? sentence : head)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-"))
        return words.count > maxWords && text == head.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-")) ? text + "…" : text
    }

    /// The lines with repeats removed: the same words again, whatever the capitals and punctuation.
    public static func unique(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let key = TextCleaner.wordKey(line)
            return key.isEmpty || seen.insert(key).inserted
        }
    }

    /// The material handed to the language model for the final notes: what the recording knows about
    /// itself, the user's own notes, then the points.
    /// `transcript` is true when `points` holds the transcript itself rather than notes taken from it.
    /// `reference` is a short excerpt of the files attached to the recording. It goes in under its own
    /// tags, and is said not to have been spoken.
    public static func notesMaterial(
        userNotes: String, points: [String], transcript: Bool = false, context: RecordingContext? = nil, reference: String? = nil
    ) -> String {
        var parts: [String] = []
        if let about = context?.material() { parts.append(about) }
        if let reference, !reference.isEmpty {
            parts.append(
                "REFERENCE FILES (attached to the recording, NOT said in it; only for spelling the names, terms and figures the transcript mentions):\n"
                    + "<reference_files>\n\(reference)\n</reference_files>")
        }
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("MY OWN NOTES (written by \"Me\"):\n\(notes)") }
        parts.append((transcript ? "TRANSCRIPT:\n" : "POINTS FROM THE TRANSCRIPT:\n") + points.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}

/// Something a person said they would do, or asked for, in a meeting. Who owns it comes from who said
/// it and how, worked out by rule: a language model asked to read a whole transcript mixes the owners up.
public struct Commitment: Sendable, Equatable {
    /// "I" for the person recording, a speaker label, a name that was said, or "Everyone".
    public var owner: String
    /// True when the speaker asked for this rather than taking it on.
    public var isRequest: Bool
    /// The sentence as it was said.
    public var sentence: String
    /// The task in the speaker's own words, without the "I will" part.
    public var task: String
    /// What was said just before, for working out what "it" or "them" means.
    public var context: String

    /// One line "Owner: task", the form the rules work in.
    public func bullet(task text: String? = nil) -> String {
        let t = (text ?? task).trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return isRequest ? "\(owner) asked: \(t)" : "\(owner): \(t)"
    }

    /// The same as an ordinary point for the notes: "I will send the numbers by Wednesday", "Priya will
    /// fix the bug", "Speaker 2 asked: send the slides".
    public func point(task text: String? = nil) -> String {
        let t = (text ?? task).trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return isRequest ? "\(owner) asked: \(t)" : "\(owner) will \(t)"
    }
}

extension MeetingText {
    private static let firstPerson = try! NSRegularExpression(
        // "I'll go ahead and" comes before "I'll": the first that fits is used, and after "I'll" it never got a turn.
        pattern: #"\b(?:I will|I'll go ahead and|I’ll go ahead and|I'll|I’ll|I can|I am going to|I'm going to|I’m going to|let me|I need to|I have to)\s+(.+)"#,
        options: [.caseInsensitive])
    private static let group = try! NSRegularExpression(
        pattern: #"\b(?:let's|let’s|we will|we'll|we’ll|we need to|we should|we have to)\s+(.+)"#, options: [.caseInsensitive])
    /// "Priya will fix it", "Jana and Francine have to build it". The second group is the form, the third the task.
    private static let named = try! NSRegularExpression(
        pattern: #"\b([A-Z][a-z]+(?: and [A-Z][a-z]+)?),?\s+(will|is going to|are going to|is supposed to|are supposed to|needs to|need to|has to|have to)\s+(.+)"#)
    /// "Dan, can you ask her": a job handed to a person by name.
    private static let handed = try! NSRegularExpression(
        pattern: #"\b([A-Z][a-z]+),?\s+(?:can you|could you|would you|will you)\s+(?:also\s+|please\s+)?(.+)"#)
    /// "the designer will…", "the UID is supposed to…": a job given to a role. Only words that name a
    /// person's role count, or initials; "the remote will have a screen" is about a thing.
    private static let role = try! NSRegularExpression(
        pattern: #"\b[Tt]he\s+((?:[a-z]+\s+)?(?:manager|designer|expert|engineer|specialist|lead|developer|team|coordinator|director|editor|writer|analyst|assistant|secretary|chair)|[A-Z]{2,5})\s+(?:will|is going to|is supposed to|needs to|has to)\s+(.+)"#)
    /// A request, where a clause starts: "Could you send the slides?", "so please send them to me". Not
    /// the same words in the middle of a question ("what would you get out of it").
    private static let request = try! NSRegularExpression(
        pattern: #"(?:^|[,;:]\s+|\b(?:and|so|okay|ok|but|then|now)\s+)(?:please|can you|could you|would you)\s+(?:please\s+)?(.+)"#,
        options: [.caseInsensitive])
    /// Capitalised words that start sentences but are not people.
    private static let notNames: Set<String> = [
        "It", "This", "That", "There", "These", "Those", "We", "They", "He", "She", "You", "What", "Who", "Which",
        "Everyone", "Someone", "Nobody", "Nothing", "Something", "Then", "So", "And", "But", "If", "When",
        // Noises and openers the transcript writes with a capital, and words for things.
        "Uh", "Um", "Er", "Ah", "Oh", "Hmm", "Okay", "Ok", "Yeah", "Yes", "No", "Well", "Right", "Now", "Maybe", "Ours", "Our", "Mine",
        "Yours", "Here", "Honor", "People", "Users", "One", "Each", "All", "Both", "Because", "Where", "How", "Why", "Or", "Also", "Just", "Like",
    ]
    /// "I can see…" and the like are not offers to do something.
    private static let notActions: Set<String> = [
        "see", "hear", "tell", "imagine", "understand", "say", "be", "think", "remember", "confirm that", "not", "also", "just",
        "probably", "definitely", "only", "still", "never", "already", "always", "need", "have", "want", "know", "like",
        // Not verbs at all: what follows was not an instruction ("may it please the Court").
        "the", "a", "an", "you", "it", "that", "this", "we", "i", "to", "there", "they", "he", "she", "of", "in", "on", "at",
    ]

    /// How a meeting is steered while it is going on, which is not work to take away: "go on to the next
    /// slide", "move on", "come back to that", "wrap it up there". Said with a day or a deadline some of
    /// these are tasks ("start the fix on Monday"), so `hasDeadline` lets them through.
    private static let steering: Set<String> = [
        "go", "move", "start", "begin", "discuss", "jump", "see", "hear", "say", "turn", "repeat", "pass", "skip", "continue", "wrap",
        "stop", "recap", "finish", "hit", "point", "wait", "hold", "explain", "mention", "try", "consider", "stick", "focus",
        "concentrate", "assume", "imagine", "suppose", "add", "cut", "use", "present", "cover", "describe", "remain",
    ]
    private static let steeringPhrases = [
        "next slide", "previous slide", "next one", "next point", "come back to", "get back to", "back to that", "move on", "go on",
        "go back", "hear me", "see my screen", "share my screen", "wrap it up", "wrap up", "one second", "one moment", "a second",
        "look at", "talk about", "speak about", "come to that", "come back", "take the definition",
    ]
    /// A day, a date or "by …": the mark of work that is due.
    private static let deadline = try! NSRegularExpression(
        pattern: #"\b(?:by|before|tomorrow|tonight|today|this week|next week|this afternoon|this evening|end of|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|june|july|august|september|october|november|december|morning|o'clock|\d+(?:st|nd|rd|th))\b"#,
        options: [.caseInsensitive])

    static func hasDeadline(_ text: String) -> Bool {
        deadline.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The task without the noises around it: "um", "uh" and a trailing "and" or "but".
    static func tidyTask(_ task: String) -> String {
        var words = task.split(separator: " ").map(String.init)
        let noise: Set<String> = ["um", "uh", "er", "erm", "like", "so", "and", "but", "or", "then", "well"]
        func bare(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:?!")) }
        while let first = words.first, ["um", "uh", "er", "erm", "just", "also", "maybe", "probably", "then", "actually"].contains(bare(first)) { words.removeFirst() }
        while let last = words.last, noise.contains(bare(last)) { words.removeLast() }
        return words.filter { !["um", "uh", "er", "erm"].contains(bare($0)) }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?"))
    }

    /// Whether a task is steering the meeting rather than work to take away.
    static func isSteering(_ task: String) -> Bool {
        let lower = task.lowercased()
        if steeringPhrases.contains(where: lower.contains) { return true }
        let first = lower.split(separator: " ").first.map(String.init) ?? ""
        return steering.contains(first) && !hasDeadline(task)
    }

    /// What follows "and will…" in a line of notes: the part that says who does a task.
    private static let ownershipTail = try! NSRegularExpression(
        pattern: #"\s+(?:and|who|but)\s+(?:will|is going to|must|needs to|has to|should|agreed to|offered to)\b.*$"#, options: [.caseInsensitive])

    /// One group of the first match of `regex` in `s`, if there is one.
    private static func capture(_ regex: NSRegularExpression, _ s: String, group: Int) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range(at: group).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// Things a group says it will do right now, in the meeting, which are not tasks to carry away.
    private static let inMeeting: Set<String> = [
        "review", "start", "begin", "look", "go", "move", "discuss", "talk", "jump", "get", "see", "take", "turn", "hear", "say", "be",
    ]

    /// True when the task leans on an earlier sentence for its meaning ("fix it", "send them").
    public static func needsContext(_ task: String) -> Bool {
        let words = Set(task.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["it", "them", "that", "this", "those", "these", "one"])
    }

    /// Removes lines that say who will do what from the parts of the notes that are not the task list.
    /// The model writing those parts often names the wrong person; the task list is worked out separately.
    public static func withoutOwnershipClaims(_ draft: String, speakers: [String], taskSection: (String) -> Bool) -> String {
        let names = (speakers + ["I", "Me", "We"]).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let claim = Patterns.regex(
            "\\b(?:\(names))\\s+(?:will|is going to|am going to|must|needs? to|has to|have to|should|agreed to|offered to|volunteered to|promised to)\\b",
            options: [.caseInsensitive])
        else { return draft }
        let tail = ownershipTail
        var out: [String] = []
        var inTasks = false
        var kept = 0
        var heading: Int?
        func closeSection() {
            if let heading, kept == 0, !inTasks { out.insert("- None noted", at: heading + 1) }
        }
        for line in draft.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                closeSection()
                inTasks = taskSection(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                heading = out.count
                kept = 0
                out.append(line)
                continue
            }
            let isBullet = line.trimmingCharacters(in: .whitespaces).hasPrefix("-")
            if !inTasks, isBullet, claim.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                continue
            }
            if isBullet { kept += 1 }
            // "Speaker 1 raised the bug and will fix it": keep what was raised, drop who fixes it.
            let ns = line as NSString
            if !inTasks, isBullet, let m = tail.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(to: m.range.location).trimmingCharacters(in: CharacterSet(charactersIn: " ,")) + ".")
            } else {
                out.append(line)
            }
        }
        closeSection()
        return out.joined(separator: "\n")
    }

    /// Whether the words after "I will" are something to do: at least two words, not starting with "see", "be" and the like.
    private static func isAction(_ task: String) -> Bool {
        let words = task.split(separator: " ")
        let first = words.first.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:?!-")) } ?? ""
        guard !first.isEmpty, !notActions.contains(first), words.count >= 2, first.allSatisfy(\.isLetter) else { return false }
        // "do that", "do it": nothing to write down.
        if first == "do", !["the", "a", "an", "some", "my", "our", "your"].contains(words.dropFirst().first.map { $0.lowercased() } ?? "") { return false }
        return !isSteering(task)
    }

    /// The commitments and requests in a transcript, in the order they were said.
    ///
    /// A line is a task only when it has the form of one: someone taking it on ("I will…"), someone given
    /// it by name or role ("Priya will…", "Dan, can you…", "the designer is supposed to…"), a request
    /// ("could you send…"), or the group setting itself something with a day on it ("let's meet again next
    /// Tuesday"). Steering the meeting ("go on to the next slide", "let's come back to that"), what the
    /// group thinks the product should do ("we should use rubber"), noises taken for names ("Uh") and
    /// half-sentences are left out: a short list that is right is worth more than a long one.
    public static func commitments(in segments: [TranscriptSegment], me: String = "Me") -> [Commitment] {
        var out: [Commitment] = []
        var recent: [String] = []
        // Where the meeting is being wound up, jobs are handed out more loosely ("you two have to…").
        let total = segments.reduce(0) { $0 + $1.text.count }
        var passed = 0
        for segment in segments {
            let speaker = segment.speaker == me ? "I" : segment.speaker
            for sentence in ReadingText.sentences(segment.text).map(\.text) {
                defer {
                    recent.append(sentence)
                    if recent.count > 2 { recent.removeFirst() }
                    passed += sentence.count + 1
                }
                let closing = passed * 100 >= total * 85
                let context = recent.joined(separator: " ")
                let lower = sentence.lowercased()
                // An example of what someone might say or do is not a promise.
                if lower.contains("for example") || lower.hasPrefix("if ") || lower.contains("let's say") || lower.contains("let’s say") { continue }
                func add(_ owner: String, request: Bool, _ raw: String) {
                    let task = tidyTask(raw)
                    guard isAction(task), task.split(separator: " ").count >= 2 else { return }
                    out.append(Commitment(owner: owner, isRequest: request, sentence: sentence, task: task, context: context))
                }
                // A job handed to someone by name: "Dan, can you also ask her".
                if let name = capture(handed, sentence, group: 1), !notNames.contains(name), let task = capture(handed, sentence, group: 2) {
                    add(name, request: false, task)
                } else if let name = capture(named, sentence, group: 1), name.components(separatedBy: " and ").allSatisfy({ !notNames.contains($0) }),
                    let form = capture(named, sentence, group: 2), let task = capture(named, sentence, group: 3)
                {
                    // "Priya will fix it". "Has to" and "needs to" say what is true of someone as often as
                    // what they took on, so alone they count only for two people named together, or at the close.
                    let firm = form == "will" || form.contains("going to") || form.contains("supposed to")
                    if firm || name.contains(" and ") || closing { add(name, request: false, task) }
                } else if let who = capture(role, sentence, group: 1), let task = capture(role, sentence, group: 2) {
                    add("The " + who, request: false, task)
                } else if let task = capture(firstPerson, sentence, group: 1), !lower.hasSuffix("?") {
                    add(speaker, request: false, task)
                } else if let task = capture(request, sentence, group: 1) {
                    add(speaker, request: true, task)
                } else if let task = capture(group, sentence, group: 1), hasDeadline(task),
                    !inMeeting.contains(task.split(separator: " ").first.map { $0.lowercased() } ?? "")
                {
                    // What the group sets itself counts when it has a day on it; without one it is talk about
                    // what the thing being made should be like.
                    add("Everyone", request: false, task)
                }
            }
        }
        // Something promised twice is one task.
        var kept: [Commitment] = []
        for commitment in out where !kept.contains(where: { $0.owner.lowercased() == commitment.owner.lowercased() && sameThing($0.task, commitment.task) }) {
            kept.append(commitment)
        }
        return kept
    }
}
