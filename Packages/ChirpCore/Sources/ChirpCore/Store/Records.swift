import Foundation
import GRDB

/// Where a piece of personal data came from. Learned items can always be inspected and deleted.
public enum Origin: String, Codable, Sendable, CaseIterable {
    case manual
    case learned
}

// MARK: - Personal Language Engine records

/// A word or phrase Chirp should always spell the user's way.
public struct DictionaryEntry: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictionaryEntry"
    public var id: Int64?
    /// The correct spelling, e.g. "Kubernetes" or "Anaïs".
    public var term: String
    /// Things speech recognition tends to write instead, e.g. ["cooper netties"].
    public var soundsLike: [String]
    /// How the voice should say it when reading aloud, if different from the spelling.
    public var pronunciation: String?
    public var origin: Origin
    /// For learned entries: a short human-readable note on where it came from.
    public var originNote: String?
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: Int64? = nil, term: String, soundsLike: [String] = [], pronunciation: String? = nil,
        origin: Origin = .manual, originNote: String? = nil, enabled: Bool = true, createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
        self.pronunciation = pronunciation
        self.origin = origin
        self.originNote = originNote
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A spoken cue that expands to saved text.
public struct Snippet: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snippet"
    public var id: Int64?
    public var cue: String
    public var text: String
    public var enabled: Bool
    public var createdAt: Date

    public init(id: Int64? = nil, cue: String, text: String, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.cue = cue
        self.text = text
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// How formal the user wants text to read.
public enum Formality: String, Codable, Sendable, CaseIterable {
    case casual
    case neutral
    case formal
}

/// A style the user (or Chirp, by learning) attached to one app.
public struct AppStyle: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "appStyle"
    public var id: Int64?
    public var bundleID: String
    public var appName: String
    public var formality: Formality
    /// Whether live underlines are shown in this app.
    public var underlinesEnabled: Bool
    public var origin: Origin
    public var updatedAt: Date

    public init(
        id: Int64? = nil, bundleID: String, appName: String, formality: Formality = .neutral,
        underlinesEnabled: Bool = true, origin: Origin = .manual, updatedAt: Date = Date()
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.formality = formality
        self.underlinesEnabled = underlinesEnabled
        self.origin = origin
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A grammar suggestion the user dismissed, so it is not shown again.
public struct DismissedRule: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dismissedRule"
    public var id: Int64?
    /// The checker's rule identifier, e.g. "SentenceCapitalization".
    public var ruleKey: String
    /// When set, only this exact text is exempt; when nil the whole rule is off.
    public var text: String?
    public var createdAt: Date

    public init(id: Int64? = nil, ruleKey: String, text: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.ruleKey = ruleKey
        self.text = text
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One key/value of the writing profile or preferences.
struct SettingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"
    var key: String
    var value: String
    var origin: Origin
    var updatedAt: Date
}

// MARK: - Library records

/// What a saved item is. Stored by name, so a case is never renamed.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case dictation
    case voiceNote
    case meeting
    case document
    case note
}

/// Anything saved in the library: a dictation, a meeting, a note, a document to read.
public struct SavedItem: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "item"
    public var id: Int64?
    public var kind: ItemKind
    public var title: String
    /// Main text: the dictated text, the document text, or the meeting's enhanced notes.
    public var body: String
    /// The user's own raw notes (meetings) or the raw, uncleaned transcript (dictation).
    public var rawText: String
    /// Meeting summary in Markdown, when one has been made.
    public var summary: String
    public var folderID: Int64?
    /// File name inside the audio folder, when audio was kept.
    public var audioFile: String?
    /// Length of the recording in seconds; zero when there is none.
    public var duration: Double
    /// The app the text was dictated into, or the app the call ran in.
    public var appBundleID: String?
    /// Where a document came from (file path or URL). For a meeting: the names of the people invited,
    /// from the calendar, separated by commas.
    public var source: String?
    /// Reading position as a character offset into `body`.
    public var position: Int
    public var starred: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// For a recording: what it knew about itself, as `RecordingContext` JSON. Empty otherwise.
    public var context: String

    public init(
        id: Int64? = nil, kind: ItemKind, title: String = "", body: String = "", rawText: String = "",
        summary: String = "", folderID: Int64? = nil, audioFile: String? = nil, duration: Double = 0,
        appBundleID: String? = nil, source: String? = nil, position: Int = 0, starred: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(), context: String = ""
    ) {
        self.context = context
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.rawText = rawText
        self.summary = summary
        self.folderID = folderID
        self.audioFile = audioFile
        self.duration = duration
        self.appBundleID = appBundleID
        self.source = source
        self.position = position
        self.starred = starred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One spoken stretch of a meeting or voice note.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcriptSegment"
    public var id: Int64?
    public var itemID: Int64
    /// Speaker label, e.g. "Me", "Speaker 2", or a name the user gave.
    public var speaker: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int64? = nil, itemID: Int64, speaker: String, start: Double, end: Double, text: String) {
        self.id = id
        self.itemID = itemID
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A named place the user files items in.
public struct Folder: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"
    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// What a document keeps beside its text: how the text is laid out (headings, lists, images), the
/// original file or the saved copy of the page, and where it came from. A document without one is plain text.
public struct DocumentExtra: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "itemDocument"
    public var itemID: Int64
    /// `DocLayout` as JSON; empty when the document is plain text.
    public var layout: String
    /// The folder, inside `ChirpStore.documentsDirectory`, that holds this document's files.
    public var files: String?
    /// The original's file name in that folder: the PDF or Word file, or the saved copy of a web page.
    public var original: String?
    /// The site's own name for a saved page ("Long Run Journal"); empty when not known.
    public var site: String
    /// What it is, as the list says it: "PDF", "EPUB", "Word", "Web page", "YouTube", "Podcast", "Audio", "Text".
    public var format: String
    /// Pages, for a file that has them; zero otherwise.
    public var pages: Int
    /// True when its summary panel was left folded to one line.
    public var summaryCollapsed: Bool

    public init(
        itemID: Int64, layout: String = "", files: String? = nil, original: String? = nil, site: String = "",
        format: String = "", pages: Int = 0, summaryCollapsed: Bool = false
    ) {
        self.itemID = itemID
        self.layout = layout
        self.files = files
        self.original = original
        self.site = site
        self.format = format
        self.pages = pages
        self.summaryCollapsed = summaryCollapsed
    }

    /// The folder holding this document's files, when it has one.
    public var folderURL: URL? { files.map { ChirpStore.documentsDirectory.appendingPathComponent($0, isDirectory: true) } }
    /// The original file, when one was kept.
    public var originalURL: URL? { original.flatMap { name in folderURL?.appendingPathComponent(name) } }
    /// True for sound that was transcribed: a link, a podcast or an audio file.
    public var isTranscript: Bool { ["YouTube", "Podcast", "Audio", "Video"].contains(format) }
}

/// A meeting-notes template: a name and the instructions that shape the summary.
public struct NoteTemplate: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "noteTemplate"
    public var id: Int64?
    public var name: String
    /// Section headings the notes should use, one per line.
    public var sections: String
    public var builtIn: Bool

    public init(id: Int64? = nil, name: String, sections: String, builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.sections = sections
        self.builtIn = builtIn
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A passage of an item with its embedding, for semantic search.
public struct Chunk: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chunk"
    public var id: Int64?
    public var itemID: Int64
    /// Character offset of the passage in the item's searchable text.
    public var offset: Int
    public var text: String
    /// Float32 vector, little-endian. Empty until embedded.
    public var embedding: Data

    public init(id: Int64? = nil, itemID: Int64, offset: Int, text: String, embedding: Data = Data()) {
        self.id = id
        self.itemID = itemID
        self.offset = offset
        self.text = text
        self.embedding = embedding
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A note's Markdown and what the Notes list says about it. Every note is an item of kind
/// `voiceNote`, typed or spoken; `body` holds the same words without marks.
public struct NoteExtra: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "itemNote"
    public var itemID: Int64
    /// The note as typed: Markdown.
    public var markdown: String
    /// Something was typed into it, and something was dictated into it (for "typed and dictated").
    public var typed: Bool
    public var dictated: Bool
    /// When it was last changed by hand; nil for a voice note never edited.
    public var editedAt: Date?
    /// When it was last exported or shared, for "exported 15 Nov" in the list.
    public var exportedAt: Date?

    public init(itemID: Int64, markdown: String, typed: Bool = false, dictated: Bool = false, editedAt: Date? = nil, exportedAt: Date? = nil) {
        self.itemID = itemID
        self.markdown = markdown
        self.typed = typed
        self.dictated = dictated
        self.editedAt = editedAt
        self.exportedAt = exportedAt
    }
}
