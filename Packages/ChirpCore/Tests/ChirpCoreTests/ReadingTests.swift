import Foundation
import Testing

@testable import ChirpCore

@Suite struct ReadingTests {
    @Test func splitsSentencesWithOffsets() {
        let text = "Dr. Smith arrived at 3.5 p.m. on Monday. She said \"Hello!\" Then left.\n\nNew paragraph here."
        let s = ReadingText.sentences(text)
        #expect(s.map(\.text) == ["Dr. Smith arrived at 3.5 p.m. on Monday.", "She said \"Hello!\"", "Then left.", "New paragraph here."])
        #expect(s.map(\.startsParagraph) == [true, false, false, true])
        let ns = text as NSString
        for sentence in s {
            #expect(ns.substring(with: NSRange(location: sentence.offset, length: sentence.length)) == sentence.text)
        }
    }

    @Test func headingsAndListsAreTheirOwnSentences() {
        let s = ReadingText.sentences("Chapter One\nIt was late. Very late.\n- first item\n- second item")
        #expect(s.map(\.text) == ["Chapter One", "It was late.", "Very late.", "- first item", "- second item"])
    }

    @Test func cleansPdfText() {
        let raw = "This is an exam-\nple of wrapped\ntext in a PDF.\n\n12\n\nSecond   paragraph\ncontinues here."
        #expect(ReadingText.clean(raw) == "This is an example of wrapped text in a PDF.\n\nSecond paragraph continues here.")
    }

    @Test func aBareHeadingFromAPDFStaysOnItsOwnLine() {
        let raw = "How Birds Learn to Sing\nMost songbirds are not born knowing their song. A young bird listens to adults for weeks.\nThen it starts to babble."
        #expect(ReadingText.clean(raw).hasPrefix("How Birds Learn to Sing\n\nMost songbirds are not born"))
        // Lines of a wrapped paragraph are about the same length: they are still joined.
        let wrapped = "The first line of a paragraph that was wrapped\nby the page and carries on over a second line\nand ends here."
        #expect(ReadingText.clean(wrapped) == "The first line of a paragraph that was wrapped by the page and carries on over a second line and ends here.")
    }

    @Test func removesRunningHeadersAndFooters() {
        let pages = (1...5).map { "My Report 2026\nIntro line \($0).\nBody of page \($0) goes here.\nMore text.\nClosing line \($0).\nLast words.\nPage \($0) of 5" }
        let out = ReadingText.clean(pages.joined(separator: "\n"), pages: pages)
        #expect(!out.contains("My Report"))
        #expect(!out.contains("of 5"))
        #expect(out.contains("Body of page 3 goes here."))
    }

    @Test func spokenFormDropsCitationsAndLinks() {
        #expect(
            ReadingText.spoken("Results improved [12] and [3, 4]; see https://example.com/x for more.")
                == "Results improved and; see link for more.")
        #expect(ReadingText.spoken("Ask Saoirse.", pronunciations: ["Saoirse": "Seer-sha"]) == "Ask Seer-sha.")
    }

    @Test func wordTimingsUseSpokenWeightsWhenTheyLineUp() {
        let t = ReadingText.wordTimings(sentence: "Hi there friend", spokenWeights: [1, 2, 1], duration: 2)
        #expect(t.map(\.start) == [0, 0.5, 1.5])
        #expect(t.last?.end == 2)
        #expect(("Hi there friend" as NSString).substring(with: t[1].range) == "there")
        #expect(ReadingText.wordIndex(at: 0.6, in: t) == 1)
        #expect(ReadingText.wordIndex(at: 5, in: t) == 2)
    }

    @Test func wordTimingsFallBackToLength() {
        // "$45" is spoken as three words, so the counts differ and length is used instead.
        let t = ReadingText.wordTimings(sentence: "It costs $45", spokenWeights: [1, 1, 1, 1, 1], duration: 3)
        #expect(t.count == 3)
        #expect(abs(t.last!.end - 3) < 0.0001)
        #expect(t[0].end < t[1].end - t[1].start + t[0].end)
        #expect(ReadingText.wordTimings(sentence: "", spokenWeights: [], duration: 1).isEmpty)
    }
}

@Suite struct HTMLTextTests {
    @Test func extractsArticle() {
        let html = """
            <html><head><title>Site &mdash; Page</title><style>p{color:red}</style></head><body>
            <nav><a href="/">Home</a> <a href="/about">About</a></nav>
            <article><h1>How Birds Sing</h1>
            <p>Birds sing with a <em>syrinx</em>, not a larynx. It sits where the windpipe splits, and each side can make its own sound at the same time, which is how some species sing two notes at once.</p>
            <script>track()</script>
            <p>Most song is learned &amp; practised.<br>Young birds babble first.</p>
            <ul><li>Dawn chorus</li><li>Alarm calls</li></ul>
            </article><footer>Copyright 2026</footer></body></html>
            """
        let a = HTMLText.article(from: html)
        #expect(a.title == "How Birds Sing")
        #expect(a.text.hasPrefix("How Birds Sing\n\nBirds sing with a syrinx, not a larynx."))
        #expect(a.text.contains("Most song is learned & practised. Young birds babble first."))
        #expect(a.text.contains("- Dawn chorus\n\n- Alarm calls"))
        #expect(!a.text.contains("Home"))
        #expect(!a.text.contains("track()"))
        #expect(!a.text.contains("Copyright"))
    }

    @Test func decodesEntities() {
        #expect(HTMLText.decodeEntities("Tom &amp; Jerry &#8212; &#x263A; &unknown;") == "Tom & Jerry — ☺ &unknown;")
    }

    @Test func readsEpubStructure() {
        let container = #"<container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        #expect(HTMLText.epubPackagePath(container: container) == "OEBPS/content.opf")
        let opf = """
            <package><metadata><dc:title>A Short Book</dc:title></metadata>
            <manifest><item id="c2" href="ch%202.xhtml" media-type="application/xhtml+xml"/><item href="ch1.xhtml" id="c1"/><item id="css" href="s.css"/></manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
            """
        let spine = HTMLText.epubSpine(package: opf)
        #expect(spine.title == "A Short Book")
        #expect(spine.chapters == ["ch1.xhtml", "ch 2.xhtml"])
    }

    @Test func bracketedAsidesCanBeSkipped() {
        let s = "The effect was large (Smith, 2019) and held up [see Figure 2] over time."
        #expect(ReadingText.spoken(s, skipBrackets: true) == "The effect was large and held up over time.")
        #expect(ReadingText.spoken(s, skipCitations: false).contains("Smith"))
        // Only the citation goes by default; the aside stays.
        #expect(ReadingText.spoken(s) == "The effect was large and held up [see Figure 2] over time.")
    }

    @Test func cleaningKeepsCodeBlocksListItemsAndHeadingsApart() {
        let raw = "# Setup\nInstall it with one\ncommand:\n```sh\ngit clone repo\n  make install\n```\nThen:\n- open the app\n- pick a model\n1. first\n2. second"
        #expect(ReadingText.clean(raw) == "# Setup\n\nInstall it with one command:\n\n```sh\ngit clone repo\n  make install\n```\n\nThen:\n\n- open the app\n\n- pick a model\n\n1. first\n\n2. second")
        // A fence that never closes is ordinary text.
        #expect(ReadingText.clean("Before\n```\nlast line") == "Before\n\n```\n\nlast line")
    }
}
