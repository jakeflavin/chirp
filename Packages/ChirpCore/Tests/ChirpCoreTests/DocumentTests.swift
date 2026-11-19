import Foundation
import Testing

@testable import ChirpCore

@Suite struct DocumentStoreTests {
    @Test func aLibraryMadeBeforeDocumentsKeptLayoutsOpensWithEverythingInIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-docs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var ids: [Int64] = []
        do {
            // A library as it was at the step before.
            let lib = Library(store: try ChirpStore(url: url, upTo: "v5"))
            let folder = try lib.addFolder("Launch")
            let doc = try lib.save(SavedItem(kind: .document, title: "Plan", body: "One. Two.", summary: "- A point", folderID: folder.id, source: "https://example.com/plan", position: 5, starred: true))
            let meeting = try lib.save(SavedItem(kind: .meeting, title: "Sync", summary: "## Summary\n- Done"))
            try lib.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: meeting.id!, speaker: "Me", start: 0, end: 2, text: "marmalade")])
            _ = try lib.save(SavedItem(kind: .dictation, body: "Hello there."))
            ids = [doc.id!, meeting.id!]
        }
        let lib = Library(store: try ChirpStore(url: url))
        #expect(try lib.items().count == 3)
        let doc = try #require(try lib.item(ids[0]))
        #expect(doc.title == "Plan" && doc.body == "One. Two." && doc.summary == "- A point" && doc.position == 5 && doc.starred)
        #expect(doc.source == "https://example.com/plan" && doc.folderID != nil)
        #expect(try lib.segments(itemID: ids[1]).map(\.text) == ["marmalade"])
        #expect(try lib.search("marmalade").count == 1)
        #expect(try lib.folders().map(\.name) == ["Launch"])
        // Nothing was made up for the documents that were already there.
        #expect(try lib.documentExtra(itemID: ids[0]) == nil)
        #expect(try lib.documentFacts().isEmpty)
        #expect(try lib.store.db.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") } == "ok")
    }

    @Test func whatADocumentKeepsIsSavedAndGoesWithIt() throws {
        let lib = Library(store: try ChirpStore())
        let doc = try lib.save(SavedItem(kind: .document, title: "Plan", body: "Heading\n\nWords."))
        let id = try #require(doc.id)
        try lib.save(DocumentExtra(itemID: id, layout: DocLayout.plain(doc.body).json, site: "Example", format: "PDF", pages: 14))
        #expect(try lib.documentExtra(itemID: id)?.pages == 14)
        // The list's copy leaves the layout out.
        #expect(try lib.documentFacts()[id]?.layout == "")
        #expect(try lib.documentFacts()[id]?.format == "PDF")
        try lib.setSummaryCollapsed(itemID: id, true)
        #expect(try lib.documentExtra(itemID: id)?.summaryCollapsed == true)
        #expect(try lib.documentExtra(itemID: id)?.format == "PDF")
        try lib.delete(doc)
        #expect(try lib.documentExtra(itemID: id) == nil)
    }

    @Test func foldingTheSummaryOfADocumentWithNothingKeptMakesItsRow() throws {
        let lib = Library(store: try ChirpStore())
        let id = try #require(try lib.save(SavedItem(kind: .document, body: "Words.")).id)
        try lib.setSummaryCollapsed(itemID: id, true)
        #expect(try lib.documentExtra(itemID: id) == DocumentExtra(itemID: id, summaryCollapsed: true))
    }

    @Test func foldersAreRenamedCountedAndDeletedWithoutTheirItems() throws {
        let lib = Library(store: try ChirpStore())
        let launch = try lib.addFolder("Launch")
        let running = try lib.addFolder("Running")
        let a = try lib.save(SavedItem(kind: .document, title: "A", body: "a", folderID: launch.id))
        _ = try lib.save(SavedItem(kind: .meeting, title: "B", folderID: launch.id))
        let c = try lib.save(SavedItem(kind: .voiceNote, title: "C"))
        try lib.setFolder(id: c.id!, running.id)
        #expect(try lib.folderCounts() == [launch.id!: 2, running.id!: 1])
        #expect(try lib.folderCounts(kinds: [.document]) == [launch.id!: 1])
        #expect(try lib.folderCounts(kinds: []) == [:])
        #expect(try lib.items(folderID: launch.id).count == 2)
        try lib.rename(launch, to: "  Launch week ")
        try lib.rename(running, to: "   ")
        #expect(try lib.folders().map(\.name) == ["Launch week", "Running"])
        try lib.delete(launch)
        #expect(try lib.item(a.id!)?.folderID == nil)
        #expect(try lib.items().count == 3)
        try lib.setFolder(id: c.id!, nil)
        #expect(try lib.folderCounts() == [:])
    }

    @Test func pinningChangesOnlyThePin() throws {
        let lib = Library(store: try ChirpStore())
        let doc = try lib.save(SavedItem(kind: .document, title: "A", body: "a", position: 3))
        try lib.setPosition(id: doc.id!, position: 9)
        try lib.setPinned(id: doc.id!, true)
        #expect(try lib.item(doc.id!)?.starred == true)
        #expect(try lib.item(doc.id!)?.position == 9)
        _ = try lib.save(SavedItem(kind: .dictation, body: "x", starred: true))
        #expect(try lib.pinned(kinds: [.document, .meeting]).map(\.title) == ["A"])
    }
}

