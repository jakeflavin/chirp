import Foundation
import Testing

@testable import ChirpCore

@Suite struct CorrectionTests {
    @Test func aLibraryMadeBeforeCorrectionsWereCountedOpensWithEverythingInIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-corr-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var ids: [Int64] = []
        do {
            // A library as it was at the step before.
            let store = try ChirpStore(url: url, upTo: "v6")
            let lib = Library(store: store)
            let engine = PersonalLanguage(store: store)
            let folder = try lib.addFolder("Launch")
            let doc = try lib.save(SavedItem(kind: .document, title: "Plan", body: "One. Two.", summary: "- A point", folderID: folder.id, position: 5, starred: true))
            try lib.save(DocumentExtra(itemID: doc.id!, layout: DocLayout.plain(doc.body).json, format: "PDF", pages: 14))
            let meeting = try lib.save(SavedItem(kind: .meeting, title: "Sync", summary: "## Summary\n- Done"))
            try lib.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: meeting.id!, speaker: "Me", start: 0, end: 2, text: "marmalade")])
            _ = try lib.save(SavedItem(kind: .dictation, body: "Hello there."))
            try engine.addWord("Kubernetes", soundsLike: ["cooper netties"])
            try engine.save(Snippet(cue: "sign off", text: "Thanks, talk soon."))
            try engine.dismiss(ruleKey: "SpellCheck", text: "Zorblax")
            ids = [doc.id!, meeting.id!]
            #expect(try store.db.read { db in try db.tableExists("correction") } == false)
        }
        let store = try ChirpStore(url: url)
        let lib = Library(store: store)
        let engine = PersonalLanguage(store: store)
        #expect(try lib.items().count == 3)
        let doc = try #require(try lib.item(ids[0]))
        #expect(doc.title == "Plan" && doc.body == "One. Two." && doc.summary == "- A point" && doc.position == 5 && doc.starred && doc.folderID != nil)
        #expect(try lib.documentExtra(itemID: ids[0])?.pages == 14)
        #expect(try lib.segments(itemID: ids[1]).map(\.text) == ["marmalade"])
        #expect(try lib.search("marmalade").count == 1)
        #expect(try lib.folders().map(\.name) == ["Launch"])
        #expect(try engine.dictionary().map(\.term) == ["Kubernetes"])
        #expect(try engine.dictionary().first?.soundsLike == ["cooper netties"])
        #expect(try engine.snippets().map(\.cue) == ["sign off"])
        #expect(try engine.dismissedRules().count == 1)
        // The count starts empty, and counts.
        #expect(try engine.corrections().isEmpty)
        try engine.noteCorrection(wrong: "anthropc", right: "Anthropic")
        #expect(try engine.corrections().map(\.times) == [1])
        #expect(try store.db.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") } == "ok")
    }

    @Test func theSameCorrectionIsCountedUpAndOnlySingleWordsCount() throws {
        let engine = PersonalLanguage(store: try ChirpStore())
        for _ in 0..<3 { try engine.noteCorrection(wrong: "kubernets", right: "Kubernetes") }
        try engine.noteCorrection(wrong: " recieve ", right: "receive")
        try engine.noteCorrection(wrong: "a lot", right: "alot")
        try engine.noteCorrection(wrong: "same", right: "same")
        try engine.noteCorrection(wrong: "", right: "word")
        let all = try engine.corrections()
        #expect(all.map(\.right) == ["Kubernetes", "receive"])
        #expect(all.map(\.times) == [3, 1])
        #expect(try engine.corrections(atLeast: 3).map(\.wrong) == ["kubernets"])
        try engine.forgetCorrections(of: "kubernetes")
        #expect(try engine.corrections().map(\.right) == ["receive"])
        try engine.forgetLearned()
        #expect(try engine.corrections().isEmpty)
    }

    @Test func onlyANameOrATermOfTheUsersOwnIsOfferedForTheDictionary() {
        #expect(Correction(wrong: "kubernets", right: "Kubernetes").isOwnTerm)
        #expect(Correction(wrong: "Github", right: "GitHub").isOwnTerm)
        #expect(Correction(wrong: "k8", right: "K8s").isOwnTerm)
        #expect(!Correction(wrong: "recieve", right: "receive").isOwnTerm)
        // A capital the user typed too may only be the start of a sentence.
        #expect(!Correction(wrong: "Recieve", right: "Receive").isOwnTerm)
    }

    @Test func aWordCorrectedOftenBecomesATip() throws {
        let often = Correction(wrong: "kubernets", right: "Kubernetes", times: 4)
        let everyday = Correction(wrong: "recieve", right: "receive", times: 9)
        let twice = Correction(wrong: "anthropc", right: "Anthropic", times: 2)
        var facts = HomeTip.Facts(corrections: [everyday, twice, often])
        let tip = try #require(HomeTip.pick(facts, dismissed: [], lastDismissal: nil, now: Date()))
        #expect(tip.id == "word:kubernetes")
        #expect(tip.title == "You have corrected “kubernets” to “Kubernetes” four times")
        #expect(tip.button == "Add to Dictionary")
        #expect(tip.action == .addWord(term: "Kubernetes", wrong: "kubernets"))
        // Not once the word is in the Dictionary, not after its ×, and not with the Dictionary's features all off.
        facts.dictionary = ["kubernetes"]
        #expect(HomeTip.pick(facts, dismissed: [], lastDismissal: nil, now: Date()) == nil)
        facts.dictionary = []
        #expect(HomeTip.pick(facts, dismissed: ["word:kubernetes"], lastDismissal: nil, now: Date()) == nil)
        facts.features = FeatureSet(on: [.read, .summarize])
        #expect(HomeTip.candidates(facts).isEmpty)
        // A sentence dictated often still comes first.
        let both = HomeTip.Facts(dictations: Array(repeating: "Thanks, talk soon.", count: 3), corrections: [often])
        #expect(HomeTip.candidates(both).map(\.id) == ["repeat:thanks, talk soon", "word:kubernetes"])
    }

    @Test func theBirdLooksAtTheNewRowOnlyWhenNotesWereFinished() {
        #expect(HomeBird.looksAtNewRow(wasWriting: 7, nowWriting: nil, stopped: nil, hasNotes: true))
        // Still writing, or writing the next one.
        #expect(!HomeBird.looksAtNewRow(wasWriting: 7, nowWriting: 7, stopped: nil, hasNotes: true))
        #expect(!HomeBird.looksAtNewRow(wasWriting: 7, nowWriting: 8, stopped: nil, hasNotes: true))
        // Stopped part-way, or nothing came of it.
        #expect(!HomeBird.looksAtNewRow(wasWriting: 7, nowWriting: nil, stopped: 7, hasNotes: true))
        #expect(!HomeBird.looksAtNewRow(wasWriting: 7, nowWriting: nil, stopped: nil, hasNotes: false))
        #expect(!HomeBird.looksAtNewRow(wasWriting: nil, nowWriting: nil, stopped: nil, hasNotes: true))
        // Notes stopped earlier do not stop it looking at another meeting's.
        #expect(HomeBird.looksAtNewRow(wasWriting: 8, nowWriting: nil, stopped: 7, hasNotes: true))
    }
}

