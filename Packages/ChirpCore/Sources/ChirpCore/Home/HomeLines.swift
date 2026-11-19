import Foundation

/// Home's welcome line: a greeting for the time of day and one plain line made from real things.
/// Written by rule, so it is instant and needs no model.
public enum WelcomeLine {
    /// What the line is made from.
    public struct Day: Equatable, Sendable {
        /// Meetings saved today.
        public var recordings: Int
        /// Notes saved today, typed or spoken (a voice note is a note).
        public var notes: Int
        /// Documents saved today.
        public var documents: Int
        /// The next meeting on the calendar still to come today, when there is one.
        public var nextMeeting: Date?

        public init(recordings: Int = 0, notes: Int = 0, documents: Int = 0, nextMeeting: Date? = nil) {
            self.recordings = recordings
            self.notes = notes
            self.documents = documents
            self.nextMeeting = nextMeeting
        }
    }

    /// "Good morning" from 5, "Good afternoon" from 12, "Good evening" from 18 and through the night.
    public static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// The one line. A meeting about to start comes first, then what was captured today, then that
    /// nothing has been yet.
    public static func line(_ day: Day, now: Date, calendar: Calendar = .current) -> String {
        if let start = day.nextMeeting {
            let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
            if (0...60).contains(minutes) {
                let at = clock(start, calendar: calendar)
                return minutes < 1 ? "Your \(at) meeting starts now." : "Your \(at) meeting starts in \(count(minutes, "minute"))."
            }
        }
        var parts: [String] = []
        if day.notes > 0 { parts.append(count(day.notes, "note")) }
        if day.recordings > 0 { parts.append(count(day.recordings, "meeting")) }
        if day.documents > 0 { parts.append(count(day.documents, "document")) }
        guard let first = parts.first else { return "Nothing captured yet today." }
        // "A note, a meeting and a document today."
        let said = parts.count == 1 ? first : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return said.prefix(1).uppercased() + said.dropFirst() + " today."
    }

    /// "2 pm", "2:30 pm".
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let half = hour < 12 ? "am" : "pm"
        return minute == 0 ? "\(twelve) \(half)" : String(format: "%d:%02d %@", twelve, minute, half)
    }

    /// "a recording", "two recordings", "14 documents": one is "a", up to twelve is a word.
    public static func count(_ n: Int, _ noun: String) -> String {
        if n == 1 { return "\(noun.first.map { "aeiou".contains($0) } == true ? "an" : "a") \(noun)" }
        return "\(word(n)) \(noun)s"
    }

    /// Small numbers as words, the way they are written in a sentence.
    public static func word(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(n) ? words[n] : n.formatted()
    }
}

/// Home's bird once a meeting's notes are ready: it stops pecking and looks at the new row for a
/// moment.
public enum HomeBird {
    /// How long it looks before it sits as it was.
    public static let lookSeconds: Double = 4
    /// Down and to the left: the rows are under the welcome line, and the bird is at its right end.
    public static let rowGaze = (x: -2.0, y: 2.0)

    /// True when notes that were being written have just been finished and are there to read: not
    /// while others are still being written, not when they were stopped part-way or could not be written.
    public static func looksAtNewRow(wasWriting: Int64?, nowWriting: Int64?, stopped: Int64?, hasNotes: Bool) -> Bool {
        guard let was = wasWriting, nowWriting == nil, stopped != was else { return false }
        return hasNotes
    }
}

/// "This week" on Home: a few counts Chirp already keeps. A count of nothing is left out, and with
/// nothing to count the section is not shown.
public struct WeekCounts: Equatable, Sendable {
    public var recordedSeconds: Double
    public var wordsDictated: Int
    public var documentsRead: Int
    public var fixesAccepted: Int

    public init(recordedSeconds: Double = 0, wordsDictated: Int = 0, documentsRead: Int = 0, fixesAccepted: Int = 0) {
        self.recordedSeconds = recordedSeconds
        self.wordsDictated = wordsDictated
        self.documentsRead = documentsRead
        self.fixesAccepted = fixesAccepted
    }

    /// One number and what it counts.
    public struct Tile: Equatable, Sendable, Identifiable {
        public var value: String
        public var label: String
        public var id: String { label }
    }

