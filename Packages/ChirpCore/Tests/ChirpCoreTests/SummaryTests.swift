import Foundation
import Testing
@testable import ChirpCore

@Suite struct SummaryTests {
    // MARK: Planning

    static let paragraph = "This is a sentence of plain reading matter that goes on for a while. "

    /// A document of `sections` headed sections, each with `paragraphs` paragraphs of about 280 characters.
    static func document(sections: Int, paragraphs: Int) -> String {
        (1...sections).map { s in
            (["Section \(s) heading"] + (1...paragraphs).map { p in String(repeating: paragraph, count: 4) + "End \(s).\(p)." }).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    @Test func aShortTextIsNotSectionedAndAsksForAFewPoints() {
        let brief = SummaryPlan.make(for: String(repeating: "Ten words. ", count: 30))
        #expect(!brief.sectioned)
        #expect(brief.parts.count == 1)
        #expect(brief.parts[0].points == 2)
        // About 1,700 characters and only two headings: one step, three sentences, no sections.
        let longer = SummaryPlan.make(for: Self.document(sections: 2, paragraphs: 3))
        #expect(!longer.sectioned)
        #expect(longer.parts.count == 1)
        #expect(longer.parts[0].points == 3)
        #expect(SummaryPlan.make(for: "").parts.isEmpty)
    }

    /// Long text with no headings in it.
    static func prose(paragraphs: Int) -> String {
        (1...paragraphs).map { String(repeating: paragraph, count: 4) + "End \($0)." }.joined(separator: "\n\n")
    }

    @Test func everyCharacterOfALongDocumentIsInSomePart() {
        let text = Self.prose(paragraphs: 56)
        let plan = SummaryPlan.make(for: text)
        #expect(plan.sectioned)
        #expect(plan.parts.map(\.text).joined(separator: "\n\n") == text)
        #expect(plan.parts.allSatisfy { $0.text.count <= SummaryPlan.part * 14 / 10 })
        // Near the same size: no stub at the end.
        let sizes = plan.parts.map(\.text.count)
        #expect(sizes.min()! * 5 > sizes.max()! * 2)
        // No headings in the original: the model names each part; about one point per 700 characters.
        #expect(plan.parts.allSatisfy { $0.heading == nil && $0.points == SummaryPlan.points(for: $0.text.count) })
    }

    @Test func aDocumentWithHeadingsIsSummarizedSectionBySection() {
        let text = "A Title For The Piece\n\n" + String(repeating: Self.paragraph, count: 6) + "\n\n" + Self.document(sections: 14, paragraphs: 4)
        let plan = SummaryPlan.make(for: text)
        // Every section after the title and its opening is a part, in order, under its own heading: none is put with another.
        #expect(plan.parts.map(\.heading) == (1...14).map { "Section \($0) heading" })
        #expect(plan.parts.allSatisfy { $0.text.hasPrefix("Section ") && $0.points == 2 && !$0.continues && !$0.extractive })
        #expect(text.hasSuffix("\n\n" + plan.parts.map(\.text).joined(separator: "\n\n")))
    }

    @Test func aLongSectionIsCutUpUnderItsOwnHeadingAndASmallOneKeepsItsPlace() {
        let long = "Title\n\nOpening words that say what this is about, at some length.\n\nFirst\n\n" + Self.prose(paragraphs: 12)
            + "\n\nTiny\n\nJust a line under a small heading here.\n\nSecond\n\n" + Self.prose(paragraphs: 5)
            + "\n\nThird\n\n" + Self.prose(paragraphs: 3)
        let plan = SummaryPlan.make(for: long)
        // "First" is about 3,500 characters: two pieces, both under "First" (the second carries it on). The tiny
        // section keeps its own heading and place, and is its own first sentence (no model step).
        #expect(plan.parts.map(\.heading) == ["First", "First", "Tiny", "Second", "Third"])
        #expect(plan.parts.map(\.continues) == [false, true, false, false, false])
        #expect(plan.parts.map(\.extractive) == [false, false, true, false, false])
        #expect(plan.parts[2].text == "Just a line under a small heading here.")
        #expect(plan.parts.map(\.points) == [2, 2, 2, 2, 1])
        // Fewer than three headings: cut by size instead.
        #expect(SummaryPlan.make(for: "Only\n\n" + Self.prose(paragraphs: 20)).parts.allSatisfy { $0.heading == nil })
    }

    @Test func theSectionsAreTheHighestLevelThatRepeatsAndALongOneShowsItsOwn() {
        let small = "# Tool\n\nIntro line that is long enough to read as prose for the test.\n\n## One\n\n" + Self.prose(paragraphs: 2)
            + "\n\n### One a\n\n" + Self.prose(paragraphs: 1) + "\n\n## Two\n\n" + Self.prose(paragraphs: 2)
        let outline = SummaryPlan.outline(SummaryPlan.paragraphs(small))!
        // The lone "#" title is the title; "##" repeats, so those are the sections; "### One a" stays inside "One".
        #expect(outline.map(\.heading) == ["", "One", "Two"])
        #expect(outline[1].lines.contains("### One a"))
        let big = "# Tool\n\n## Usage\n\n" + (1...3).map { "### Part \($0)\n\n" + Self.prose(paragraphs: 9) }.joined(separator: "\n\n")
            + "\n\n## License\n\n" + Self.prose(paragraphs: 1)
        let nested = SummaryPlan.outline(SummaryPlan.paragraphs(big))!
        #expect(nested.map(\.heading) == ["", "Usage", "Part 1", "Part 2", "Part 3", "License"])
        #expect(nested.map(\.depth) == [0, 0, 1, 1, 1, 0])
        // Numbered headings of a paper, and their depth.
        #expect(SummaryPlan.isHeading("2. Methods", next: String(repeating: "x", count: 90)))
        #expect(SummaryPlan.numberedLevel("2. Methods") == 2 && SummaryPlan.numberedLevel("2.1 Study sites") == 3 && SummaryPlan.numberedLevel("Results") == 2)
        // An email thread's sections are its messages, headed by sender and day; its sign-offs and rules are not sections.
        let message = { (name: String, day: String) in ["From: \(name)", "Subject: Re: the plan", "Date: \(day), 2026 at 4:12 PM", "Hi all,", String(repeating: Self.paragraph, count: 3), "Alex", "-----"] }
        let thread = SummaryPlan.outline(message("Sofia Ramirez", "November 16") + message("Devon Price <devon@example.com>", "November 15"))!
        #expect(thread.map(\.heading) == ["Sofia Ramirez, November 16", "Devon Price, November 15"])
        #expect(SummaryPlan.outline(message("Sofia Ramirez", "November 16")) == nil)
        // An email's header lines, a date and a byline are not headings.
        for line in ["-----", "Postgres 19 adds built-in vector search (6 minute read)", "From: Sofia Ramirez", "Subject: Re: the plan", "November 8, 2026", "By Isabel Fournier", "1. Read the timestamp and the signature from the header."] {
            #expect(!SummaryPlan.isHeading(line, next: String(repeating: "x", count: 90)))
        }
    }

    @Test func textThatArrivedAsOneBlockIsCutAtSentences() {
        let blob = String(repeating: Self.paragraph, count: 150)
        let plan = SummaryPlan.make(for: blob)
        #expect(plan.parts.count >= 2)
        #expect(plan.parts.allSatisfy { $0.text.count <= SummaryPlan.part * 14 / 10 })
        #expect(plan.parts.allSatisfy { $0.text.hasSuffix(".") })
        #expect(plan.parts.map(\.text.count).reduce(0, +) >= blob.count - 300)
    }

    @Test func aVeryLongDocumentGetsBiggerPartsAndABookIsCoveredToItsEnd() {
        let long = SummaryPlan.make(for: Self.prose(paragraphs: 1250))  // about 370,000 characters
        #expect(long.parts.count <= SummaryPlan.mostParts + 2)
        #expect(long.parts.allSatisfy { $0.points == 4 })
        // No cap: a book is all planned, in parts no bigger than the biggest.
        let text = Self.prose(paragraphs: 2500)  // about 740,000
        let book = SummaryPlan.make(for: text)
        #expect(book.parts.count > SummaryPlan.mostParts)
        #expect(book.parts.allSatisfy { $0.text.count <= SummaryPlan.biggestPart * 14 / 10 })
        #expect(book.parts.reduce(0) { $0 + $1.text.count } >= book.characters - 2 * book.parts.count)
    }

    @Test func headingsMakeSectionsAtAnyLength() {
        // Three headings in a short text: still its sections.
        let short = SummaryPlan.make(for: "A Title\n\n" + Self.document(sections: 3, paragraphs: 1))
        #expect(short.sectioned && short.parts.count == 3)
    }

    @Test func halvesSplitAPartInTwo() {
        let halves = SummaryPlan.halves(of: Self.document(sections: 4, paragraphs: 3))
        #expect(halves.count == 2)
        #expect(halves[1].hasPrefix("Section 3"))
    }

    // MARK: Reading the model's answer

    @Test func anAnswerIsReadAsSections() {
        let found = SummaryNotes.sections(
            from: "### **Family and Social Ideas**\n\n- Family goals should be countable.\n* Social goals take a standing date.\n\n### Creative\n- Define done first.", cut: false)
        #expect(found == [
            SummarySection(heading: "Family and Social Ideas", points: ["Family goals should be countable.", "Social goals take a standing date."]),
            SummarySection(heading: "Creative", points: ["Define done first."]),
        ])
    }

