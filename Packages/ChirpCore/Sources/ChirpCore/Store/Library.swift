import Foundation
import GRDB

/// Everything saved: dictations, voice notes, meetings, documents and notes, with search.
public final class Library: Sendable {
    public let store: ChirpStore

    public init(store: ChirpStore) {
        self.store = store
    }

    // MARK: Items

    /// Saves a new item or the changes to one, and returns it as saved (with its id). An item without a
    /// title is named from its first words.
    @discardableResult
    public func save(_ item: SavedItem) throws -> SavedItem {
        var i = item
        i.updatedAt = Date()
        if i.title.isEmpty { i.title = Self.title(from: i.body.isEmpty ? i.rawText : i.body) }
        try store.db.write { db in
            // When the text changes, drop its passages so search by meaning re-reads it.
            if let id = i.id, let old = try SavedItem.fetchOne(db, key: id),
                old.body != i.body || old.summary != i.summary || old.rawText != i.rawText
            {
                try Chunk.filter(Column("itemID") == id).deleteAll(db)
            }
            try i.save(db)
        }
        return i
    }

    /// The item with this id, if it still exists.
    public func item(_ id: Int64) throws -> SavedItem? {
        try store.db.read { db in try SavedItem.fetchOne(db, key: id) }
    }

    /// Remembers how far a document has been read, and changes nothing else about it. (Saving the whole
    /// item from a copy held while reading would put back a title or summary changed elsewhere meanwhile.)
    public func setPosition(id: Int64, position: Int) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE item SET position = ? WHERE id = ?", arguments: [position, id]) }
    }

    /// Items newest first, optionally only of some kinds or in one folder.
    public func items(kinds: [ItemKind]? = nil, folderID: Int64? = nil, limit: Int = 500) throws -> [SavedItem] {
        try store.db.read { db in
            var q = SavedItem.order(Column("createdAt").desc).limit(limit)
            if let kinds { q = q.filter(kinds.map(\.rawValue).contains(Column("kind"))) }
            if let folderID { q = q.filter(Column("folderID") == folderID) }
            return try q.fetchAll(db)
        }
    }

    /// Deletes an item, its transcript, its audio file and, for a document, the files kept with it.
    public func delete(_ item: SavedItem) throws {
        let extra = item.id.flatMap { try? documentExtra(itemID: $0) }
        _ = try store.db.write { db in try item.delete(db) }
        if let folder = extra?.folderURL { try? FileManager.default.removeItem(at: folder) }
        if let file = item.audioFile {
            try? FileManager.default.removeItem(at: ChirpStore.audioDirectory.appendingPathComponent(file))
        }
    }

    /// How many items of one kind are saved.
    public func count(kind: ItemKind) throws -> Int {
        try store.db.read { db in try SavedItem.filter(Column("kind") == kind.rawValue).fetchCount(db) }
    }

    /// Keeps only the newest `keep` dictations (starred ones are always kept).
    public func trimDictations(keep: Int) throws {
        let old = try store.db.read { db in
            try SavedItem.filter(Column("kind") == ItemKind.dictation.rawValue && Column("starred") == false)
                .order(Column("createdAt").desc).limit(-1, offset: keep).fetchAll(db)
        }
        for item in old { try delete(item) }
    }

    /// A short title from the first words of the text.
    /// An email's subject when the text starts with its header lines; otherwise the first line that is not an
    /// ad or a newsletter's header ("Sign Up | Advertise | View Online").
    public static func title(from text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var firstLine = lines.first { !Boilerplate.isTitleNoise($0) } ?? lines.first ?? ""
        if let subject = lines.prefix(12).first(where: { $0.lowercased().hasPrefix("subject:") }) {
            var s = String(subject.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
            while let reply = s.range(of: #"^(re|fwd?|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(reply) }
            if !s.isEmpty { firstLine = s }
        }
        let words = firstLine.split(separator: " ").prefix(8).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?#-* "))
        return trimmed.isEmpty ? "Untitled" : (trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed)
    }

    /// Pins an item or takes the pin off, and changes nothing else about it.
    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE item SET starred = ? WHERE id = ?", arguments: [pinned, id]) }
    }

    /// Puts an item in a folder, or in none, and changes nothing else about it.
    public func setFolder(id: Int64, _ folderID: Int64?) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE item SET folderID = ? WHERE id = ?", arguments: [folderID, id]) }
    }

    /// Changes when an item says it was made, and nothing else about it (for demos and pictures of the dated groups).
    public func setCreated(id: Int64, _ date: Date) throws {
        try store.db.write { db in try db.execute(sql: "UPDATE item SET createdAt = ? WHERE id = ?", arguments: [date, id]) }
    }

    /// The pinned items of these kinds, newest first.
    public func pinned(kinds: [ItemKind], limit: Int = 50) throws -> [SavedItem] {
        try store.db.read { db in
            try SavedItem.filter(Column("starred") == true && kinds.map(\.rawValue).contains(Column("kind")))
                .order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    // MARK: Notes

    /// A note's Markdown and facts. A voice note saved without a row of its own is its plain words.
    public func note(itemID: Int64) throws -> NoteExtra? {
        try store.db.read { db in
            if let extra = try NoteExtra.fetchOne(db, key: itemID) { return extra }
            guard let item = try SavedItem.fetchOne(db, key: itemID), item.kind == .voiceNote else { return nil }
            return NoteExtra(itemID: itemID, markdown: NoteMarkdown.fromPlainText(item.body))
        }
    }

    /// The facts of every note, by item id, for the list's rows.
    public func noteFacts() throws -> [Int64: NoteExtra] {
        try store.db.read { db in
            let rows = try NoteExtra.fetchAll(db, sql: "SELECT itemID, '' AS markdown, typed, dictated, editedAt, exportedAt FROM itemNote")
            return Dictionary(rows.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Saves a note's Markdown: a new note when `id` is nil. Its title is its first line, and its body the
    /// same words without marks. A voice note never edited keeps the title it was given until its words
    /// change. `typed` and `dictated` say how this change was made; they add to what is known.
    @discardableResult
    public func saveNote(id: Int64?, markdown: String, typed: Bool = false, dictated: Bool = false, now: Date = Date()) throws -> SavedItem {
        var item = try id.flatMap { try self.item($0) } ?? SavedItem(kind: .voiceNote, createdAt: now)
        let old = try id.flatMap { try note(itemID: $0) }
        let changed = old?.markdown != markdown
        item.body = NoteMarkdown.plain(markdown)
        if changed || item.title.isEmpty {
            item.title = NoteMarkdown.title(markdown) ?? "Note"
        }
        item = try save(item)
        guard let itemID = item.id else { return item }
        var extra = old ?? NoteExtra(itemID: itemID, markdown: markdown)
        extra.itemID = itemID
        extra.markdown = markdown
        extra.typed = extra.typed || typed
        extra.dictated = extra.dictated || dictated
        if changed { extra.editedAt = now }
        try store.db.write { db in try extra.save(db) }
        return item
    }

    /// Remembers that a note was exported or shared. Nothing else about it changes.
    public func setNoteExported(itemID: Int64, at date: Date = Date()) throws {
        try store.db.write { db in
            if try NoteExtra.fetchOne(db, key: itemID) != nil {
                try db.execute(sql: "UPDATE itemNote SET exportedAt = ? WHERE itemID = ?", arguments: [date, itemID])
            } else if let item = try SavedItem.fetchOne(db, key: itemID), item.kind == .voiceNote {
                try NoteExtra(itemID: itemID, markdown: item.body, exportedAt: date).insert(db)
            }
        }
    }

    /// Removes notes that have no words (a note opened and left empty is not kept), except `keeping`.
    @discardableResult
    public func deleteEmptyNotes(keeping: Int64? = nil) throws -> Int {
        let empty = try store.db.read { db in
            try SavedItem.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN itemNote ON itemNote.itemID = item.id
                WHERE item.kind = 'voiceNote' AND item.audioFile IS NULL AND trim(itemNote.markdown) = ''
                """)
        }
        var gone = 0
        for item in empty where item.id != keeping {
            try delete(item)
            gone += 1
        }
        return gone
    }

    // MARK: Documents

    /// What a document keeps beside its text, if anything.
    public func documentExtra(itemID: Int64) throws -> DocumentExtra? {
        try store.db.read { db in try DocumentExtra.fetchOne(db, key: itemID) }
    }

    /// Saves what a document keeps beside its text.
    public func save(_ extra: DocumentExtra) throws {
        try store.db.write { db in try extra.save(db) }
    }

    /// What each document is (format, pages, site, files), by item id, without the layouts: for list rows.
    public func documentFacts() throws -> [Int64: DocumentExtra] {
        try store.db.read { db in
            let rows = try DocumentExtra.fetchAll(
                db, sql: "SELECT itemID, '' AS layout, files, original, site, format, pages, summaryCollapsed FROM itemDocument")
            return Dictionary(rows.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Remembers whether a document's summary panel is folded to one line.
    public func setSummaryCollapsed(itemID: Int64, _ collapsed: Bool) throws {
        try store.db.write { db in
            if try DocumentExtra.fetchOne(db, key: itemID) != nil {
                try db.execute(sql: "UPDATE itemDocument SET summaryCollapsed = ? WHERE itemID = ?", arguments: [collapsed, itemID])
            } else {
                try DocumentExtra(itemID: itemID, summaryCollapsed: collapsed).insert(db)
            }
        }
    }

    /// How many speakers an item's transcript has.
    public func speakerCount(itemID: Int64) throws -> Int {
        try store.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT speaker) FROM transcriptSegment WHERE itemID = ?", arguments: [itemID]) ?? 0
        }
    }

    // MARK: Transcript segments

    /// An item's transcript, in the order it was said.
    public func segments(itemID: Int64) throws -> [TranscriptSegment] {
        try store.db.read { db in
            try TranscriptSegment.filter(Column("itemID") == itemID).order(Column("start")).fetchAll(db)
        }
    }

    /// Swaps an item's whole transcript for a new one, in one step.
    public func replaceSegments(itemID: Int64, with segments: [TranscriptSegment]) throws {
        try store.db.write { db in
            try TranscriptSegment.filter(Column("itemID") == itemID).deleteAll(db)
            for var s in segments {
                s.id = nil
                s.itemID = itemID
                try s.insert(db)
            }
            // The same words as one text, for keyword search.
            try db.execute(sql: "DELETE FROM itemTranscript WHERE itemID = ?", arguments: [itemID])
            let text = segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: "\n")
            if !text.isEmpty { try db.execute(sql: "INSERT INTO itemTranscript (itemID, text) VALUES (?, ?)", arguments: [itemID, text]) }
        }
    }

    /// Keeps the text of an item's attached files for keyword search; empty text takes it out.
    public func setAttachmentText(itemID: Int64, text: String) throws {
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM itemAttachment WHERE itemID = ?", arguments: [itemID])
            if !text.isEmpty { try db.execute(sql: "INSERT INTO itemAttachment (itemID, text) VALUES (?, ?)", arguments: [itemID, text]) }
        }
    }

    /// Gives every line of one speaker in an item a new name ("Speaker 2" becomes "Priya").
    public func renameSpeaker(itemID: Int64, from old: String, to new: String) throws {
        _ = try store.db.write { db in
            try TranscriptSegment.filter(Column("itemID") == itemID && Column("speaker") == old)
                .updateAll(db, Column("speaker").set(to: new))
        }
    }

    // MARK: Folders and templates

    /// The folders, by name.
    public func folders() throws -> [Folder] {
        try store.db.read { db in try Folder.order(Column("name")).fetchAll(db) }
    }

    @discardableResult
    public func addFolder(_ name: String) throws -> Folder {
        var f = Folder(name: name)
        try store.db.write { db in try f.insert(db) }
        return f
    }

    /// Gives a folder a new name. An empty name changes nothing.
    public func rename(_ folder: Folder, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let id = folder.id else { return }
        try store.db.write { db in try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    /// How many items each folder holds, by folder id. `kinds` leaves out what is not shown.
    public func folderCounts(kinds: [ItemKind]? = nil) throws -> [Int64: Int] {
        try store.db.read { db in
            var sql = "SELECT folderID, COUNT(*) FROM item WHERE folderID IS NOT NULL"
            var args: [DatabaseValueConvertible] = []
            if let kinds {
                guard !kinds.isEmpty else { return [:] }
                sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
                args += kinds.map(\.rawValue)
            }
            sql += " GROUP BY folderID"
            var out: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) { out[row[0]] = row[1] }
            return out
        }
    }

    /// Deletes a folder. The items in it are kept and no longer belong to any folder.
    public func delete(_ folder: Folder) throws {
        _ = try store.db.write { db in try folder.delete(db) }
    }

    /// The notes templates: the built-in ones first, then the user's in the order they were made.
    public func templates() throws -> [NoteTemplate] {
        try store.db.read { db in try NoteTemplate.order(Column("builtIn").desc, Column("id")).fetchAll(db) }
    }

    @discardableResult
    public func save(_ template: NoteTemplate) throws -> NoteTemplate {
        var t = template
        try store.db.write { db in try t.save(db) }
        return t
    }

    public func delete(_ template: NoteTemplate) throws {
        _ = try store.db.write { db in try template.delete(db) }
    }

    // MARK: Search

    /// One item a keyword search found.
    public struct Hit: Sendable, Identifiable, Equatable {
        public var item: SavedItem
        /// A short excerpt around the match, with matched words wrapped in «…».
        public var snippet: String
        /// How well it matched; higher is better.
        public var score: Double
        public var id: Int64 { item.id ?? 0 }
    }

    /// Keyword search over titles, text, raw notes, summaries and what was said in a recording. Words are
    /// matched by stem and prefix. An item found by its title, notes or summary comes with that excerpt;
    /// one found only by its transcript comes with the words said.
    public func search(_ query: String, kinds: [ItemKind]? = nil, limit: Int = 50) throws -> [Hit] {
        guard let pattern = Self.ftsPattern(query) else { return [] }
        let hits = try searchItems(pattern, kinds: kinds, limit: limit)
        var found = Set(hits.map(\.id))
        // What was said, weighted as an item's own text is (0.6 in `searchItems`), under its title and summary.
        let said = try searchBeside("transcriptFTS", weight: 0.6, pattern, kinds: kinds, limit: limit).filter { !found.contains($0.id) }
        found.formUnion(said.map(\.id))
        // Then the files attached to a recording: they are about it, not what it said.
        let attached = try searchBeside("attachmentFTS", weight: 0.3, pattern, kinds: kinds, limit: limit).filter { !found.contains($0.id) }
        // In that order: each list is already best first.
        return Array((hits + said + attached).prefix(limit))
    }

    /// Items found through a text kept beside them: their transcript, or the text of their attached files.
    private func searchBeside(_ table: String, weight: Double, _ pattern: String, kinds: [ItemKind]?, limit: Int) throws -> [Hit] {
        try store.db.read { db in
            var sql = """
                SELECT item.*, snippet(\(table), 0, '«', '»', '…', 14) AS snip, bm25(\(table)) AS rank
                FROM \(table) JOIN item ON item.id = \(table).rowid
                WHERE \(table) MATCH ?
                """
            var args: [DatabaseValueConvertible] = [pattern]
            if let kinds, !kinds.isEmpty {
                sql += " AND item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
                args += kinds.map(\.rawValue)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                Hit(item: try SavedItem(row: row), snippet: row["snip"] ?? "", score: -(row["rank"] as Double? ?? 0) * weight)
            }
        }
    }

    /// Items whose title, text, raw notes or summary hold the words.
    private func searchItems(_ pattern: String, kinds: [ItemKind]?, limit: Int) throws -> [Hit] {
        try store.db.read { db in
            var sql = """
                SELECT item.*, snippet(itemFTS, -1, '«', '»', '…', 14) AS snip, bm25(itemFTS, 4.0, 1.0, 0.6, 1.5) AS rank
                FROM itemFTS JOIN item ON item.id = itemFTS.rowid
                WHERE itemFTS MATCH ?
                """
            var args: [DatabaseValueConvertible] = [pattern]
            if let kinds, !kinds.isEmpty {
                sql += " AND item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
                args += kinds.map(\.rawValue)
            }
            sql += " ORDER BY rank LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                Hit(item: try SavedItem(row: row), snippet: row["snip"] ?? "", score: -(row["rank"] as Double? ?? 0))
            }
        }
    }

    /// Turns free text into a safe FTS5 query: each word quoted, last word as a prefix.
    static func ftsPattern(_ query: String) -> String? {
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in
            "\"\(w)\"" + (i == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    // MARK: Chunks for semantic search

    /// Every passage that has been embedded, across all items.
    public func chunks() throws -> [Chunk] {
        try store.db.read { db in try Chunk.filter(length(Column("embedding")) > 0).fetchAll(db) }
    }

    /// Items whose text has not been split and embedded yet.
    public func itemsNeedingChunks() throws -> [SavedItem] {
        try store.db.read { db in
            try SavedItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM item WHERE kind != 'dictation'
                    AND id NOT IN (SELECT DISTINCT itemID FROM chunk)
                    AND (length(body) + length(rawText) + length(summary) > 0
                         OR id IN (SELECT DISTINCT itemID FROM transcriptSegment))
                    """)
        }
    }

    /// How many items `itemsNeedingChunks` would return, without loading their text.
    public func countItemsNeedingChunks() throws -> Int {
        try store.db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM item WHERE kind != 'dictation'
                    AND id NOT IN (SELECT DISTINCT itemID FROM chunk)
                    AND (length(body) + length(rawText) + length(summary) > 0
                         OR id IN (SELECT DISTINCT itemID FROM transcriptSegment))
                    """) ?? 0
        }
    }

    /// Swaps an item's passages for new ones, in one step.
    public func replaceChunks(itemID: Int64, with chunks: [Chunk]) throws {
        try store.db.write { db in
            try Chunk.filter(Column("itemID") == itemID).deleteAll(db)
            for var c in chunks {
                c.id = nil
                c.itemID = itemID
                try c.insert(db)
            }
        }
    }

    /// The texts of an item that search covers, most original first: what the user wrote,
    /// what was said, then notes Chirp wrote from them.
    public static func searchableParts(_ item: SavedItem, segments: [TranscriptSegment] = []) -> [String] {
        var parts = [item.body]
        if !item.rawText.isEmpty, item.rawText != item.body { parts.append(item.rawText) }
        if !segments.isEmpty { parts.append(MeetingText.script(segments)) }
        if !item.summary.isEmpty { parts.append(item.summary) }
        return parts.filter { !$0.isEmpty }
    }

    /// The text of an item that search covers, in one string.
    public static func searchableText(_ item: SavedItem, segments: [TranscriptSegment] = []) -> String {
        searchableParts(item, segments: segments).joined(separator: "\n\n")
    }
}
