import XCTest

@testable import ChirpCore

/// "Delete my library" and "Reset Chirp completely", against a library and folders made for the test.
final class DataResetTests: XCTestCase {
    private var folder: URL!
    private var audio: URL!
    private var was: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-reset-\(UUID().uuidString)", isDirectory: true)
        audio = folder.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        was = ChirpStore.audioDirectory
        ChirpStore.audioDirectory = audio
    }

    override func tearDown() {
        ChirpStore.audioDirectory = was
        try? FileManager.default.removeItem(at: folder)
    }

    /// A library with one of everything, and the things that are not the library.
    private func filled() throws -> (store: ChirpStore, library: Library, engine: PersonalLanguage) {
        let store = try ChirpStore(url: folder.appendingPathComponent("chirp.sqlite"))
        let library = Library(store: store)
        let engine = PersonalLanguage(store: store)
        let launch = try library.addFolder("Launch")
        var meeting = try library.save(SavedItem(kind: .meeting, title: "Launch review", summary: "## Summary\n- The beta is in March.", audioFile: "meeting.m4a"))
        meeting.folderID = launch.id
        meeting = try library.save(meeting)
        try library.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: meeting.id!, speaker: "Me", start: 0, end: 4, text: "The budget is mine.")])
        try library.replaceChunks(itemID: meeting.id!, with: [Chunk(itemID: meeting.id!, offset: 0, text: "The budget is mine.")])
        try library.save(SavedItem(kind: .voiceNote, title: "Half marathon plan", audioFile: "note.m4a"))
        try library.save(SavedItem(kind: .dictation, body: "Thanks, talk soon.", audioFile: "dictation.m4a"))
        try library.save(SavedItem(kind: .dictation, body: "On my way."))
        try library.save(SavedItem(kind: .document, title: "Pacing", body: "Start slow."))
        try library.save(SavedItem(kind: .note, body: "An old draft."))
        _ = try engine.addWord("Kubernetes")
        try engine.save(Snippet(cue: "sign off", text: "Thanks, talk soon."))
        var profile = WritingProfile()
        profile.styleNotes = "Short sentences."
        try engine.saveProfile(profile)
        try engine.setSetting("holdKey", "fn")
        for name in ["meeting.m4a", "note.m4a", "dictation.m4a"] { try Data("sound".utf8).write(to: audio.appendingPathComponent(name)) }
        for name in ["Attachments", "Recording in progress", "Recordings to finish", "Recording audio not saved", "Models", "Tools"] {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: dir.appendingPathComponent("file.bin"))
        }
        for name in ["chirp-before-notes.sqlite", "chirp-before-notes.sqlite-wal", "unrelated.sqlite"] {
            try Data("copy".utf8).write(to: folder.appendingPathComponent(name))
        }
        return (store, library, engine)
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    func testTheCountsSayWhatWillGo() throws {
        let (_, library, _) = try filled()
        let counts = try DataReset.counts(library)
        XCTAssertEqual(counts, DataReset.Counts(meetings: 1, notes: 1, dictations: 2, documents: 2, folders: 1))
        XCTAssertEqual(counts.lines, ["1 meeting and 1 note, with their audio and attached files", "2 dictations", "2 documents", "1 folder"])
        XCTAssertEqual(DataReset.Counts(meetings: 0, notes: 3, dictations: 0, documents: 0, folders: 0).lines, ["3 notes, with their audio and attached files"])
        XCTAssertTrue(DataReset.Counts().isEmpty)
        XCTAssertEqual(DataReset.Counts().lines, [])
    }

    func testTheWordMustBeTyped() {
        XCTAssertTrue(DataReset.confirms("delete", word: "delete"))
        XCTAssertTrue(DataReset.confirms(" Delete ", word: "delete"))
        XCTAssertFalse(DataReset.confirms("", word: "delete"))
        XCTAssertFalse(DataReset.confirms("delet", word: "delete"))
        XCTAssertFalse(DataReset.confirms("delete", word: "reset"))
    }

    func testDeletingTheLibraryKeepsTheLanguageAndSettings() throws {
        let (store, library, engine) = try filled()
        try DataReset.deleteLibrary(store)
        XCTAssertEqual(DataReset.removeLibraryFiles(dataDirectory: folder, audioDirectory: audio), [])

        XCTAssertTrue(try DataReset.counts(library).isEmpty)
        XCTAssertEqual(try library.items().count, 0)
        XCTAssertEqual(try library.chunks().count, 0)
        XCTAssertEqual(try library.search("budget").count, 0, "the search tables follow the items")
        try store.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptSegment"), 0)
        }
        // Kept: Dictionary, Snippets, Writing style, settings and templates.
        XCTAssertEqual(try engine.dictionary().map(\.term), ["Kubernetes"])
        XCTAssertEqual(try engine.snippets().map(\.cue), ["sign off"])
        XCTAssertEqual(try engine.profile().styleNotes, "Short sentences.")
        XCTAssertEqual(try engine.setting("holdKey", as: String.self), "fn")
        XCTAssertFalse(try library.templates().isEmpty)
        // Files: the audio folder is there and empty; the rest of the library's folders and the backups are gone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path), [])
        for gone in ["Attachments", "Recording in progress", "Recordings to finish", "Recording audio not saved", "chirp-before-notes.sqlite", "chirp-before-notes.sqlite-wal"] {
            XCTAssertFalse(exists(gone), gone)
        }
        // Not the library: the models, the link tool, and a file that only looks like a backup.
        for kept in ["Models/file.bin", "Tools/file.bin", "unrelated.sqlite", "chirp.sqlite"] { XCTAssertTrue(exists(kept), kept) }
        // The library works afterwards.
        try library.save(SavedItem(kind: .dictation, body: "Hello again."))
        XCTAssertEqual(try library.items().count, 1)
    }

    func testAResetLeavesAFreshInstall() throws {
        let (store, _, _) = try filled()
        try DataReset.deleteLibrary(store)
        DataReset.removeLibraryFiles(dataDirectory: folder, audioDirectory: audio)
        try DataReset.eraseEverything(store)
        let freed = DataReset.remove([folder.appendingPathComponent("Models"), folder.appendingPathComponent("Tools"), folder.appendingPathComponent("not there")])
        XCTAssertEqual(freed.failed, [])
        XCTAssertGreaterThan(freed.bytes, 0)
        XCTAssertFalse(exists("Models"))
        XCTAssertFalse(exists("Tools"))

        // The next launch: the same file opens as a new library, with onboarding still to do.
        let again = try ChirpStore(url: folder.appendingPathComponent("chirp.sqlite"))
        let engine = PersonalLanguage(store: again)
        XCTAssertEqual(try engine.dictionary(includeDisabled: true).count, 0)
        XCTAssertEqual(try engine.snippets(includeDisabled: true).count, 0)
        XCTAssertEqual(try engine.profile(), WritingProfile())
        XCTAssertNil(try engine.setting("holdKey", as: String.self))
        XCTAssertNil(try engine.setting("onboardingDone", as: Bool.self))
        XCTAssertEqual(try Library(store: again).items().count, 0)
        XCTAssertFalse(try Library(store: again).templates().isEmpty, "the built-in templates are there again")
    }

    func testSizesAreSaidPlainly() throws {
        XCTAssertEqual(DataReset.sizeWords(2_300_000_000), "2.3 GB")
        XCTAssertEqual(DataReset.sizeWords(410_000_000), "410 MB")
        XCTAssertEqual(DataReset.sizeWords(10), "1 MB")
        XCTAssertEqual(DataReset.size(of: folder.appendingPathComponent("nothing")), 0)
    }
}