@Suite struct DocumentRowsTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15))! }

    @Test func pinnedLeadThenTodayThenEarlier() {
        let items = [
            SavedItem(id: 1, kind: .document, title: "today", createdAt: now.addingTimeInterval(-3600)),
            SavedItem(id: 2, kind: .document, title: "pinned old", starred: true, createdAt: now.addingTimeInterval(-9 * 86_400)),
            SavedItem(id: 3, kind: .document, title: "yesterday", createdAt: now.addingTimeInterval(-86_400)),
            SavedItem(id: 4, kind: .document, title: "pinned today", starred: true, createdAt: now),
        ]
        let groups = DocumentRows.groups(items, now: now, calendar: cal)
        #expect(groups.map(\.title) == ["Pinned", "Today", "Earlier"])
        #expect(groups[0].isPinned && groups[0].items.map(\.id) == [2, 4])
        #expect(groups[1].items.map(\.id) == [1] && groups[2].items.map(\.id) == [3])
        #expect(DocumentRows.groups(Array(items.prefix(1)), now: now, calendar: cal).map(\.title) == ["Today"])
    }

    @Test func aRowSaysWhatItIsHowLongAndItsFolder() {
        let page = SavedItem(kind: .document, title: "Pace", body: String(repeating: "word ", count: 100), source: "https://www.longrunjournal.com/pace")
        #expect(DocumentRows.meta(page, extra: nil, readSeconds: 540, folder: "Running") == "longrunjournal.com · 9 min read · Running")
        let pdf = SavedItem(kind: .document, title: "Contract", body: "x", source: "/tmp/Contract.pdf")
        #expect(DocumentRows.meta(pdf, extra: DocumentExtra(itemID: 1, format: "PDF", pages: 14), readSeconds: 900, folder: "Launch") == "PDF · 14 pages · Launch")
        // One saved before formats were kept is told from its file's ending.
        #expect(DocumentRows.meta(pdf, extra: nil, readSeconds: 360) == "PDF · 6 min read")
        var book = SavedItem(kind: .document, title: "Book", body: String(repeating: "a", count: 100), source: "/b.epub")
        book.position = 41
        #expect(DocumentRows.meta(book, extra: DocumentExtra(itemID: 2, format: "EPUB"), readSeconds: 9000, folder: "Reading list") == "EPUB · 41% heard · Reading list")
        let video = SavedItem(kind: .document, title: "Designing calm software", body: "x", duration: 2530, source: "https://www.youtube.com/watch?v=1")
        #expect(DocumentRows.meta(video, extra: DocumentExtra(itemID: 3, format: "YouTube"), readSeconds: 60, speakers: 2) == "YouTube · 42 min · 2 speakers")
        #expect(DocumentRows.meta(SavedItem(kind: .document, body: "x", source: "Pasted text"), extra: nil, readSeconds: 60) == "Text · 1 min read")
        #expect(DocumentRows.subtitle([page, book]) == "2 documents · 1 being read")
        #expect(DocumentRows.subtitle([]) == "No documents")
    }

    @Test func theSourceLineNamesTheSiteAndLinksToIt() {
        let page = SavedItem(kind: .document, title: "Pace", body: "x", source: "https://longrunjournal.com/pace", createdAt: now.addingTimeInterval(-7200))
        let source = DocumentRows.source(page, extra: DocumentExtra(itemID: 1, site: "Long Run Journal", format: "Web page"), readSeconds: 540, now: now, calendar: cal)
        #expect(source.linkTitle == "Long Run Journal · longrunjournal.com")
        #expect(source.link?.absoluteString == "https://longrunjournal.com/pace")
        #expect(source.rest.hasPrefix("9 min read · saved today "))
        // No site name: the address's own.
        #expect(DocumentRows.source(page, extra: nil, readSeconds: 540, now: now, calendar: cal).linkTitle == "longrunjournal.com")
        let pdf = SavedItem(kind: .document, title: "Contract", body: "x", source: "/tmp/Contract.pdf", createdAt: now.addingTimeInterval(-4 * 86_400))
        let file = DocumentRows.source(pdf, extra: DocumentExtra(itemID: 2, format: "PDF", pages: 14), readSeconds: 60, folder: "Launch", now: now, calendar: cal)
        #expect(file.link == nil && file.linkTitle == "")
        #expect(file.rest == "PDF · 14 pages · added Friday · Launch")
        let video = SavedItem(kind: .document, title: "Designing calm software", body: "x", duration: 2530, source: "https://www.youtube.com/watch?v=1", createdAt: now.addingTimeInterval(-86_400))
        let link = DocumentRows.source(video, extra: DocumentExtra(itemID: 3, format: "YouTube"), readSeconds: 60, speakers: 2, now: now, calendar: cal)
        #expect(link.linkTitle == "YouTube · Designing calm software")
        #expect(link.rest == "42 min · 2 speakers · transcribed yesterday")
        #expect(DocumentRows.day(now.addingTimeInterval(-30 * 86_400), now: now, calendar: cal).contains("Oct"))
    }

    @Test func aFoldedSummaryShowsItsFirstSentence() {
        #expect(DocumentRows.summaryLine("## The main point\n\nRun the first miles **slower**.\n\n## Pacing\n- Start slow") == "Run the first miles slower.")
        #expect(DocumentRows.summaryLine("- First point\n- Second") == "First point")
        #expect(DocumentRows.summaryLine("") == "")
    }
}