    @Test func leadInsLabelsAndEmptyHeadingsAreLeftOut() {
        let found = SummaryNotes.sections(from: "Here are the main points:\n- One point is made here.\n\nA sentence written without its bullet mark.\n### Nothing under this", cut: false)
        #expect(found == [SummarySection(heading: "", points: ["One point is made here.", "A sentence written without its bullet mark."])])
        #expect(SummaryNotes.sections(from: "", cut: false).isEmpty)
    }

    @Test func aCutOffAnswerLosesItsUnfinishedLastLine() {
        let answer = "### Fitness\n- Run three times a week.\n- Lift twice a week and hit a strength"
        #expect(SummaryNotes.endsUnfinished(answer))
        #expect(!SummaryNotes.endsUnfinished("- Run three times a week.\n- \"Is that enough?\"\n"))
        #expect(!SummaryNotes.endsUnfinished("- **Done.**"))
        #expect(SummaryNotes.sections(from: answer, cut: true) == [SummarySection(heading: "Fitness", points: ["Run three times a week."])])
        // Not cut: a point without a full stop is still a point.
        #expect(SummaryNotes.sections(from: answer, cut: false)[0].points.count == 2)
        // Cut under a heading with nothing finished: nothing.
        #expect(SummaryNotes.sections(from: "### Career\n- Plan the wee", cut: true).isEmpty)
    }