    /// Counts what was saved since `weekStart`. Dictations are left to their kind; a document counts as
    /// read when its place moved this week.
    public init(items: [SavedItem], since weekStart: Date, fixesAccepted: Int = 0) {
        self.init(fixesAccepted: fixesAccepted)
        for item in items {
            switch item.kind {
            case .meeting, .voiceNote:
                if item.createdAt >= weekStart { recordedSeconds += item.duration }
            case .dictation:
                if item.createdAt >= weekStart { wordsDictated += item.body.split { $0.isWhitespace }.count }
            case .document, .note:
                if item.position > 0, item.updatedAt >= weekStart { documentsRead += 1 }
            }
        }
    }

    public var tiles: [Tile] {
        var out: [Tile] = []
        if recordedSeconds >= 60 { out.append(Tile(value: DocumentRows.length(recordedSeconds), label: "recorded")) }
        if wordsDictated > 0 { out.append(Tile(value: wordsDictated.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))), label: wordsDictated == 1 ? "word dictated" : "words dictated")) }
        if documentsRead > 0 { out.append(Tile(value: "\(documentsRead)", label: documentsRead == 1 ? "document read" : "documents read")) }
        if fixesAccepted > 0 { out.append(Tile(value: "\(fixesAccepted)", label: fixesAccepted == 1 ? "fix accepted" : "fixes accepted")) }
        return out
    }

    /// The Monday (or the calendar's first weekday) the week of `date` began.
    public static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

/// "Try this" on Home: one tip at a time, made from what Chirp already knows, with its action. It goes
/// when dismissed, and a dismissal keeps the section quiet for a while so it stays rare.
public struct HomeTip: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        /// Save this sentence as a snippet.
        case saveSnippet(String)
        /// Add this word to the Dictionary, with the spelling it keeps being corrected from.
        case addWord(term: String, wrong: String)
        /// Open a new note in the perch.
        case newNote
        /// Choose a document to read aloud, or to summarize.
        case readDocument, summarizeDocument
    }

    public var id: String
    public var title: String
    public var detail: String
    public var button: String
    public var action: Action

    /// What a tip can be made from.
    public struct Facts: Sendable {
        /// Recent dictations' text, newest first.
        public var dictations: [String]
        /// The saved text of each snippet.
        public var snippets: [String]
        public var features: FeatureSet
        /// How many meetings and notes, how many notes, documents heard at all, and summaries there are.
        public var recordings: Int
        public var notes: Int
        public var documentsHeard: Int
        public var summaries: Int
        /// How many dictations there are: a feature is only suggested to someone who has used Chirp a little.
        public var dictationCount: Int
        /// Spellings put right, with how often, and the words already in the Dictionary.
        public var corrections: [Correction]
        public var dictionary: [String]

        public init(dictations: [String] = [], snippets: [String] = [], features: FeatureSet = .all, recordings: Int = 0, notes: Int = 0, documentsHeard: Int = 0, summaries: Int = 0, dictationCount: Int = 0, corrections: [Correction] = [], dictionary: [String] = []) {
            self.notes = notes
            self.corrections = corrections
            self.dictionary = dictionary
            self.dictations = dictations
            self.snippets = snippets
            self.features = features
            self.recordings = recordings
            self.documentsHeard = documentsHeard
            self.summaries = summaries
            self.dictationCount = dictationCount
        }
    }

    /// How often a sentence has to be dictated before it is worth a snippet.
    public static let repeatsNeeded = 3
    /// After a tip is dismissed nothing is suggested for this long.
    public static let quietAfterDismissal: TimeInterval = 3 * 24 * 3600

    /// The one tip to show, or nil. `dismissed` holds the ids put away; `lastDismissal` when the last one was.
    public static func pick(_ facts: Facts, dismissed: Set<String>, lastDismissal: Date?, now: Date) -> HomeTip? {
        if let lastDismissal, now.timeIntervalSince(lastDismissal) < quietAfterDismissal { return nil }
        return candidates(facts).first { !dismissed.contains($0.id) }
    }

    /// Every tip the facts support, the most useful first.
    public static func candidates(_ facts: Facts) -> [HomeTip] {
        var out: [HomeTip] = []
        if facts.features.isOn(.dictate), let (sentence, times) = repeated(in: facts.dictations, notIn: facts.snippets) {
            out.append(HomeTip(
                id: "repeat:" + key(sentence), title: "You have dictated “\(sentence)” \(WelcomeLine.word(times)) times",
                detail: "Save it as a snippet and say a short cue next time", button: "Save as a snippet", action: .saveSnippet(sentence)))
        }
        if facts.features.shows(FeaturePage.dictionary), let often = correctedOften(facts.corrections, notIn: facts.dictionary) {
            out.append(HomeTip(
                id: "word:" + often.right.lowercased(), title: "You have corrected “\(often.wrong)” to “\(often.right)” \(WelcomeLine.word(often.times)) times",
                detail: "Add it to your Dictionary and Chirp writes it that way when you dictate", button: "Add to Dictionary",
                action: .addWord(term: often.right, wrong: often.wrong)))
        }
        // A feature that is on and has never been used, once Chirp itself has been used a little.
        guard facts.dictationCount + facts.recordings >= 5 else { return out }
        if facts.features.isOn(.notes), facts.notes == 0 {
            out.append(HomeTip(id: "try:note", title: "You have not written a note yet", detail: "Type or say an idea; copy or export it later", button: "New note", action: .newNote))
        }
        if facts.features.isOn(.read), facts.documentsHeard == 0 {
            out.append(HomeTip(id: "try:read", title: "You have not listened to a document yet", detail: "Chirp reads a PDF, a book or a page aloud and keeps your place", button: "Choose a document", action: .readDocument))
        }
        if facts.features.isOn(.summarize), facts.summaries == 0 {
            out.append(HomeTip(id: "try:summarize", title: "You have not summarized a document yet", detail: "Get the main points of a long file before you read it", button: "Choose a document", action: .summarizeDocument))
        }
        return out
    }

    /// The sentence dictated most often (at least `repeatsNeeded` times), and how many times. Only a short
    /// whole dictation counts: two to twelve words, the same apart from capitals and its last mark.
    public static func repeated(in dictations: [String], notIn snippets: [String]) -> (sentence: String, times: Int)? {
        let saved = Set(snippets.map(key))
        var counts: [String: (text: String, times: Int, order: Int)] = [:]
        for (order, raw) in dictations.enumerated() {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = text.split { $0.isWhitespace }.count
            guard (2...12).contains(words), !text.contains("\n") else { continue }
            let k = key(text)
            guard !k.isEmpty, !saved.contains(k) else { continue }
            if let had = counts[k] { counts[k] = (had.text, had.times + 1, had.order) } else { counts[k] = (text, 1, order) }
        }
        let best = counts.values.filter { $0.times >= repeatsNeeded }.max { ($0.times, -$0.order) < ($1.times, -$1.order) }
        return best.map { ($0.text, $0.times) }
    }

    /// The word corrected most often (at least `repeatsNeeded` times) that reads as a name or a term
    /// of the user's own and is not in the Dictionary yet. Worked out by rule; no model.
    public static func correctedOften(_ corrections: [Correction], notIn dictionary: [String]) -> Correction? {
        let have = Set(dictionary.map { $0.lowercased() })
        return corrections
            .filter { $0.times >= repeatsNeeded && $0.isOwnTerm && !have.contains($0.right.lowercased()) }
            .max { ($0.times, $0.lastAt) < ($1.times, $1.lastAt) }
    }

    /// A sentence without capitals, outer spaces or its closing mark, so "Thanks, talk soon." and
    /// "thanks, talk soon" are the same one.
    static func key(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!?…"))
            .split { $0.isWhitespace }.joined(separator: " ")
    }
}