@Suite struct DocLayoutTests {
    /// The words a block covers.
    func words(_ block: DocLayout.Block, _ text: String) -> String {
        (text as NSString).substring(with: NSRange(location: block.start, length: block.length))
    }

    @Test func aPageKeepsItsStructure() {
        let html = """
            <html><head><title>Pace | Long Run Journal</title><meta property="og:site_name" content="Long Run Journal"></head><body>
            <nav><a href="/">Home</a></nav>
            <article><h1>How to pace</h1>
            <figure><img src="/img/road.jpg" alt="A road"><figcaption>The first miles.</figcaption></figure>
            <p>Most people ran the <b>first third</b> too <em>fast</em>. A <a href="/pace-bands">pace band</a> helps.</p>
            <h2>Pick a goal</h2>
            <blockquote><p>Speed up then, not before.</p></blockquote>
            <ul><li>Eat first.</li><li>Take <strong>water</strong>.</li></ul>
            <ol><li>One</li><li>Two</li></ol>
            <table><thead><tr><th>Week</th><th>Long run</th></tr></thead><tbody><tr><td>1</td><td>4 miles</td></tr></tbody></table>
            <pre>let a = 1\n  let b = 2</pre>
            <script>var x = "<p>not this</p>";</script>
            </article></body></html>
            """
        let article = HTMLDocument.article(from: html, base: URL(string: "https://longrunjournal.com/pace"))
        #expect(article.title == "How to pace")
        #expect(article.site == "Long Run Journal")
        let text = article.builder.text, layout = article.builder.layout
        #expect(layout.fits(length: (text as NSString).length))
        #expect(!text.contains("Home") && !text.contains("not this") && !text.contains("How to pace"))
        #expect(layout.blocks.map(\.kind) == [.image, .paragraph, .heading, .quote, .bullet, .bullet, .numbered, .numbered, .tableHead, .tableRow, .code])
        #expect(layout.blocks[0].image == "https://longrunjournal.com/img/road.jpg" && layout.blocks[0].caption == "The first miles.")
        let para = layout.blocks[1]
        #expect(words(para, text) == "Most people ran the first third too fast. A pace band helps.")
        let ns = text as NSString
        #expect(para.spans.map { "\($0.style.rawValue):\(ns.substring(with: NSRange(location: $0.start, length: $0.length)))" } == ["bold:first third", "italic:fast", "link:pace band"])
        #expect(para.spans[2].url == "https://longrunjournal.com/pace-bands")
        #expect(words(layout.blocks[4], text) == "Eat first.")
        #expect(layout.blocks[7].marker == "2." && words(layout.blocks[7], text) == "Two")
        #expect(layout.blocks[8].cells?.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) } == ["Week", "Long run"])
        #expect(words(layout.blocks[10], text) == "let a = 1\n  let b = 2")
        // The text is what reading aloud has always been given: points with a dash, rows with bars.
        #expect(text.contains("\n\n- Eat first.\n\n- Take water.\n\n1. One\n\n2. Two\n\n| Week | Long run |\n\n| 1 | 4 miles |"))
        // And it is read a cell at a time, as before.
        let cells = ReadingText.sentences(text).filter(\.isCell).map(\.text)
        #expect(cells == ["Week", "Long run", "1", "4 miles"])
    }