    @Test func aParagraphWrittenAsAPointKeepsItsFirstSentence() {
        let long = "The author identifies eight core categories for yearly goals. " + String(repeating: "He goes on and on about them at length. ", count: 8)
        #expect(SummaryNotes.sections(from: "- " + long, cut: false)[0].points == ["The author identifies eight core categories for yearly goals."])
    }

    @Test func tooManyPointsAreThinnedFromFirstToLast() {
        let many = SummarySection(heading: "Fun", points: (1...11).map { "Point \($0)." })
        let fitted = SummaryNotes.fitted([many], points: 4, headed: true)
        #expect(fitted.count == 1)
        #expect(fitted[0].points.count == 5)
        #expect(fitted[0].points.first == "Point 1." && fitted[0].points.last == "Point 11.")
        // Repeats go.
        #expect(SummaryNotes.fitted([SummarySection(heading: "A", points: ["Same point.", "same point", "Other."])], points: 3, headed: true)[0].points == ["Same point.", "Other."])
    }

    @Test func severalSectionsFromOnePartBecomeOne() {
        let three = (1...3).map { s in SummarySection(heading: "S\(s)", points: (1...3).map { "S\(s) point \($0)." }) }
        // The model followed the part's own sub-headings: one section, points spread from the first to the last.
        let fitted = SummaryNotes.fitted(three, points: 3, headed: true)
        #expect(fitted.count == 1)
        #expect(fitted[0].heading == "S1")
        #expect(fitted[0].points == ["S1 point 1.", "S2 point 1.", "S2 point 3.", "S3 point 3."])
        // A short text has no headings: one paragraph.
        #expect(SummaryNotes.fitted(three, points: 3, headed: false) == [SummarySection(heading: "", points: ["S1 point 1.", "S2 point 1.", "S2 point 3.", "S3 point 3."])])
        // The part's list and code go with its section.
        let withCode = SummaryNotes.fitted(three, points: 3, headed: true, list: true, code: "make install")
        #expect(withCode.allSatisfy { $0.list })
        #expect(withCode.map(\.code) == ["make install"])
    }

