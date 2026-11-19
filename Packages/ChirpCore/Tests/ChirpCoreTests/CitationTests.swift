import Foundation
import Testing

@testable import ChirpCore

/// Marks that point at a source are left out of what is read aloud; brackets that are part of the writing stay.
struct CitationTests {
    private func said(_ s: String) -> String { Citations.removing(from: s) }

    @Test func numberedMarksGo() {
        #expect(said("The effect was large [1].") == "The effect was large.")
        #expect(said("It held [12, 13] over time.") == "It held over time.")
        #expect(said("Seen before [5–7] and since [3,4][9].") == "Seen before and since.")
        #expect(said("Seen before[2].") == "Seen before.")
    }

    @Test func authorAndYearMarksGo() {
        #expect(said("The effect was large (Smith 2020).") == "The effect was large.")
        #expect(said("The effect was large (Smith, 2020) and lasting.") == "The effect was large and lasting.")
        #expect(said("It held (Smith & Jones, 2019; Lee et al., 2021).") == "It held.")
        #expect(said("It held (Smith and Jones 2019a, p. 14).") == "It held.")
        #expect(said("It held (see van Dijk, 2008).") == "It held.")
        #expect(said("It held (O’Brien, Nguyen, and Lee, 2015, 2017).") == "It held.")
    }

    @Test func raisedNoteNumbersGo() {
        #expect(said("The effect was large.¹ It held.") == "The effect was large. It held.")
        #expect(said("The effect¹² was large,³⁻⁵ and held.”⁶") == "The effect was large, and held.”")
    }

    @Test func bracketsThatArePartOfTheWritingStay() {
        for kept in [
            "He wrote that it was “there [sic] problem”.", "The method (see below) is simple.", "It opened in Paris (2020) to full houses.",
            "The paper [see Figure 2] agrees.", "She left (in May 2020) for good.", "Sales fell (May 2020) and rose (Fiscal 2021).",
            "The edition [1987] is the one to read.", "Smith (2020) found the same.", "Choose (1) the first or (2) the second.",
            "It costs more (about $20) now.", "The index [a] is in the back.", "The team (Smith, Jones and Lee) won.",
            "The array a[12] holds it.".replacingOccurrences(of: "a[12]", with: "a [1200]"),
        ] {
            #expect(said(kept) == kept)
        }
    }

    @Test func raisedDigitsThatAreSquaresStay() {
        for kept in ["The room is 20 m² and the lot 2 km².", "So x² + y² = z².", "E = mc² is the one everyone knows.", "That is 10² or 100."] {
            #expect(said(kept) == kept)
        }
    }

    @Test func spokenLeavesThemOutUnlessToldNotTo() {
        let s = "The effect was large (Smith, 2019) and held up [3] over time [sic]."
        #expect(ReadingText.spoken(s) == "The effect was large and held up over time [sic].")
        #expect(ReadingText.spoken(s, skipCitations: false).contains("Smith"))
        #expect(ReadingText.spoken(s, skipCitations: false).contains("3"))
    }
}
