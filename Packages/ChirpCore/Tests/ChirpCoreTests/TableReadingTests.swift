import XCTest

@testable import ChirpCore

/// A table is read row by row, left to right, a cell at a time: each cell is a
/// sentence of its own (so the mark moves cell by cell), with a short pause after it and a longer one at
/// the end of its row. Column names are not repeated.
final class TableReadingTests: XCTestCase {
    private let table = """
        Paces for the first month.

        | Week | Long run | Pace |
        |------|----------|------|
        | 1 | 8 km | 6:10 |
        | 2 | 10 km | 6:05 |

        Take the fourth week easy.
        """

    func testEachCellIsASentenceAndTheRuleIsNotRead() {
        let sentences = ReadingText.sentences(table)
        XCTAssertEqual(sentences.map(\.text), [
            "Paces for the first month.", "Week", "Long run", "Pace", "1", "8 km", "6:10", "2", "10 km", "6:05", "Take the fourth week easy.",
        ])
        XCTAssertEqual(sentences.map(\.isCell), [false, true, true, true, true, true, true, true, true, true, false])
        // The first cell of each row starts it; what follows the table starts a paragraph again.
        XCTAssertEqual(sentences.map(\.startsParagraph), [true, true, false, false, true, false, false, true, false, false, true])
        XCTAssertEqual(sentences.map(\.index), Array(0..<11))
    }

    func testEachCellIsWhereItIsInTheText() {
        // The mark is drawn from these: each cell's own words, and nothing of the bars around them.
        let ns = table as NSString
        for sentence in ReadingText.sentences(table) {
            XCTAssertEqual(ns.substring(with: NSRange(location: sentence.offset, length: sentence.length)), sentence.text)
        }
    }

    func testAShortPauseAfterACellAndALongerOneAfterARow() {
        let sentences = ReadingText.sentences(table)
        let pauses = sentences.indices.map { ReadingText.pause(after: $0, in: sentences) }
        // Week | Long run | Pace
        XCTAssertEqual(Array(pauses[1...3]), [ReadingText.cellPause, ReadingText.cellPause, ReadingText.rowPause])
        XCTAssertEqual(Array(pauses[4...6]), [ReadingText.cellPause, ReadingText.cellPause, ReadingText.rowPause])
        XCTAssertEqual(pauses[9], ReadingText.rowPause, "the last row ends like any row")
        XCTAssertGreaterThan(ReadingText.rowPause, ReadingText.cellPause)
        // Longer than the breath between two sentences, so a table is not rushed.
        XCTAssertGreaterThan(ReadingText.cellPause, ReadingText.pause(after: 0, in: ReadingText.sentences("One. Two.")))
    }

    func testATableWithTabsBetweenItsCells() {
        // How a table selected or copied in another app arrives, and how a page read off the screen is written.
        let text = "Name\tPace\tDistance\nPriya\t5:40\t12 km\nSam\t6:02\t8 km"
        let sentences = ReadingText.sentences(text)
        XCTAssertEqual(sentences.map(\.text), ["Name", "Pace", "Distance", "Priya", "5:40", "12 km", "Sam", "6:02", "8 km"])
        XCTAssertTrue(sentences.allSatisfy(\.isCell))
        XCTAssertEqual(sentences.filter(\.startsParagraph).map(\.text), ["Name", "Priya", "Sam"])
        let ns = text as NSString
        for s in sentences { XCTAssertEqual(ns.substring(with: NSRange(location: s.offset, length: s.length)), s.text) }
    }

    func testACellKeepsItsSentencesTogether() {
        let sentences = ReadingText.sentences("| Plan | Rest on Monday. Run on Tuesday. |")
        XCTAssertEqual(sentences.map(\.text), ["Plan", "Rest on Monday. Run on Tuesday."])
    }

    func testProseIsReadAsBefore() {
        // A bar or a tab in a line of prose does not make it a table.
        XCTAssertNil(ReadingText.tableCells("Use a | b to pipe one command into the next."))
        XCTAssertNil(ReadingText.tableCells("Chapter one"))
        XCTAssertNil(ReadingText.tableCells("\tAn indented line."))
        XCTAssertNil(ReadingText.tableCells("| only one cell |"))
        XCTAssertEqual(ReadingText.tableCells("|---|:--:|")?.count, 0)
        let prose = "Dr. Lee arrived at 3.5 km. She waited!\n\nThen she ran on."
        let sentences = ReadingText.sentences(prose)
        XCTAssertEqual(sentences.map(\.text), ["Dr. Lee arrived at 3.5 km.", "She waited!", "Then she ran on."])
        XCTAssertEqual(sentences.map(\.startsParagraph), [true, false, true])
        XCTAssertFalse(sentences.contains(where: \.isCell))
        let ns = prose as NSString
        for s in sentences { XCTAssertEqual(ns.substring(with: NSRange(location: s.offset, length: s.length)), s.text) }
    }

    func testACellIsSaidAsItsWordsAlone() {
        // No bar reaches the voice, and a cell ends like a line, so the voice comes down after it.
        for sentence in ReadingText.sentences(table) where sentence.isCell {
            let said = ReadingText.spoken(sentence.text)
            XCTAssertFalse(said.contains("|"))
            XCTAssertFalse(said.contains(","), said)
        }
        XCTAssertEqual(ReadingText.spoken("Long run"), "Long run.")
    }

    func testAWebPagesTableIsWrittenAsRows() {
        let html = "<p>Paces.</p><table><tr><th>Week</th><th>Pace</th></tr><tr><td>1</td><td>6:10</td></tr></table><p>Easy does it.</p>"
        let text = HTMLText.text(from: html)
        XCTAssertEqual(text, "Paces.\n\n| Week | Pace |\n\n| 1 | 6:10 |\n\nEasy does it.")
        XCTAssertEqual(ReadingText.sentences(text).map(\.text), ["Paces.", "Week", "Pace", "1", "6:10", "Easy does it."])
    }

    func testCleaningImportedTextKeepsRowsApart() {
        let cleaned = ReadingText.clean("Paces for\nthe month.\n| Week | Pace |\n| 1 | 6:10 |\nTake it easy.")
        XCTAssertEqual(cleaned, "Paces for the month.\n\n| Week | Pace |\n\n| 1 | 6:10 |\n\nTake it easy.")
        let tabbed = ReadingText.clean("Name\tPace\nPriya\t5:40")
        XCTAssertEqual(ReadingText.sentences(tabbed).map(\.text), ["Name", "Pace", "Priya", "5:40"])
    }
}
