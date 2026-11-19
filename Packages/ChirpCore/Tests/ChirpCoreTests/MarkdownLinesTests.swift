import Foundation
import Testing
@testable import ChirpCore

@Suite struct MarkdownLinesTests {
    @Test func headingsPointsAndText() {
        let lines = MarkdownLines.parse("## Summary\n\nBirds learn **young**.\n- First point\n* Second\n  - Nested\n1. One\n2) Two")
        #expect(lines == [
            .init(kind: .heading(2), text: "Summary"),
            .init(kind: .text, text: "Birds learn **young**."),
            .init(kind: .point(marker: "•", depth: 0), text: "First point"),
            .init(kind: .point(marker: "•", depth: 0), text: "Second"),
            .init(kind: .point(marker: "•", depth: 1), text: "Nested"),
            .init(kind: .point(marker: "1.", depth: 0), text: "One"),
            .init(kind: .point(marker: "2.", depth: 0), text: "Two"),
        ])
    }

    @Test func aLineThatIsOnlyBoldIsAHeading() {
        #expect(MarkdownLines.parse("**Key points:**") == [.init(kind: .heading(3), text: "Key points")])
        #expect(MarkdownLines.parse("### **Next steps**") == [.init(kind: .heading(3), text: "Next steps")])
        #expect(MarkdownLines.parse("**Bold** then more.") == [.init(kind: .text, text: "**Bold** then more.")])
    }

    @Test func rulesBlankLinesAndTaskBoxesAreDropped() {
        #expect(MarkdownLines.parse("One\n\n---\n***\n- [ ] Call Sam\n- [x] Done") == [
            .init(kind: .text, text: "One"),
            .init(kind: .point(marker: "•", depth: 0), text: "Call Sam"),
            .init(kind: .point(marker: "•", depth: 0), text: "Done"),
        ])
    }

    @Test func thingsThatOnlyLookLikeMarksStayText() {
        #expect(MarkdownLines.parse("#hashtag").first?.kind == .text)
        #expect(MarkdownLines.parse("3.5 months is the answer").first?.kind == .text)
        #expect(MarkdownLines.parse("-5 degrees").first?.kind == .text)
        #expect(MarkdownLines.parse("2026. A year").first?.kind == .text)
        #expect(MarkdownLines.parse("").isEmpty)
    }

    @Test func plainTextDropsTheMarks() {
        #expect(MarkdownLines.plain("## Summary\n- **Birds** learn *young*.\n1. Use `song`\n2 * 3 * 4") == "Summary\nBirds learn young.\n1. Use song\n2 * 3 * 4")
    }
}

@Suite struct WordRangeTests {
    @Test func aNonBreakingSpaceSeparatesWords() {
        let ranges = ReadingText.wordRanges("reply until\u{00a0}Friday.")
        #expect(ranges == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5), NSRange(location: 12, length: 7)])
    }
}

@Suite struct DiffLayoutTests {
    @Test func breaksFollowTheWordsOfTheText() {
        #expect(WordDiff.breaks(after: "Hi,\n\nThis is a test.\nThanks,\n\n\n\nAlex") == ["\n\n", " ", " ", " ", "\n", "\n\n", ""])
        #expect(WordDiff.breaks(after: "  one   two ") == [" ", ""])
        #expect(WordDiff.breaks(after: "").isEmpty)
        #expect(WordDiff.breaks(after: "Hi,\n\nAlex").count == WordDiff.tokens("Hi,\n\nAlex").count)
    }

    @Test func fencedCodeIsOneBlockWithItsLineBreaks() {
        let lines = MarkdownLines.parse("Run this:\n\n```sh\ngit clone repo\n\n  make install   # builds it\n```\n\nThen `open` it.\n~~~\n- not a point\n~~~")
        #expect(lines == [
            .init(kind: .text, text: "Run this:"),
            .init(kind: .code, text: "git clone repo\n\n  make install   # builds it"),
            .init(kind: .text, text: "Then `open` it."),
            .init(kind: .code, text: "- not a point"),
        ])
    }

    @Test func aFenceThatIsNeverClosedEndsWithTheText() {
        #expect(MarkdownLines.parse("Before\n```\nswift build\n# not a heading") == [
            .init(kind: .text, text: "Before"), .init(kind: .code, text: "swift build\n# not a heading"),
        ])
        // An empty block is nothing; backticks inside a sentence are not a fence.
        #expect(MarkdownLines.parse("```\n\n```").isEmpty)
        #expect(MarkdownLines.parse("```code``` in a sentence").first?.kind == .text)
    }

    @Test func plainTextKeepsCodeAsWritten() {
        #expect(MarkdownLines.plain("## Install\nRun **this**:\n```\nmake `all` **now**\n```") == "Install\nRun this:\nmake `all` **now**")
    }
}
