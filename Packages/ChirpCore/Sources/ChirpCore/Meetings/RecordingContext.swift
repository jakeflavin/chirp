import Foundation

/// What a recording knows about itself besides the sound: the calendar event it belongs to and the app
/// the call ran in. Saved with the recording, and given to the language model with the transcript so the
/// notes can use the right names and topic: event title and time,
/// participants and the source app.
public struct RecordingContext: Codable, Sendable, Equatable {
    /// A document given to the recording: dropped on Chirp while it ran, or added afterwards.
    public struct Attachment: Codable, Sendable, Equatable {
        public var name: String
        /// The start of its text; enough for names, numbers and terms. Empty for a file Chirp cannot read
        /// the text of (a picture, a kind it does not know): that file is kept and opens, and is not searched.
        public var text: String
        /// The copy of the file kept with the recording, by its name in the attachments folder. Nil for a
        /// document given before files were kept: only its text was.
        public var file: String?

        public init(name: String, text: String, file: String? = nil) {
            self.name = name
            self.text = text
            self.file = file
        }

        /// Whether its text was read, so it can be found by searching and helps the notes with spellings.
        public var isSearchable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// The line under its name in a list: what kind of file it is, or that it cannot be searched.
        public var kindLine: String {
            guard isSearchable else { return "Not searchable" }
            let ending = (name as NSString).pathExtension.uppercased()
            return ending.isEmpty ? "Document" : ending
        }
    }

    /// The text of every attachment, for the search index.
    public var attachmentText: String {
        attachments.filter(\.isSearchable).map { "\($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Everything kept beside the words that search should find: the attached files, the user's timed
    /// notes, and the words read off their pictures.
    public var searchText: String {
        let kept = notes.map { [$0.text, $0.window ?? "", $0.seen ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") }.filter { !$0.isEmpty }
        return ([attachmentText] + kept).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The typed notes as plain lines with their times, for copying and exporting.
    public var notesText: String {
        notes.sorted { $0.at < $1.at }.map { "\($0.clock)  \($0.line)" }.joined(separator: "\n")
    }

    /// A short stretch from the start of each attachment, to hand to the notes model as something to
    /// check spellings against: `limit` characters in all, shared between the files.
    public func attachmentExcerpt(limit: Int = 1000) -> String? {
        let readable = attachments.filter(\.isSearchable)
        guard !readable.isEmpty, limit > 0 else { return nil }
        let each = max(200, limit / readable.count)
        var out: [String] = []
        var left = limit
        for document in readable where left > 0 {
            let piece = String(Self.squeeze(document.text).prefix(min(each, left)))
            left -= piece.count
            out.append("[\(document.name)]\n\(piece)")
        }
        return out.joined(separator: "\n")
    }

    /// What was on screen at one moment of the recording, read as text.
    public struct Screen: Codable, Sendable, Equatable {
        /// Seconds after the recording began.
        public var at: Double
        public var app: String
        public var window: String
        public var text: String
        /// File name of the picture inside the audio folder, when it was kept.
        public var image: String?

        public init(at: Double, app: String, window: String = "", text: String, image: String? = nil) {
            self.at = at
            self.app = app
            self.window = window
            self.text = text
            self.image = image
        }
    }

    public var eventTitle: String?
    /// The other people invited, by name (or by address when the calendar has no name).
    public var attendees: [String]
    /// The event's description, as written in the calendar.
    public var eventDetails: String?
    public var location: String?
    /// Links found in the event.
    public var links: [String]
    /// The app the call ran in, by name ("Zoom").
    public var app: String?
    public var attachments: [Attachment]
    public var screens: [Screen]
    /// The notes template this recording's notes were written with, by name. (Templates are gone; kept so
    /// recordings saved with one still open.)
    public var template: String?
    /// What the user kept during the recording, each with its time: typed lines and pictures of the front window.
    public var notes: [TimedNote] = []
    /// What the user chose to record. Nil for recordings saved before the choice existed.
    public var kind: RecordingKind?

    public init(
        eventTitle: String? = nil, attendees: [String] = [], eventDetails: String? = nil, location: String? = nil,
        links: [String] = [], app: String? = nil, attachments: [Attachment] = [], screens: [Screen] = []
    ) {
        self.eventTitle = eventTitle
        self.attendees = attendees
        self.eventDetails = eventDetails
        self.location = location
        self.links = links
        self.app = app
        self.attachments = attachments
        self.screens = screens
    }

    // Recordings saved before a field existed decode with it empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventTitle = try c.decodeIfPresent(String.self, forKey: .eventTitle)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        eventDetails = try c.decodeIfPresent(String.self, forKey: .eventDetails)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        app = try c.decodeIfPresent(String.self, forKey: .app)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        screens = try c.decodeIfPresent([Screen].self, forKey: .screens) ?? []
        template = try c.decodeIfPresent(String.self, forKey: .template)
        notes = try c.decodeIfPresent([TimedNote].self, forKey: .notes) ?? []
        kind = try c.decodeIfPresent(RecordingKind.self, forKey: .kind)
    }

    /// What a recording knows when it starts: the calendar event it belongs to, if any, and the app the call is in.
    public init(event: CalendarMeeting?, app: String?) {
        self.init(
            eventTitle: event?.title, attendees: event?.attendees ?? [],
            eventDetails: event.flatMap { $0.details.isEmpty ? nil : $0.details },
            location: event.flatMap { $0.location.isEmpty ? nil : $0.location }, links: event?.links ?? [], app: app)
    }

    /// The context without anything taken from the calendar: for a recording that turned out to be one
    /// person's voice note, which no calendar event is about.
    public var withoutEvent: RecordingContext {
        var copy = self
        copy.eventTitle = nil
        copy.attendees = []
        copy.eventDetails = nil
        copy.location = nil
        copy.links = []
        return copy
    }

    /// True when nothing at all is known.
    public var isEmpty: Bool { self == RecordingContext() }

    /// The context as it is saved with an item; an empty string when nothing is known.
    public var json: String {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a saved context back. Text that is not a context gives an empty one.
    public init(json: String) {
        self = (try? JSONDecoder().decode(RecordingContext.self, from: Data(json.utf8))) ?? RecordingContext()
    }

    /// The names in what the recording was given: the people invited, and capitalised names in the calendar
    /// description, documents and screens. These go to the notes model as spellings to get right, and
    /// nothing more: a small model given the documents themselves reports them as things that were said.
    public func names(limit: Int = 30, fromAttachments: Bool = true) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ name: String) {
            let key = name.lowercased()
            guard found.count < limit, name.count >= 3, seen.insert(key).inserted else { return }
            found.append(name)
        }
        attendees.filter { !$0.contains("@") }.forEach(add)
        let texts = [eventTitle, eventDetails].compactMap { $0 } + (fromAttachments ? attachments.map(\.text) : []) + screens.map(\.text)
        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) {
                // Words with their punctuation stripped, and whether each opens a sentence.
                var run: [String] = []
                var runStartsSentence = false
                var startsSentence = true
                func flush() {
                    defer { run = [] }
                    guard !run.isEmpty else { return }
                    // One capitalised word at the start of a sentence is probably just a sentence starting.
                    if run.count == 1, runStartsSentence { return }
                    add((run.count > 3 ? Array(run.prefix(3)) : run).joined(separator: " "))
                }
                for raw in line.split(whereSeparator: \.isWhitespace) {
                    let word = raw.trimmingCharacters(in: CharacterSet.letters.inverted)
                    let named = word.count >= 2 && word.first!.isUppercase && word.dropFirst().contains(where: \.isLowercase)
                        && !Self.ordinary.contains(word.lowercased())
                    if named {
                        if run.isEmpty { runStartsSentence = startsSentence }
                        run.append(word)
                    } else {
                        flush()
                    }
                    if let last = raw.last, ".;!?•-–—".contains(last) || word.isEmpty {
                        flush()
                        startsSentence = true
                    } else {
                        // After a colon comes a value ("Codename: Kingfisher"), not a new sentence.
                        if raw.last == ":" { flush() }
                        startsSentence = false
                    }
                }
                flush()
            }
        }
        return found
    }

    /// Capitalised words that are not names.
    private static let ordinary: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "with", "to", "in", "on", "at", "by", "from", "this", "that", "these", "those",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november", "december", "agenda", "notes", "summary", "action", "items",
        "meeting", "review", "plan", "update", "updates", "budget", "owner", "next", "steps", "decide", "confirm", "discuss",
        "file", "edit", "view", "window", "help", "please", "thanks", "hello", "hi", "we", "i", "you", "it", "our", "your", "my",
    ]

