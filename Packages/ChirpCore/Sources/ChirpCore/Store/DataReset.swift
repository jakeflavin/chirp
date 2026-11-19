import Foundation
import GRDB

/// The two buttons of Settings › General › Danger zone.
///
/// **Delete my library** removes every recording, note, dictation and document with their audio and
/// attached files, and the folders. The Dictionary, Snippets, Writing style, templates and settings stay.
///
/// **Reset Chirp completely** removes that and everything else Chirp keeps, so the next launch is a
/// fresh install: the whole database, and the downloaded models and the link tool.
///
/// Nothing here stops work in progress or quits the app: the app does that first. Everything is
/// worked out from the folders it is given, so a test copy only ever touches its own.
public enum DataReset {
    /// What the library holds, for the confirmation to say plainly what will go.
    public struct Counts: Sendable, Equatable {
        public var meetings = 0
        public var notes = 0
        public var dictations = 0
        public var documents = 0
        public var folders = 0

        public init(meetings: Int = 0, notes: Int = 0, dictations: Int = 0, documents: Int = 0, folders: Int = 0) {
            self.meetings = meetings
            self.notes = notes
            self.dictations = dictations
            self.documents = documents
            self.folders = folders
        }

        public var isEmpty: Bool { meetings + notes + dictations + documents + folders == 0 }

        /// One line a kind, leaving out what there is none of: "6 meetings and 3 notes, with their audio
        /// and attached files", "48 dictations", "7 documents", "3 folders".
        public var lines: [String] {
            func counted(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
            var out: [String] = []
            let recordings = [meetings > 0 ? counted(meetings, "meeting", "meetings") : nil, notes > 0 ? counted(notes, "note", "notes") : nil]
                .compactMap { $0 }
            if !recordings.isEmpty { out.append(recordings.joined(separator: " and ") + ", with their audio and attached files") }
            if dictations > 0 { out.append(counted(dictations, "dictation", "dictations")) }
            if documents > 0 { out.append(counted(documents, "document", "documents")) }
            if folders > 0 { out.append(counted(folders, "folder", "folders")) }
            return out
        }
    }

    public static func counts(_ library: Library) throws -> Counts {
        var c = Counts()
        c.meetings = try library.count(kind: .meeting)
        c.notes = try library.count(kind: .voiceNote)
        c.dictations = try library.count(kind: .dictation)
        // A draft kept from the old "Check a draft" page is listed with the documents.
        c.documents = try library.count(kind: .document) + library.count(kind: .note)
        c.folders = try library.folders().count
        return c
    }

    /// The word that has to be typed before either button does anything.
    public static func confirms(_ typed: String, word: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == word
    }

    /// Deletes every saved item (with its transcript, search passages and anything else kept by item)
    /// and every folder. The Dictionary, Snippets, Writing style, templates and settings are not touched.
    public static func deleteLibrary(_ store: ChirpStore) throws {
        try store.db.write { db in
            // One by one through the record type, so the search tables that mirror the items follow.
            try SavedItem.deleteAll(db)
            try Folder.deleteAll(db)
        }
        // Give the space back to the disk.
        try? store.db.vacuum()
    }

    /// The folders beside the database that hold the library's files: audio, documents' files, attached files and screen
    /// pictures, and the sound of recordings that were never saved.
    public static func libraryFolders(dataDirectory: URL, audioDirectory: URL) -> [URL] {
        // The documents' folder is worked out from the audio folder given here, never from the app's own.
        [audioDirectory, ChirpStore.documentsDirectory(beside: audioDirectory)] + ["Attachments", "Recording in progress", "Recordings to finish", "Recording audio not saved"]
            .map { dataDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    /// The copies of the database made during development ("chirp-before-….sqlite", with their side files).
    public static func backups(in dataDirectory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("chirp-before-") && $0.contains(".sqlite") }.sorted()
            .map { dataDirectory.appendingPathComponent($0) }
    }

    /// Removes the library's files. The audio folder is left in place, empty, because the app writes to it.
    /// Returns what could not be removed.
    @discardableResult
    public static func removeLibraryFiles(dataDirectory: URL, audioDirectory: URL) -> [URL] {
        let fm = FileManager.default
        var failed: [URL] = []
        for url in libraryFolders(dataDirectory: dataDirectory, audioDirectory: audioDirectory) + backups(in: dataDirectory)
        where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { failed.append(url) }
        }
        try? fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        return failed
    }

    /// Everything in the database goes: the library, the Dictionary, Snippets, Writing style, templates
    /// and every setting kept there. The next launch builds it again, empty, and shows onboarding.
    public static func eraseEverything(_ store: ChirpStore) throws {
        try store.db.erase()
    }

    /// Removes downloaded models and tools: each folder or file given, if it is there. Returns how many
    /// bytes were freed and what could not be removed.
    @discardableResult
    public static func remove(_ places: [URL]) -> (bytes: Int64, failed: [URL]) {
        let fm = FileManager.default
        var bytes: Int64 = 0
        var failed: [URL] = []
        for url in places where fm.fileExists(atPath: url.path) {
            let size = Self.size(of: url)
            do {
                try fm.removeItem(at: url)
                bytes += size
            } catch { failed.append(url) }
        }
        return (bytes, failed)
    }

    /// How much disk a file or a folder takes.
    public static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue else { return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    /// A size in words: "2.3 GB", "410 MB".
    public static func sizeWords(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }
}
