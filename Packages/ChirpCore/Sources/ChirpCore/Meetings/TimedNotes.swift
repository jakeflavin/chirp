import Foundation

/// What the user chose to record, by how they started it. Chirp does not guess: Record on the perch is
/// a voice note, and a meeting is started from the offer when a call begins or by hand ("Record a
/// Meeting").
public enum RecordingKind: String, Codable, Sendable, CaseIterable {
    /// The user's own words: saved as clean text with a title. No speakers, no notes written about it.
    case voiceNote
    /// Several people: a transcript with speakers, then a summary, key points and decisions.
    case meeting

    /// The library kind a recording of this kind is saved as.
    public var itemKind: ItemKind { self == .meeting ? .meeting : .voiceNote }

    /// What the perch, the menu bar and the Library call it while it is being made: a voice note reads as
    /// a note ("Note · 0:26"); a meeting keeps "record".
    public var name: String { self == .meeting ? "Meeting" : "Note" }

    /// The title of one nobody has named yet.
    public var untitled: String { self == .meeting ? "New meeting" : "New note" }
}

/// Something the user kept at a moment of a recording: a line typed and sent with Enter, or a picture
/// of the window in front. Both are the same thing with different content: they sit in the transcript
/// at their time and in "My notes", and neither is given to the step that writes a meeting's notes.
public struct TimedNote: Codable, Sendable, Equatable, Identifiable {
    /// Seconds after the recording began.
    public var at: Double
    /// What was typed. Empty for a picture.
    public var text: String
    /// For a picture: its file name inside the audio folder.
    public var image: String?
    /// For a picture: the app and window it shows.
    public var app: String?
    public var window: String?
    /// For a picture: the words read off it. Used for search only.
    public var seen: String?

    public init(at: Double, text: String = "", image: String? = nil, app: String? = nil, window: String? = nil, seen: String? = nil) {
        self.at = at
        self.text = text
        self.image = image
        self.app = app
        self.window = window
        self.seen = seen
    }

    public var id: String { "\(at)|\(image ?? text)" }

    /// Whether this is a picture of a window rather than a typed line.
    public var isPicture: Bool { image != nil }

    /// What stands for it in a list: the typed line, or what the picture is of.
    public var line: String {
        guard isPicture else { return text }
        let named = [window, app].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return named.map { "Picture of \($0)" } ?? "Picture of the front window"
    }

    /// The small line under a picture in the transcript: "Keynote · Test results".
    public var caption: String {
        let parts = [app, window].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Picture of the front window" : parts.joined(separator: " · ")
    }

    /// The time as it is shown: "5:20".
    public var clock: String { at.clock }
}

extension MeetingText {
    /// One thing in a recording's timeline: something said, or something the user kept.
    public enum TimelineEntry: Sendable, Equatable, Identifiable {
        case line(TranscriptSegment)
        case note(TimedNote)

        public var at: Double {
            switch self {
            case .line(let segment): segment.start
            case .note(let note): note.at
            }
        }

        public var id: String {
            switch self {
            case .line(let segment): "line|\(segment.speaker)|\(segment.start)"
            case .note(let note): "note|\(note.id)"
            }
        }
    }

    /// What was said and what the user kept, in the order it happened. A note sent while somebody was
    /// talking comes after the line that was being said, as a message does in a conversation.
    public static func timeline(lines: [TranscriptSegment], notes: [TimedNote]) -> [TimelineEntry] {
        let said = lines.sorted { $0.start < $1.start }.map(TimelineEntry.line)
        let kept = notes.sorted { $0.at < $1.at }.map(TimelineEntry.note)
        var out: [TimelineEntry] = []
        var i = 0
        var j = 0
        while i < said.count || j < kept.count {
            if j >= kept.count || (i < said.count && said[i].at <= kept[j].at) {
                out.append(said[i])
                i += 1
            } else {
                out.append(kept[j])
                j += 1
            }
        }
        return out
    }

