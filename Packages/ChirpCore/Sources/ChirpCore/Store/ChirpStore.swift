import Foundation
import GRDB

/// The single local database behind every Chirp feature.
public final class ChirpStore: Sendable {
    /// The database itself. One connection, so writes never overlap.
    public let db: DatabaseQueue

    /// Opens (and migrates) the database at `url`, or an in-memory one when `url` is nil.
    public init(url: URL? = nil) throws {
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: url.path)
        } else {
            db = try DatabaseQueue()
        }
        try Self.migrator.migrate(db)
        try seedTemplatesIfNeeded()
    }

    /// Opens the database as it was at an earlier step of its layout (for tests of the steps after it).
    init(url: URL, upTo step: String) throws {
        db = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(db, upTo: step)
        try seedTemplatesIfNeeded()
    }

    /// `~/Library/Application Support/Chirp`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Chirp", isDirectory: true)
    }

    /// Where the database is kept.
    public static var defaultURL: URL { supportDirectory.appendingPathComponent("chirp.sqlite") }
    /// Where recordings are kept. Test runs point this at a temporary folder.
    nonisolated(unsafe) public static var audioDirectory: URL = supportDirectory.appendingPathComponent("Audio", isDirectory: true)
    /// Where the files of documents are kept (originals, saved pages, images): beside the recordings.
    public static var documentsDirectory: URL { documentsDirectory(beside: audioDirectory) }

    /// The documents' folder that goes with an audio folder: "Documents" beside "Audio", or, for a test
    /// run's own audio folder, one named after it.
    public static func documentsDirectory(beside audioDirectory: URL) -> URL {
        audioDirectory.lastPathComponent == "Audio"
            ? audioDirectory.deletingLastPathComponent().appendingPathComponent("Documents", isDirectory: true)
            : audioDirectory.deletingLastPathComponent().appendingPathComponent(audioDirectory.lastPathComponent + "-documents", isDirectory: true)
    }
    /// Where downloaded models are kept.
    public static var modelsDirectory: URL { supportDirectory.appendingPathComponent("Models", isDirectory: true) }

    /// The changes to the database's layout, in the order they were made. A step that has shipped is
    /// never edited; a new change is a new step.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "dictionaryEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("term", .text).notNull()
                t.column("soundsLike", .jsonText).notNull()
                t.column("pronunciation", .text)
                t.column("origin", .text).notNull()
                t.column("originNote", .text)
                t.column("enabled", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("cue", .text).notNull()
                t.column("text", .text).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "appStyle") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleID", .text).notNull().unique()
                t.column("appName", .text).notNull()
                t.column("formality", .text).notNull()
                t.column("underlinesEnabled", .boolean).notNull()
                t.column("origin", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "dismissedRule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ruleKey", .text).notNull()
                t.column("text", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("rawText", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("folderID", .integer).references("folder", onDelete: .setNull)
                t.column("audioFile", .text)
                t.column("duration", .double).notNull()
                t.column("appBundleID", .text)
                t.column("source", .text)
                t.column("position", .integer).notNull()
                t.column("starred", .boolean).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "transcriptSegment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemID", .integer).notNull().indexed().references("item", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(table: "noteTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sections", .text).notNull()
                t.column("builtIn", .boolean).notNull()
            }
            try db.create(table: "chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemID", .integer).notNull().indexed().references("item", onDelete: .cascade)
                t.column("offset", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("embedding", .blob).notNull()
            }
            // Full-text index over everything searchable in an item. Kept in step by SQLite triggers.
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("body")
                t.column("rawText")
                t.column("summary")
            }
        }
        m.registerMigration("v2") { db in
            // What a recording knew about itself (calendar event, call app, attachments), as JSON.
            try db.alter(table: "item") { t in
                t.add(column: "context", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v3") { db in
            // Which to-dos from a recording's notes have been ticked off. A to-do is known by the recording
            // it came from and its own words, so it stays ticked when the notes are shown again.
            try db.create(table: "todoDone") { t in
                t.column("itemID", .integer).notNull().indexed().references("item", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("doneAt", .datetime).notNull()
                t.primaryKey(["itemID", "key"])
            }
        }
        m.registerMigration("v4") { db in
            // What was said in each recording, as one text, so a word spoken in a meeting is found by a
            // keyword search even when the notes do not mention it. Kept in step by `replaceSegments`.
            try db.create(table: "itemTranscript") { t in
                t.column("itemID", .integer).primaryKey().references("item", onDelete: .cascade)
                t.column("text", .text).notNull()
            }
            try db.execute(sql: """
                INSERT INTO itemTranscript (itemID, text)
                SELECT itemID, group_concat(text, char(10)) FROM (SELECT itemID, text FROM transcriptSegment ORDER BY itemID, start)
                GROUP BY itemID
                """)
            try db.create(virtualTable: "transcriptFTS", using: FTS5()) { t in
                t.synchronize(withTable: "itemTranscript")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
        }
        m.registerMigration("v5") { db in
            // The text of the files attached to each recording, so a word in a slide or a sheet finds the
            // recording it was attached to. Kept in step by `Library.setAttachmentText`.
            try db.create(table: "itemAttachment") { t in
                t.column("itemID", .integer).primaryKey().references("item", onDelete: .cascade)
                t.column("text", .text).notNull()
            }
            try db.create(virtualTable: "attachmentFTS", using: FTS5()) { t in
                t.synchronize(withTable: "itemAttachment")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
            // Documents given to recordings before this kept their text in the recording's own record.
            let rows = try Row.fetchAll(db, sql: "SELECT id, context FROM item WHERE context LIKE '%\"attachments\"%'")
            for row in rows {
                let text = RecordingContext(json: row["context"]).attachmentText
                if !text.isEmpty { try db.execute(sql: "INSERT INTO itemAttachment (itemID, text) VALUES (?, ?)", arguments: [row["id"] as Int64, text]) }
            }
        }
        m.registerMigration("v6") { db in
            // What a document keeps beside its text: its layout, its files and where it came from. Nothing
            // already saved is changed: a document without a row here is shown as the plain text it is.
            try db.create(table: "itemDocument") { t in
                t.column("itemID", .integer).primaryKey().references("item", onDelete: .cascade)
                t.column("layout", .text).notNull().defaults(to: "")
                t.column("files", .text)
                t.column("original", .text)
                t.column("site", .text).notNull().defaults(to: "")
                t.column("format", .text).notNull().defaults(to: "")
                t.column("pages", .integer).notNull().defaults(to: 0)
                t.column("summaryCollapsed", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v7") { db in
            // How often each spelling has been put right ("Kubernets" → "Kubernetes", 4 times), so Home
            // can suggest a word for the Dictionary. Counted from here on; nothing already saved changes.
            try db.create(table: "correction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wrong", .text).notNull()
                t.column("right", .text).notNull()
                t.column("times", .integer).notNull().defaults(to: 1)
                t.column("lastAt", .datetime).notNull()
                t.uniqueKey(["wrong", "right"])
            }
        }
        m.registerMigration("v8") { db in
            // A note's Markdown, as typed, and what the Notes list says about it. The item's own body
            // keeps the note's words without marks, so search, Home and reading aloud go on as before.
            // Every voice note saved so far becomes an editable note of its own words: its text, title and
            // audio are not changed.
            try db.create(table: "itemNote") { t in
                t.column("itemID", .integer).primaryKey().references("item", onDelete: .cascade)
                t.column("markdown", .text).notNull()
                t.column("typed", .boolean).notNull().defaults(to: false)
                t.column("dictated", .boolean).notNull().defaults(to: false)
                t.column("editedAt", .datetime)
                t.column("exportedAt", .datetime)
            }
            try db.execute(sql: "INSERT INTO itemNote (itemID, markdown) SELECT id, body FROM item WHERE kind = 'voiceNote'")
        }
        return m
    }

    /// Adds the built-in notes templates to a database that has none.
    private func seedTemplatesIfNeeded() throws {
        try db.write { db in
            guard try NoteTemplate.fetchCount(db) == 0 else { return }
            for var t in NoteTemplate.builtIns { try t.insert(db) }
        }
    }
}

extension NoteTemplate {
    /// The templates every new library starts with.
    static let builtIns: [NoteTemplate] = [
        NoteTemplate(name: "General", sections: "Summary\nKey points\nDecisions", builtIn: true),
        NoteTemplate(name: "One-on-one", sections: "Updates\nFeedback\nBlockers", builtIn: true),
        NoteTemplate(name: "Stand-up", sections: "Done\nDoing next\nBlockers", builtIn: true),
        NoteTemplate(
            name: "Customer call", sections: "Who and context\nWhat they need\nObjections and concerns",
            builtIn: true),
        NoteTemplate(
            name: "Interview", sections: "Background\nStrengths\nConcerns\nQuestions they asked",
            builtIn: true),
    ]
}
