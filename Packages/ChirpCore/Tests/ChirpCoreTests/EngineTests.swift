import Foundation
import GRDB
import Testing

@testable import ChirpCore

@Suite struct EngineTests {
    func engine() throws -> PersonalLanguage { PersonalLanguage(store: try ChirpStore()) }

    @Test func profileRoundTrip() throws {
        let e = try engine()
        #expect(try e.profile() == WritingProfile())
        var p = WritingProfile()
        p.spelling = .british
        p.formality = .formal
        p.styleNotes = "Short sentences."
        try e.saveProfile(p)
        #expect(try e.profile() == p)
    }

    @Test func addWordMergesAliases() throws {
        let e = try engine()
        try e.addWord("Kubernetes", soundsLike: ["cooper netties"])
        try e.addWord("kubernetes", soundsLike: ["kuber nettys", "Cooper Netties"])
        let all = try e.dictionary()
        #expect(all.count == 1)
        #expect(all[0].soundsLike == ["cooper netties", "kuber nettys"])
    }

    @Test func learnedCorrectionsAreMarkedAndForgettable() throws {
        let e = try engine()
        try e.addWord("Chirp")
        let learned = try e.learnCorrection(heard: "okafar", meant: "Okafor", note: "Corrected in history")
        #expect(learned?.origin == .learned)
        #expect(try e.learnCorrection(heard: "same", meant: "Same", note: "") == nil)
        #expect(try e.dictionary().count == 2)
        try e.forgetLearned()
        #expect(try e.dictionary().map(\.term) == ["Chirp"])
    }

    /// The style of the app in front, changed from the perch's More menu or the menu bar.
    @Test func theStyleOfOneAppIsChangedInPlace() throws {
        let e = try engine()
        let mail = WorkContext(bundleID: "com.apple.mail", appName: "Mail")
        try e.setFormality(.formal, for: mail)
        #expect(try e.formality(for: mail) == .formal)
        #expect(try e.appStyles().map(\.appName) == ["Mail"])
        // Changing it again changes the same row, and the underlines stay as they were.
        try e.setFormality(.casual, for: mail)
        #expect(try e.appStyles().count == 1)
        #expect(try e.formality(for: mail) == .casual)
        #expect(try e.underlinesEnabled(for: mail))
        // An app Chirp stays out of is given a style without having its underlines switched on.
        let out = WorkContext(bundleID: "com.apple.Terminal", appName: "Terminal")
        let before = try e.underlinesEnabled(for: out)
        try e.setFormality(.formal, for: out)
        #expect(try e.underlinesEnabled(for: out) == before)
        // With no app there is nothing to set.
        try e.setFormality(.formal, for: WorkContext())
        #expect(try e.appStyles().count == 2)
    }

    @Test func appStyleDecidesFormality() throws {
        let e = try engine()
        #expect(try e.formality(for: WorkContext(bundleID: "com.apple.MobileSMS")) == .neutral)
        try e.save(AppStyle(bundleID: "com.apple.MobileSMS", appName: "Messages", formality: .casual))
        try e.save(AppStyle(bundleID: "com.apple.MobileSMS", appName: "Messages", formality: .casual))
        #expect(try e.appStyles().count == 1)
        #expect(try e.formality(for: WorkContext(bundleID: "com.apple.MobileSMS")) == .casual)
    }

    @Test func underlinesDefaultOffInEditors() throws {
        let e = try engine()
        #expect(try e.underlinesEnabled(for: WorkContext(bundleID: "com.apple.TextEdit")))
        #expect(try !e.underlinesEnabled(for: WorkContext(bundleID: "com.microsoft.VSCode")))
        try e.save(AppStyle(bundleID: "com.microsoft.VSCode", appName: "Code", underlinesEnabled: true))
        #expect(try e.underlinesEnabled(for: WorkContext(bundleID: "com.microsoft.VSCode")))
    }

    @Test func dismissedRules() throws {
        let e = try engine()
        try e.dismiss(ruleKey: "SpellCheck", text: "teh")
        try e.dismiss(ruleKey: "OxfordComma", text: nil)
        let rules = try e.dismissedRules()
        #expect(e.isDismissed(ruleKey: "SpellCheck", text: "teh", in: rules))
        #expect(!e.isDismissed(ruleKey: "SpellCheck", text: "wrod", in: rules))
        #expect(e.isDismissed(ruleKey: "OxfordComma", text: "anything", in: rules))
    }

    @Test func storeSeedsTemplatesAndIndexesItems() throws {
        let store = try ChirpStore()
        try store.db.write { db in
            #expect(try NoteTemplate.fetchCount(db) == 5)
            var item = SavedItem(kind: .dictation, title: "Note", body: "Deploying Kubernetes on Friday")
            try item.insert(db)
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM itemFTS WHERE itemFTS MATCH ?", arguments: ["deploy"])
            #expect(hits == 1)
        }
    }

    @Test func opensOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-\(UUID().uuidString)/db.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let e = PersonalLanguage(store: try ChirpStore(url: url))
        try e.addWord("Chirp")
        let again = PersonalLanguage(store: try ChirpStore(url: url))
        #expect(try again.dictionary().count == 1)
    }
}