    /// The index of the line being said at `time`: the last one that had started by then. Nil before the first.
    public static func lineIndex(at time: Double, in lines: [TranscriptSegment]) -> Int? {
        lines.lastIndex { $0.start <= time + 0.05 }
    }

    /// A voice note as clean text: the user's words in paragraphs, a new one where they paused for a
    /// while or the paragraph has run long and a sentence ends. Nothing is added and nothing is left out.
    public static func cleanText(_ lines: [TranscriptSegment], pause: Double = 2.5, longest: Int = 420) -> String {
        var paragraphs: [String] = []
        var current = ""
        var lastEnd: Double?
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let ended = current.last.map { ".?!".contains($0) } ?? false
            let paused = lastEnd.map { line.start - $0 > pause } ?? false
            if !current.isEmpty, ended, paused || current.count >= longest {
                paragraphs.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + text
            lastEnd = line.end
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Whether a line of the user's is the Mac's own sound heard by the microphone: said at about the same
    /// time as lines from the other side, and mostly their words. `slack` is how far apart in seconds the
    /// two may be (the two sides are cut into pieces at different moments).
    public static func isEcho(_ mine: TranscriptSegment, of others: [TranscriptSegment], slack: Double = 1, share: Double = 0.7) -> Bool {
        let said = echoWords(mine.text)
        guard said.count >= 3 else { return false }
        var heard = Set<String>()
        for other in others where other.start < mine.end + slack && other.end > mine.start - slack {
            heard.formUnion(echoWords(other.text))
        }
        return Double(said.intersection(heard).count) / Double(said.count) >= share
    }

    static func echoWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The live transcript as it is shown: on loudspeakers, without the user's lines that repeat what the
    /// Mac just played; on headphones, as it was heard. The same rule is used when the recording is saved.
    public static func shown(_ lines: [TranscriptSegment], headphones: Bool, me: String = "Me") -> [TranscriptSegment] {
        headphones ? lines : dropEchoes(lines, me: me)
    }

    /// The other side's lines, with the speaker of each word decided on its own: a line is split where the
    /// voice changes. `words` are the words of those lines with their times; a line with no words of its
    /// own keeps the speaker who talks for most of it. Speakers are numbered from `first` in the order heard.
    public static func speakersByWord(
        _ lines: [TranscriptSegment], words: [SaidWord], turns: [SpeakerTurn], replacing label: String, startingAt first: Int = 1
    ) -> [TranscriptSegment] {
        guard Set(turns.map(\.speaker)).count > 1 else { return lines }
        var names: [String: String] = [:]
        func name(_ speaker: String) -> String {
            if names[speaker] == nil { names[speaker] = "Speaker \(names.count + first)" }
            return names[speaker]!
        }
        func talker(from start: Double, to end: Double) -> String? {
            var overlap: [String: Double] = [:]
            var nearest: (speaker: String, gap: Double)?
            for turn in turns {
                let o = min(end, turn.end) - max(start, turn.start)
                if o > 0 { overlap[turn.speaker, default: 0] += o } else if -o < (nearest?.gap ?? .infinity) { nearest = (turn.speaker, -o) }
            }
            if let best = overlap.max(by: { $0.value < $1.value })?.key { return best }
            if let nearest, nearest.gap <= 1 { return nearest.speaker }
            return nil
        }
        var out: [TranscriptSegment] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            guard line.speaker == label else {
                out.append(line)
                continue
            }
            let own = words.filter { $0.start >= line.start - 0.01 && $0.end <= line.end + 0.01 }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
            guard !own.isEmpty else {
                var whole = line
                if let who = talker(from: line.start, to: line.end) { whole.speaker = name(who) }
                out.append(whole)
                continue
            }
            var who: [String?] = own.map { talker(from: $0.start, to: $0.end) }
            for i in who.indices where who[i] == nil { who[i] = i > 0 ? who[i - 1] : nil }
            for i in who.indices.reversed() where who[i] == nil { who[i] = i + 1 < who.count ? who[i + 1] : nil }
            // One or two words given to somebody else inside a person's sentence are a slip, not a turn.
            var i = 0
            while i < who.count {
                var j = i
                while j + 1 < who.count, who[j + 1] == who[i] { j += 1 }
                if j - i + 1 <= 2, own[j].end - own[i].start < 0.8, i > 0, j + 1 < who.count, who[i - 1] == who[j + 1] {
                    for k in i...j { who[k] = who[i - 1] }
                }
                i = j + 1
            }
            var start = 0
            for k in own.indices {
                let last = k == own.count - 1
                if last || who[k + 1] != who[start] {
                    let run = own[start...k]
                    out.append(
                        TranscriptSegment(
                            itemID: line.itemID, speaker: who[start].map(name) ?? label, start: run.first!.start, end: max(run.last!.end, run.first!.start),
                            text: run.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
                    start = k + 1
                }
            }
        }
        return out
    }
}

/// Jobs that take turns: transcribing a link or a file, writing a recording's notes. One runs; the
/// others wait in the order they were asked for and say what they are waiting for. Nothing is refused.
/// Dictation and a live recording are never put here.
public struct JobLine: Sendable, Equatable {
    public struct Job: Sendable, Equatable, Identifiable {
        public var id: Int
        /// What it is called when another job waits for it: "the link", "Design sync".
        public var name: String
        /// The library item it belongs to, when it has one.
        public var itemID: Int64?

        public init(id: Int, name: String, itemID: Int64? = nil) {
            self.id = id
            self.name = name
            self.itemID = itemID
        }
    }

    /// The first is running; the rest wait, in order.
    public private(set) var jobs: [Job] = []
    private var nextID = 1

    public init() {}

    /// Puts a job at the end of the line and returns its number.
    public mutating func add(_ name: String, itemID: Int64? = nil) -> Int {
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, name: name, itemID: itemID))
        return id
    }

    /// Takes a job out: it finished, or was cancelled while it waited.
    public mutating func remove(_ id: Int) { jobs.removeAll { $0.id == id } }

    /// Gives a job its library item once it has one.
    public mutating func set(itemID: Int64, for id: Int) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].itemID = itemID }
    }

    public var running: Job? { jobs.first }
    public var waiting: [Job] { Array(jobs.dropFirst()) }
    public func isRunning(_ id: Int) -> Bool { jobs.first?.id == id }
    public func isWaiting(_ id: Int) -> Bool { jobs.dropFirst().contains { $0.id == id } }

    /// What a waiting job says: "Waiting for the link to finish…". Nil when it is not waiting.
    public func waitingLine(for id: Int) -> String? {
        guard isWaiting(id), let first = jobs.first else { return nil }
        return Self.waitingLine(for: first.name)
    }

    public static func waitingLine(for name: String) -> String { "Waiting for \(name) to finish…" }

    /// The first waiting job and what it waits for, for the perch and the menu bar.
    public var firstWaiting: (job: Job, line: String)? {
        guard jobs.count > 1 else { return nil }
        return (jobs[1], Self.waitingLine(for: jobs[0].name))
    }
}

/// The words a row of the Library shows for something that is not finished yet.
public enum ProgressLine {
    /// A recording being made: "Recording · 1:02".
    public static func recording(elapsed: Double) -> String { "Recording · \(elapsed.clock)" }
    /// A voice note being made reads as a note, not a recording: "Note · 0:26".
    public static func recording(_ kind: RecordingKind, elapsed: Double) -> String {
        kind == .meeting ? recording(elapsed: elapsed) : "Note · \(elapsed.clock)"
    }
    /// After Stop, until it is saved.
    public static let finishing = "Finishing…"
    /// A saved meeting whose notes are being written.
    public static let writingNotes = "Writing notes…"
    /// From Stop on those notes until the language model has let go.
    public static let stoppingNotes = "Stopping…"
}