    /// How much of an attachment is kept with a recording.
    public static let attachmentCharacters = 4000

    /// The block given to the language model ahead of the notes and transcript; nil when there is nothing to say.
    /// It is kept small: the model is small, and the transcript is what matters.
    public func material(detailLimit: Int = 1200, documentLimit: Int = 900, screenLimit: Int = 400) -> String? {
        var blocks: [String] = []
        var lines: [String] = []
        if let eventTitle, !eventTitle.isEmpty { lines.append("Title: \(eventTitle)") }
        if !attendees.isEmpty { lines.append("Invited: \(attendees.prefix(20).joined(separator: ", "))") }
        if let app, !app.isEmpty { lines.append("Held in: \(app)") }
        if let location, !location.isEmpty, !location.lowercased().hasPrefix("http") { lines.append("Place: \(location)") }
        if let eventDetails {
            let text = eventDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append("Description: \(text.prefix(detailLimit))") }
        }
        if !lines.isEmpty {
            blocks.append("ABOUT THIS MEETING (from the calendar, not something that was said):\n" + lines.joined(separator: "\n"))
        }
        let documents = attachments.prefix(3).filter { !$0.text.isEmpty }
        if !documents.isEmpty {
            blocks.append(
                "DOCUMENTS GIVEN WITH THIS RECORDING (for names, numbers and terms; not something that was said):\n"
                    + documents.map { "[\($0.name)]\n\(Self.squeeze($0.text).prefix(documentLimit))" }.joined(separator: "\n"))
        }
        // The screens that held the most to read, in the order they were seen.
        let seen = screens.filter { !$0.text.isEmpty }
        let kept = Set(seen.sorted { $0.text.count > $1.text.count }.prefix(4).map(\.at))
        let shown = seen.filter { kept.contains($0.at) }
        if !shown.isEmpty {
            blocks.append(
                "ON SCREEN DURING THE RECORDING (what was being looked at; not something that was said):\n"
                    + shown.map { "[\($0.at.clock) \([$0.app, $0.window].filter { !$0.isEmpty }.joined(separator: ", "))]\n\(Self.squeeze($0.text).prefix(screenLimit))" }
                    .joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// The text on one line, with single spaces.
    private static func squeeze(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether a screen says something the last kept one did not: most of its words are new, and there are enough of them.
    public static func isNewScreen(_ text: String, after last: String?, minimumWords: Int = 12) -> Bool {
        func wordSet(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let words = wordSet(text)
        guard words.count >= minimumWords else { return false }
        guard let last else { return true }
        let before = wordSet(last)
        let shared = Double(words.intersection(before).count)
        return shared / Double(max(1, min(words.count, before.count))) < 0.6
    }
}