    @Test func aShortSectionStandsForItselfWithItsOwnWords() {
        #expect(SummaryNotes.extract("Riverside FC fired manager Tomas Brandt on Monday after seven games without a win. The club is 17th.", points: 2).points
            == ["Riverside FC fired manager Tomas Brandt on Monday after seven games without a win."])
        let list = SummaryNotes.extract("- Swift 6.0 or later\n- macOS 14 or later", points: 2)
        #expect(list.points == ["Swift 6.0 or later", "macOS 14 or later"] && list.list)
        #expect(SummaryNotes.extract("", points: 2).points.isEmpty)
        // Nothing from a block of code.
        #expect(SummaryNotes.extract("```swift\n// Create a client with the defaults\nlet c = Client()\n```", points: 2).points.isEmpty)
    }

    @Test func aPartTheModelFailedOnIsStoodInForByItsOwnSentences() {
        let part = "Goals I’d Skip\n\nSome goals look great on paper and quietly wreck the list. Here’s what I’d leave off.\n\nAnything starting with “stop.” Flip it into something to do. The study above backs this up."
        let standIn = SummaryNotes.fallback(for: part, points: 2)
        #expect(standIn.heading == "Goals I’d Skip")
        #expect(standIn.points == ["Some goals look great on paper and quietly wreck the list.", "Anything starting with “stop.” Flip it into something to do."])
    }

    @Test func anAbbreviationDoesNotEndASentence() {
        #expect(SummaryNotes.firstSentence("The Court heard argument in McGirt v. Oklahoma on the reservation question. Then more.") == "The Court heard argument in McGirt v. Oklahoma on the reservation question.")
    }

    // MARK: The finished summary

    @Test func theSummaryIsAnOverviewThenTheSectionsInOrder() {
        let summary = SummaryNotes.compose(
            sentence: "A way to pick yearly goals. It has three parts.",
            sections: [
                SummarySection(heading: "The method", points: ["Pick five of eight categories.", "Tie each goal to a weekly habit"]),
                SummarySection(heading: "Steps", points: ["Family goals: make them countable.", "At 5:30 the day ends."], list: true),
                SummarySection(heading: "Usage", points: []),
                SummarySection(heading: "Install", points: ["Build it from source."], code: "git clone repo\n  make install", depth: 1),
                SummarySection(heading: "Empty", points: []),
            ], note: "This covers the first 70% of the document.")
        #expect(summary == """
            A way to pick yearly goals. It has three parts.

            ### The method
            - Pick five of eight categories.
            - Tie each goal to a weekly habit.

            ### Steps
            - **Family goals:** make them countable.
            - At 5:30 the day ends.

            ### Usage

            #### Install
            Build it from source.

            ```
            git clone repo
              make install
            ```

            This covers the first 70% of the document.
            """)
        // What the views draw: paragraphs, headings, lists, a block of code.
        let lines = MarkdownLines.parse(summary)
        #expect(lines.map(\.kind) == [
            .text, .heading(3), .point(marker: "•", depth: 0), .point(marker: "•", depth: 0), .heading(3), .point(marker: "•", depth: 0), .point(marker: "•", depth: 0),
            .heading(3), .heading(4), .text, .code, .text,
        ])
        #expect(lines[10].text == "git clone repo\n  make install")
        // No heading is ever two put together.
        #expect(!summary.contains(" / "))
        // Copied and read aloud without the marks; the code as it is written.
        let plain = MarkdownLines.plain(summary)
        #expect(plain.contains("Family goals: make them countable."))
        #expect(plain.contains("git clone repo\n  make install"))
        #expect(!plain.contains("#") && !plain.contains("```") && !plain.contains("**"))
    }

    @Test func aShortSummaryIsAParagraphWithNoHeadings() {
        #expect(SummaryNotes.compose(sentence: "One. Two.", sections: []) == "One. Two.")
        #expect(MarkdownLines.parse("One. Two.").map(\.kind) == [.text])
        #expect(SummaryNotes.compose(sentence: "", sections: []) == "")
    }

    @Test func aPartThatIsAListOrHasCodeIsPlannedThatWay() {
        let steps = "Setup\n\n" + (1...14).map { "\($0). Step number \($0) tells you to do one particular thing, then to check that it worked before going on to the next." }.joined(separator: "\n\n")
        let prose = (1...30).map { "Paragraph \($0) is plain reading matter that carries on for a line or so of the document." }.joined(separator: "\n\n")
        let list = SummaryPlan.make(for: steps + "\n\n" + prose)
        #expect(list.parts.contains { $0.list && $0.points == 5 })
        #expect(list.parts.last?.list == false)
        let readme = "# Tool\n\nWhat it is, in a sentence or two of plain words for the reader.\n\n## Installation\n\nRun this to install it on your machine.\n\n```sh\ngit clone repo\n\n  make install\n```\n\n"
            + prose + "\n\n## History\n\n```\nold --flag\n```\n\n" + prose + "\n\n## License\n\n" + prose
        let code = SummaryPlan.make(for: readme)
        // Markdown's own headings are the sections; a command is kept under a heading about installing, not under any heading.
        #expect(code.parts.filter { !$0.continues }.compactMap(\.heading).filter { !$0.isEmpty } == ["Installation", "History", "License"])
        #expect(code.parts.first { $0.heading == "Installation" }?.code == "git clone repo\n  make install")
        #expect(code.parts.first { $0.heading == "History" }?.code == nil)
        #expect(code.parts.map(\.text).joined(separator: "\n\n").contains("```sh\ngit clone repo"))
        // A block of code or a list item is never taken for a heading.
        #expect(!SummaryPlan.isHeading("```\nmake\n```", next: String(repeating: "x", count: 90)))
        #expect(!SummaryPlan.isHeading("- A short item", next: String(repeating: "x", count: 90)))
        #expect(SummaryPlan.isHeading("What Makes a Good Yearly Goal?", next: String(repeating: "x", count: 90)))
        // A long block keeps its first lines.
        let long = "```\n" + (1...9).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        #expect(SummaryPlan.code(in: [long]) == (1...6).map { "line \($0)" }.joined(separator: "\n") + "\n…")
        #expect(SummaryPlan.code(in: ["no code here"]) == nil)
    }

    @Test func theModelsOwnCodeAndBrokenMarksNeverReachTheSummary() {
        // An unclosed fence, a stray "#", a heading with nothing under it, a point that is a whole paragraph.
        let answer = "### Install\n- Clone the repository and build it.\n#\n### Empty\n```sh\nrm -rf /\n- This sits inside a fence the model never closed."
        let found = SummaryNotes.sections(from: answer, cut: false)
        #expect(found == [SummarySection(heading: "Install", points: ["Clone the repository and build it."])])
        let summary = SummaryNotes.compose(sentence: "", sections: SummaryNotes.fitted(found, points: 2, headed: true, code: "make"))
        #expect(summary == "### Install\nClone the repository and build it.\n\n```\nmake\n```")
        // Code that has a fence of its own inside is wrapped in the other kind.
        #expect(SummaryNotes.compose(sentence: "", sections: [SummarySection(heading: "", points: ["Run it."], code: "```\nx\n```")]).contains("~~~\n```\nx\n```\n~~~"))
        // No more than three blocks of code in one summary.
        let five = (1...5).map { SummarySection(heading: "H\($0)", points: ["Run it."], code: "cmd \($0)") }
        #expect(MarkdownLines.parse(SummaryNotes.compose(sentence: "", sections: five)).filter { $0.kind == .code }.map(\.text) == ["cmd 1", "cmd 2", "cmd 3"])
    }

    @Test func requestsPutTheTextFirstAndAskForAnExactNumber() throws {
        let prompts = Prompts(profile: WritingProfile())
        let titled = prompts.summaryPartRequest(part: "BODY", points: 4, titled: true)
        #expect(titled.hasPrefix("<part>\nBODY\n</part>"))
        #expect(titled.contains("exactly 4 bullet points"))
        #expect(titled.contains("###"))
        let plain = prompts.summaryPartRequest(part: "BODY", points: 2, titled: false)
        #expect(plain.contains("exactly 2 bullet points") && !plain.contains("###"))
        #expect(prompts.summaryPartRequest(part: "BODY", points: 1, titled: false).contains("in one sentence"))
        #expect(prompts.summaryPartRequest(part: "BODY", points: 5, titled: true, list: true).contains("one item from the list"))
        #expect(prompts.summarySystem().contains("English spelling"))
        #expect(Prompts(profile: WritingProfile(), terms: ["Chirp"]).summarySystem().contains("Chirp"))
    }

    // MARK: A page read off the screen

    static let page: String = {
        let menu = ["Skip to content", "Mara Ellison", "Home", "Recipes31 posts", "Travel9 posts", "House & Garden 14 posts", "Bikes6 posts", "About", "Home/", "Garden/"]
        let top = ["Garden", "Spring Planting Ideas: 40 Crops in 6 Groups", "12 minute read", "//", "March 3, 2026", "By Mara Ellison", "Share"]
        let body = [
            "TLDR: The easiest way to plan a spring garden is by crop group, and three groups are enough.",
            "The 6 Crop Groups",
            "The idea of planting by group is not mine, and growers have used it for years.",
            "Leaves and salads: lettuce, spinach, chard.",
        ] + (1...12).map { "Paragraph \($0) of the article says something at a fair length, as real articles tend to do." } + [
            "Try This Before April",
            "Six groups. Three beds. One crop each. That’s it. That’s the whole method.",
        ]
        let after = ["On this page — 9 sections", "The 6 Crop Groups", "Try This Before April", "// Keep reading", "More from Garden",
                     "Raised Beds: Why I Build Mine in the Autumn", "8 minute read", "© 2026 Mara Ellison // Grown at home", "Contact", "Privacy Policy"]
        return (menu + top + body + after).joined(separator: "\n")
    }()

    @Test func aPageLosesItsMenusAndLinksAndKeepsItsTitle() {
        let article = PageText.article(Self.page).components(separatedBy: "\n")
        #expect(article.first == "Spring Planting Ideas: 40 Crops in 6 Groups")
        #expect(article[1].hasPrefix("TLDR"))
        #expect(article.last == "Six groups. Three beds. One crop each. That’s it. That’s the whole method.")
        #expect(article.contains("The 6 Crop Groups"))
        #expect(!article.contains("Home") && !article.contains("Privacy Policy") && !article.contains("Share"))
    }

    @Test func textThatIsNotAPageWithFurnitureIsLeftAlone() {
        let letter = "12 Maple Street\nSpringfield\n3 March\nDear Sam,\nThank you for the note you sent last week about the kitchen.\nBest,\nJo"
        #expect(PageText.article(letter) == letter)
        let list = (1...30).map { "Item \($0)" }.joined(separator: "\n")
        #expect(PageText.article(list) == list)
        // Mostly short lines with one sentence in the middle: dropping them would lose most of it.
        let mostlyShort = (1...12).map { "A much longer menu-like line number \($0)" }.joined(separator: "\n") + "\nOne real sentence sits here in the middle of it all.\n"
            + (1...12).map { "Another long link-like line number \($0)" }.joined(separator: "\n")
        #expect(PageText.article(mostlyShort) == mostlyShort)
    }

    @Test func linesBecomeParagraphsThatCleaningKeepsApart() {
        let text = PageText.paragraphs("The 6 Crop Groups\nThe idea is not mine.\n\n  Roots: carrots, beets and radishes.  ")
        #expect(text == "The 6 Crop Groups\n\nThe idea is not mine.\n\nRoots: carrots, beets and radishes.")
        #expect(ReadingText.clean(text) == text)
        // Without it the heading runs into the sentence after it.
        #expect(ReadingText.clean("The 6 Crop Groups\nThe idea is not mine.") == "The 6 Crop Groups The idea is not mine.")
    }
}