    @Test func sentencesAreFoundInTheirBlocks() {
        let article = HTMLDocument.blocks(from: "<p>One. Two.</p><ul><li>Three.</li></ul><p>Four. Five. Six.</p>")
        let sentences = ReadingText.sentences(article.text)
        let ranges = article.layout.blocks.map { DocLayout.sentences(in: $0.start, length: $0.length, of: sentences) }
        #expect(ranges == [0..<2, 2..<3, 3..<6])
        #expect(DocLayout.sentences(in: 0, length: 0, of: sentences).isEmpty)
    }

    @Test func aPictureInASentenceGoesAfterItsParagraphAndTinyOnesGo() {
        let b = HTMLDocument.blocks(from: #"<p>Before <img src="a.png"> after.</p><img src="pixel.gif" width="1" height="1"><p>Next.</p><img src="b.png">"#, base: URL(string: "https://x.org/p/"))
        #expect(b.layout.blocks.map(\.kind) == [.paragraph, .image, .paragraph, .image])
        #expect(b.layout.blocks[1].image == "https://x.org/p/a.png")
        #expect(b.text == "Before after.\n\nNext.")
    }

    @Test func anEmptyCellKeepsItsColumn() {
        let b = HTMLDocument.blocks(from: "<table><tr><th></th><th>Mon</th><th>Tue</th></tr><tr><td>Run</td><td></td><td>5 km</td></tr></table>")
        #expect(b.layout.blocks.map { $0.cells?.count } == [3, 3])
        #expect(b.layout.fits(length: (b.text as NSString).length))
        #expect(ReadingText.sentences(b.text).map(\.text) == ["Mon", "Tue", "Run", "5 km"])
    }

    @Test func plainTextIsLaidOutFromHowItIsWritten() {
        let text = "How Birds Learn\n\nMost songbirds are not born knowing their song. A young bird listens to adults for weeks before it makes a sound.\n\n## Setup\n\n- First\n\n2. Second\n\n> Quoted words\n\n| A | B |\n\n|---|---|\n\n| 1 | 2 |\n\n```\ncode here\n```\n\nLast words."
        let layout = DocLayout.plain(text)
        #expect(layout.fits(length: (text as NSString).length))
        #expect(layout.blocks.map(\.kind) == [.heading, .paragraph, .heading, .bullet, .numbered, .quote, .tableHead, .tableRow, .code, .paragraph])
        #expect(words(layout.blocks[0], text) == "How Birds Learn")
        #expect(words(layout.blocks[2], text) == "Setup")
        #expect(words(layout.blocks[3], text) == "First")
        #expect(words(layout.blocks[4], text) == "Second" && layout.blocks[4].marker == "2.")
        #expect(words(layout.blocks[5], text) == "Quoted words")
        #expect(words(layout.blocks[8], text) == "code here")
        // A short line before another short line is not a heading.
        #expect(DocLayout.plain("Thanks\n\nAlex").blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(DocLayout.plain("").blocks.isEmpty)
    }

    @Test func markdownLosesItsMarksAndKeepsItsStyles() {
        let b = MarkdownDocument.blocks(from: "# Title\n\nSome **bold** and *slanted* words with a [link](https://x.org) and `code`.\nStill the same paragraph.\n\n- Point one\n- Point two\n\n> A quote\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n![A chart](chart.png)\n")
        #expect(b.layout.blocks.map(\.kind) == [.heading, .paragraph, .bullet, .bullet, .quote, .tableHead, .tableRow, .image])
        #expect(b.text.hasPrefix("Title\n\nSome bold and slanted words with a link and code. Still the same paragraph.\n\n- Point one"))
        #expect(b.layout.blocks[1].spans.map(\.style) == [.bold, .italic, .link, .code])
        #expect(b.layout.blocks[7].caption == "A chart")
        #expect(b.layout.fits(length: (b.text as NSString).length))
    }

    @Test func aLayoutIsWrittenBackAsMarkdownAndKeptAsJSON() {
        let b = HTMLDocument.blocks(from: "<h2>Pacing</h2><p>Run <b>slow</b> with a <a href=\"https://x.org\">band</a>.</p><ul><li>One</li><li>Two</li></ul><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(b.layout.markdown(b.text) == "## Pacing\n\nRun **slow** with a [band](https://x.org).\n\n- One\n- Two\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
        #expect(DocLayout(json: b.layout.json) == b.layout)
        #expect(DocLayout(json: "") == nil && DocLayout(json: "{") == nil)
        // A layout made for other text is not used on this one.
        #expect(!b.layout.fits(length: 5))
        #expect(b.layout.markdown("short") == "short")
    }

    @Test func chaptersAreJoinedAndPicturesRenamed() {
        var book = HTMLDocument.blocks(from: "<h1>One</h1><p>First chapter.</p><img src='a.png'>")
        book.append(HTMLDocument.blocks(from: "<h1>Two</h1><p>Second <i>chapter</i>.</p><img src='gone.png'>"))
        #expect(book.text == "One\n\nFirst chapter.\n\nTwo\n\nSecond chapter.")
        #expect(book.layout.fits(length: (book.text as NSString).length))
        let ns = book.text as NSString
        let italic = book.layout.blocks.flatMap(\.spans).first { $0.style == .italic }!
        #expect(ns.substring(with: NSRange(location: italic.start, length: italic.length)) == "chapter")
        book.mapImages { $0 == "a.png" ? "img-1.png" : nil }
        #expect(book.layout.blocks.filter { $0.kind == .image }.map(\.image) == ["img-1.png"])
    }
}

@Suite struct RichTextTests {
    @Test func aSummaryIsCopiedWithItsHeadingsAndPoints() {
        let html = RichText.html(fromMarkdown: "## The main point\n\nRun **slower** than <goal> pace.\n\n## Pacing\n- Start *slow*\n- See [the plan](https://x.org/a?b=1&c=2)\n\n1. One\n2. Two")
        #expect(html == """
            <h2>The main point</h2>
            <p>Run <strong>slower</strong> than &lt;goal&gt; pace.</p>
            <h2>Pacing</h2>
            <ul>
            <li>Start <em>slow</em></li>
            <li>See <a href="https://x.org/a?b=1&amp;c=2">the plan</a></li>
            </ul>
            <ol>
            <li>One</li>
            <li>Two</li>
            </ol>
            """)
    }

    @Test func aTableIsCopiedAsATable() {
        let html = RichText.html(fromMarkdown: "Before\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n> Quoted")
        #expect(html == "<p>Before</p>\n<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>\n<blockquote>Quoted</blockquote>")
    }
}