@Suite struct BookContentsTests {
    private let package = """
        <package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>So Good They Can&#39;t Ignore You</dc:title>
        <dc:creator opf:role="aut" opf:file-as="Newport, Cal">Newport, Cal</dc:creator>
        </metadata><manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="nav" href="text/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
        </manifest></package>
        """

    @Test func theAuthorIsReadFromThePackage() {
        #expect(BookContents.epubAuthor(package: package) == "Cal Newport")
        #expect(BookContents.epubAuthor(package: "<dc:creator>Ann Lee</dc:creator><dc:creator id=\"b\">Raj Patel</dc:creator>") == "Ann Lee and Raj Patel")
        #expect(BookContents.epubAuthor(package: "<dc:creator>A</dc:creator><dc:creator>B</dc:creator><dc:creator>C</dc:creator><dc:creator>D</dc:creator>") == "A and others")
        #expect(BookContents.epubAuthor(package: "<package/>") == "")
        // Not a name.
        #expect(BookContents.person("calibre (5.0) [https://calibre-ebook.com]") == "")
        #expect(BookContents.person("  Ursula K.\n Le Guin ") == "Ursula K. Le Guin")
    }

    @Test func theContentsAreFoundInTheNavigationPageOrTheOlderFile() {
        let found = BookContents.epubContentsPath(package: package)
        #expect(found?.path == "text/nav.xhtml" && found?.isNCX == false)
        let older = BookContents.epubContentsPath(package: "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        #expect(older?.path == "toc.ncx" && older?.isNCX == true)
        #expect(BookContents.epubContentsPath(package: "<package/>") == nil)
    }

    @Test func aBookInPartsIsCountedByPartsAndChapters() {
        // A common shape for a book: an introduction, four rules with fifteen chapters, a conclusion.
        var nav = "<nav epub:type=\"landmarks\"><ol><li><a href=\"c\">Cover</a></li></ol></nav><nav epub:type=\"toc\"><h1>Contents</h1><ol>"
        nav += "<li><a href=\"a\">Cover</a></li><li><a href=\"b\">Copyright</a></li><li><a href=\"i\">Introduction: The Passion</a></li>"
        var n = 0
        for (rule, chapters) in [(1, 3), (2, 4), (3, 4), (4, 4)] {
            nav += "<li><a href=\"r\(rule)\">Rule #\(rule)</a><ol>"
            for _ in 0..<chapters {
                n += 1
                nav += "<li><a href=\"c\(n)\"><span>Chapter \(n)</span></a></li>"
            }
            nav += "</ol></li>"
        }
        nav += "<li><a href=\"z\">Conclusion</a></li><li><a href=\"g\">Glossary</a></li><li><a href=\"p\">Career Profile Summaries</a></li><li><a href=\"k\">Acknowledgments</a></li><li><a>Notes</a></li></ol></nav>"
        let entries = BookContents.entries(nav: nav)
        #expect(entries.first == BookContents.Entry("Cover") && entries.count == 3 + 4 + 15 + 5)
        #expect(entries.first { $0.label == "Chapter 4" }?.depth == 1)
        let facts = BookContents.facts(author: "Cal Newport", entries: entries)
        #expect(facts == BookContents.Facts(author: "Cal Newport", parts: 4, chapters: 15, startsAt: "introduction"))
        #expect(facts.line == "Cal Newport. 4 parts, 15 chapters. Starts at the introduction.")
    }

    @Test func anOlderBooksContentsAreReadTheSameWay() {
        let ncx = """
            <ncx><docTitle><text>A Book</text></docTitle><navMap>
            <navPoint id="a"><navLabel><text>Title Page</text></navLabel><content src="t.html"/></navPoint>
            <navPoint id="b"><navLabel><text>Prologue</text></navLabel><content src="p.html"/></navPoint>
            <navPoint id="c"><navLabel><text>Part One</text></navLabel><content src="1.html"/>
              <navPoint id="d"><navLabel><text>1. Arrival</text></navLabel><content src="2.html"/></navPoint>
              <navPoint id="e"><navLabel><text>2. The House</text></navLabel><content src="3.html"/></navPoint>
            </navPoint>
            <navPoint id="f"><navLabel><text>Part Two</text></navLabel><content src="4.html"/>
              <navPoint id="g"><navLabel><text>3. Winter</text></navLabel><content src="5.html"/></navPoint>
            </navPoint>
            <navPoint id="h"><navLabel><text>Epilogue</text></navLabel><content src="6.html"/></navPoint>
            </navMap></ncx>
            """
        let entries = BookContents.entries(ncx: ncx)
        #expect(entries.map(\.depth) == [0, 0, 0, 1, 1, 0, 1, 0])
        let facts = BookContents.facts(author: "", entries: entries)
        #expect(facts == BookContents.Facts(parts: 2, chapters: 3, startsAt: "prologue"))
        #expect(facts.line == "2 parts, 3 chapters. Starts at the prologue.")
    }

    @Test func plainChaptersSectionsAndThinContentsAreCountedWithCare() {
        func flat(_ labels: [String]) -> [BookContents.Entry] { labels.map { BookContents.Entry($0) } }
        // A flat list of chapters: no parts.
        let novel = BookContents.facts(author: "Ann Lee", entries: flat(["Cover", "Chapter 1", "Chapter 2", "Chapter 3", "About the Author"]))
        #expect(novel.line == "Ann Lee. 3 chapters.")
        // Parts named in a flat list.
        let named = BookContents.facts(author: "", entries: flat(["Part I", "One", "Two", "Part II", "Three", "Four"]))
        #expect(named.parts == 2 && named.chapters == 4 && named.line == "2 parts, 4 chapters.")
        // Numbered chapters with sections under them: the sections are not chapters, the chapters are not parts.
        var sections: [BookContents.Entry] = []
        for n in 1...5 { sections += [BookContents.Entry("Chapter \(n)"), BookContents.Entry("A section", depth: 1), BookContents.Entry("Another", depth: 1)] }
        let manual = BookContents.facts(author: "", entries: sections)
        #expect(manual.parts == 0 && manual.chapters == 5)
        // One line, or none: nothing is said about chapters; the author still is.
        #expect(BookContents.facts(author: "Ann Lee", entries: flat(["Start"])).line == "Ann Lee.")
        #expect(BookContents.facts(author: "", entries: flat(["Cover", "The Whole Book"])).line == "")
        #expect(BookContents.facts(author: "", entries: []).line == "")
    }
}