/// What the menu bar popover's settings area is about: the few settings that matter for what is being
/// done right now. Chosen when the popover opens; it does not change while it is open.
public enum MenuSituation: String, Sendable, CaseIterable {
    case writing, dictating, recording, reading, idle

    /// One row of the settings area.
    public enum Row: String, Sendable, CaseIterable {
        /// The writing style of the app in front, and underlines in it.
        case style, underlines
        case microphone, holdKey, macSound
        case voice, speed, citations
        /// The five feature switches as chips, and "Show the perch".
        case features, perch
        /// Always last.
        case allSettings
    }

    /// What Chirp and the user are doing, as far as the popover needs to know.
    public struct Doing: Sendable {
        public var dictating = false
        public var recording = false
        public var reading = false
        /// Writing checks are looking at a text field of the app in front.
        public var checkingWriting = false

        public init(dictating: Bool = false, recording: Bool = false, reading: Bool = false, checkingWriting: Bool = false) {
            self.dictating = dictating
            self.recording = recording
            self.reading = reading
            self.checkingWriting = checkingWriting
        }
    }

    /// Which situation it is. What Chirp is doing with sound comes before what is being typed; while
    /// Chirp is only working or waiting it is "nothing in particular".
    public static func pick(_ doing: Doing, features: FeatureSet) -> MenuSituation {
        if doing.dictating, features.isOn(.dictate) { return .dictating }
        if doing.recording, features.records { return .recording }
        if doing.reading, features.isOn(.read) { return .reading }
        if doing.checkingWriting, features.isOn(.write) { return .writing }
        return .idle
    }

