import Foundation
import Testing
@testable import ChirpCore

/// "Source words first": every model point is read against the source, and a paper's
/// front matter and an email's footer stay out.
@Suite struct SourceWordsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Fixtures/summaries").standardized
    static func fixture(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    static let abstract = """
        Heat is the deadliest weather hazard in the United States, and night-time heat is particularly dangerous because it prevents the body from recovering. We measured air temperatures at 1,200 residential blocks in Chicago, Phoenix and Atlanta during the summers of 2024 and 2025, using low-cost sensors mounted on street lamps. Blocks with tree canopy covering more than 40% of the street area were on average 1.8°C cooler at 3 a.m. than blocks with less than 10% canopy, after adjusting for building density, paving and distance to water. The effect was largest in Phoenix (2.6°C) and smallest in Chicago (1.1°C). Low-income blocks had less than half the canopy of high-income blocks in all three cities. Our results suggest that planting street trees in low-canopy neighbourhoods could reduce exposure to dangerous night heat for the people most at risk.
        """

    // MARK: The check on model points

    /// s16, a reversal seen in a real summary: the paper says tree-covered blocks
    /// were cooler and low-income blocks had less canopy; the model said low-income blocks were cooler.
    @Test func theReversedFindingIsCaught() {
        let reversed = [
            "A study in Chicago, Phoenix, and Atlanta found low-income neighborhoods with less than 40% tree canopy were 1.1°C to 2.6°C cooler at night than high-income ones.",
            "Results show that low-income neighborhoods are 1.1°C to 2.6°C cooler at night due to less tree canopy coverage.",
            "Low-income blocks had 29% more canopy than high-income blocks.",
            "Blocks with less than 40% canopy were 1.8°C cooler at 3 a.m.",
            "Blocks with tree canopy covering more than 40% of the street area were on average 1.8°C warmer at 3 a.m.",
        ]
        for point in reversed { #expect(!SourceCheck.check(point, source: Self.abstract).passes, "\(point)") }
    }

    @Test func faithfulPointsPass() {
        let faithful = [
            "Blocks with more than 40% tree canopy were on average 1.8°C cooler at 3 a.m. than blocks with less than 10% canopy.",
            "The effect was largest in Phoenix (2.6°C) and smallest in Chicago (1.1°C).",
            "Low-income blocks had less than half the canopy of high-income blocks in all three cities.",
            "Sensors on street lamps measured air temperatures at 1,200 residential blocks in Chicago, Phoenix and Atlanta in 2024 and 2025.",
        ]
        for point in faithful {
            let verdict = SourceCheck.check(point, source: Self.abstract)
            #expect(verdict.passes, "\(point): \(verdict.problems)")
        }
    }

    /// s16's Discussion, where the model turned "each 1°C rise … increases deaths by 5%" into a 2°C drop.
    @Test func aChangedComparisonInTheDiscussionIsCaught() {
        let source = "Our results show that street trees are linked to meaningfully cooler nights, not only cooler days. A difference of 2°C may sound small, but studies of heat deaths suggest that each 1°C rise in night temperature during a heat wave increases deaths among older adults by roughly 5%."
        #expect(!SourceCheck.check("Street trees cool nights more than days, but a 2°C drop increases heat deaths among older adults by 5%.", source: source).passes)
        #expect(!SourceCheck.check("Street trees are linked to cooler days but not cooler nights.", source: source).passes)
        #expect(SourceCheck.check("Each 1°C rise in night temperature during a heat wave increases deaths among older adults by about 5%.", source: source).passes)
    }

    /// The email cases: a made-up claim in a short email, and a promotion turned round ("excludes new customers").
    @Test func theEmailExamplesAreCaught() {
        let email = Self.fixture("s27-review-request-email.txt")
        #expect(!SourceCheck.check("Further reminders are not sent, but the reviewer can contact Ledgerly directly via their Privacy Policy.", source: email).passes)
        #expect(SourceCheck.check("Reviews help other small businesses decide whether Ledgerly is right for them.", source: email).passes)
        let promo = Self.fixture("s28-promo-footer-email.txt")
        #expect(!SourceCheck.check("The 20% discount excludes new customers.", source: promo).passes)
        #expect(!SourceCheck.check("New customers get 30% off their first order this week.", source: promo).passes)
        #expect(!SourceCheck.check("Free shipping on orders over $40.", source: promo).passes)
        #expect(SourceCheck.check("New customers get 20% off their first order this week.", source: promo).passes)
    }

    @Test func aLostNotAndANewNameAreCaught() {
        let source = "When nights do not cool below about 24°C, the body cannot shed the heat it built up during the day."
        #expect(!SourceCheck.check("When nights cool below about 24°C, the body sheds the heat it built up during the day.", source: source).problems.isEmpty)
        let thread = "Tom found the crash in the export screen on Tuesday. Sofia will look at it next week."
        #expect(SourceCheck.check("Tom found the crash in the export screen on Tuesday.", source: thread).passes)
        #expect(!SourceCheck.check("Marcus found the crash in the export screen on Tuesday.", source: thread).passes)
    }

    /// A failed point is replaced by the source's own closest sentence; a second one that would repeat it is left out.
    @Test func aFailedPointBecomesTheSourceSentence() {
        let sections = [SummarySection(heading: "Abstract", points: [
            "Low-income neighborhoods are 1.1°C to 2.6°C cooler at night.",
            "The effect was largest in Phoenix (2.6°C) and smallest in Chicago (1.1°C).",
        ])]
        let checked = SourceCheck.checked(sections, source: Self.abstract)
        #expect(checked.replaced + checked.dropped == 1)
        let points = checked.sections[0].points
        #expect(!points.contains { $0.contains("Low-income neighborhoods are") })
        #expect(points.allSatisfy { Self.abstract.contains($0) || $0.hasPrefix("The effect was largest") })
    }

    @Test func numbersKeepTheirUnitsAndComparisons() {
        let found = SourceCheck.numbers(in: "Blocks with more than 40% canopy were 1.8°C cooler; each sensor cost about $45 and 1,200 blocks took part.")
        #expect(found.contains(SourceCheck.Number(value: "40", unit: "%", direction: "up")))
        #expect(found.contains { $0.value == "1.8" && $0.unit == "°c" })
        #expect(found.contains { $0.value == "45" && $0.unit == "$" })
        #expect(found.contains { $0.value == "1200" })
        #expect(SourceCheck.numbers(in: "eleven more nights").contains { $0.value == "11" })
    }

    // MARK: Front matter, footers and titles

    @Test func aPapersFrontMatterGoesAndItsTitleStays() {
        for file in ["s16-research-paper.txt", "s29-paper-from-pdf.txt"] {
            let kept = Boilerplate.strip(Self.fixture(file))
            for gone in ["Journal of Urban Health Studies", "Elena Vasquez", "Department of Environmental Health", "Midland Institute", "Keywords:", "Correspondence:", "Received 12 March", "Vasquez et al."] {
                #expect(!kept.contains(gone), "\(file): \(gone)")
            }
            #expect(kept.hasPrefix("Street Trees and Summer Night Temperatures"), "\(file)")
            #expect(Library.title(from: Self.fixture(file)).hasPrefix("Street Trees and Summer Night"), "\(file)")
            #expect(kept.contains("Abstract") && kept.contains("1. Introduction") && kept.contains("We thank the city lighting departments"))
        }
    }

    @Test func anEmailsFooterAndAddressGo() {
        let kept = Boilerplate.strip(Self.fixture("s28-promo-footer-email.txt"))
        for gone in ["do not click", "6050 Washington", "You received this email", "Unsubscribe", "View this email"] { #expect(!kept.contains(gone), "\(gone)") }
        for stays in ["New customers get 20% off", "COMFY20", "Free shipping"] { #expect(kept.contains(stays), "\(stays)") }
        let review = Boilerplate.strip(Self.fixture("s27-review-request-email.txt"))
        #expect(!review.contains("410 Market Street") && !review.contains("You are receiving this"))
        #expect(review.contains("Privacy Policy explains it"))
        #expect(Boilerplate.isPostalAddress("Northwind Apparel, 6050 Washington Blvd., Culver City, CA 90232"))
        #expect(!Boilerplate.isPostalAddress("We moved the meeting to Thursday at 3 so that more people can come."))
    }

    @Test func anAuthorListIsNotTakenForAnEmailsNames() {
        #expect(Boilerplate.isAuthorList("Elena Vasquez¹, Thomas Albright², Grace Mbeki¹"))
        #expect(!Boilerplate.isAuthorList("Thanks, Priya"))
        // Not a paper: nothing at its start is taken as front matter.
        let note = "Sofia Ramirez, Tom Becker\nWe met on Tuesday to plan the launch and agreed to move it a week."
        #expect(Boilerplate.strip(note).contains("Sofia Ramirez"))
    }

    @Test func mailsHeaderGivesTheSubject() {
        #expect(MailHeader.subject(fromHeaderLines: ["Ledgerly", "Subject:", "A quick reminder to review Ledgerly", "To: Alex"]) == "A quick reminder to review Ledgerly")
        #expect(MailHeader.subject(fromHeaderLines: ["Northwind Apparel", "Today at 6:02 PM", "20% off your first order", "To:", "alex@example.com"]) == "20% off your first order")
        #expect(MailHeader.subject(fromHeaderLines: ["Northwind Apparel"]) == nil)
        #expect(MailHeader.title("Re: Fwd: Warehouse launch") == "Warehouse launch")
    }
}