    /// The area's heading: "Settings for Mail", "Settings for dictating", "Features".
    public func heading(app: String?) -> String {
        switch self {
        case .writing: "Settings for \(app ?? "this app")"
        case .dictating: "Settings for dictating"
        case .recording: "Settings for recording"
        case .reading: "Settings for reading aloud"
        case .idle: "Features"
        }
    }

    /// The rows, at most four, then "All settings…".
    public var rows: [Row] {
        switch self {
        case .writing: [.style, .underlines, .allSettings]
        case .dictating: [.microphone, .holdKey, .allSettings]
        case .recording: [.microphone, .macSound, .allSettings]
        case .reading: [.voice, .speed, .citations, .allSettings]
        case .idle: [.features, .perch, .allSettings]
        }
    }
}

/// What the perch says about a dropped file before anything is done with it.
public enum DroppedFile {
    /// "EPUB book · 288 pages · about 5 h to listen", "PDF · 14 pages · about 25 min to listen".
    public static func facts(format: String, pages: Int, listenSeconds: Double) -> String {
        var parts: [String] = []
        let kind = format.isEmpty ? "Document" : format
        parts.append(kind == "EPUB" ? "EPUB book" : kind)
        if pages > 0 { parts.append(pages == 1 ? "1 page" : "\(pages.formatted(.number.locale(Locale(identifier: "en_US")))) pages") }
        parts.append("about \(listen(listenSeconds)) to listen")
        return parts.joined(separator: " · ")
    }

    /// "25 min", "1 h 30 min"; whole hours from five hours up ("5 h"), where minutes say nothing.
    public static func listen(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes >= 300 { return "\(Int((Double(minutes) / 60).rounded())) h" }
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    /// The file's first lines in quotation marks, cut at a word with "…": what it is, at a glance.
    /// Empty for a file with no words.
    public static func firstLines(_ text: String, limit: Int = 150) -> String {
        let words = text.split { $0.isWhitespace || $0.isNewline }
        guard !words.isEmpty else { return "" }
        var out = ""
        for word in words {
            if out.count + word.count + 1 > limit { return "“\(out)…”" }
            out += out.isEmpty ? String(word) : " " + word
        }
        return "“\(out)”"
    }

    /// The actions offered, in order; the first is the one Return presses. "Attach to this recording"
    /// is there only while a recording is being made, and only for a file.
    public enum Offer: String, Sendable, CaseIterable {
        case attach, read, summarize, keep
    }

    public static func offers(features: FeatureSet, recording: Bool, isFile: Bool, kept: Bool) -> [Offer] {
        var out: [Offer] = []
        if recording, isFile, features.records { out.append(.attach) }
        if features.isOn(.read) { out.append(.read) }
        if features.isOn(.summarize) { out.append(.summarize) }
        if !kept, features.shows(FeaturePage.documents) { out.append(.keep) }
        return out
    }
}

/// The steps of onboarding (ten of them). A step for a feature that is switched
/// off is left out.
public enum OnboardingStep: String, CaseIterable, Sendable, Identifiable {
    /// `recording` is the Meetings step (it keeps its name for links); `notes` is the Notes step before it.
    case features, dictation, shortcuts, permissions, models, language, writing, notes, recording, reading

    public var id: String { rawValue }

    public static func shown(for features: FeatureSet) -> [OnboardingStep] {
        allCases.filter { step in
            switch step {
            case .features, .shortcuts, .permissions, .models: true
            case .dictation: features.isOn(.dictate)
            case .language: features.shows(FeaturePage.dictionary) || features.shows(FeaturePage.snippets) || features.shows(FeaturePage.style)
            case .writing: features.isOn(.write)
            case .notes: features.isOn(.notes)
            case .recording: features.isOn(.meetings)
            case .reading: features.isOn(.read) || features.isOn(.summarize)
            }
        }
    }

    /// The step to show after the features changed under it: the same one when it is still there, else
    /// the nearest one before it.
    public static func keep(_ step: OnboardingStep, in shown: [OnboardingStep]) -> OnboardingStep {
        if shown.contains(step) { return step }
        let before = allCases.prefix { $0 != step }.last { shown.contains($0) }
        return before ?? shown.first ?? .features
    }
}
