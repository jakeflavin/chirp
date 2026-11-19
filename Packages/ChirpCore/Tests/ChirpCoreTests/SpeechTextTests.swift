import Testing
@testable import ChirpCore

@Suite struct SpeechTextTests {
    private func said(_ s: String) -> String { SpeechText.spoken(s) }

    @Test func unitsAreSpelledOut() {
        #expect(said("The run took 25 s and used 3 GB of memory.") == "The run took 25 seconds and used 3 gigabytes of memory.")
        #expect(said("It took 1 s.") == "It took 1 second.")
        #expect(said("A 4.5 MB file at 60fps on a 120Hz screen") == "A 4.5 megabytes file at 60 frames per second on a 120 hertz screen")
        #expect(said("Wait 250ms, then 2 h more") == "Wait 250 milliseconds, then 2 hours more")
        #expect(said("It weighs 12 lbs and is 6 ft tall") == "It weighs 12 pounds and is 6 feet tall")
    }

    @Test func decadesAndPluralsAreNotSeconds() {
        #expect(said("Music from the 1920s and the 80s") == "Music from the 1920s and the 80s")
        #expect(said("She scored 3 As and 2 Bs") == "She scored 3 As and 2 Bs")
    }

    /// A number with K, M or B is read as written; with a currency sign it is money.
    /// What the voice says for each was checked by its sounds (`read-sounds`): "5 K" is
    /// "five kay", "5M" "five em", "3B" "three bee", "5 thousand dollars" "five thousand dollars".
    @Test func aNumberWithKMOrBIsReadAsWritten() {
        #expect(said("I ran a 5K today.") == "I ran a 5 K today.")
        #expect(said("5K") == "5 K")
        // What was heard as "five ten thousand": each K had been written out as "thousand".
        #expect(said("5K, 10K, half marathon.") == "5 K, 10 K, half marathon.")
        #expect(said("From 5K to 10K.") == "From 5 K to 10 K.")
        #expect(said("A 5-10K week.") == "A 5 to 10 K week.")
        #expect(said("The 5K's start line.") == "The 5 K's start line.")
        #expect(said("Shot in 4K on a 1.5k budget.") == "Shot in 4 K on a 1.5 K budget.")
        #expect(!said("My first 5K and 10K.").contains("thousand"))
        // M and B are left as they are written: the voice says the letter.
        #expect(said("They have 5M users and 3B views.") == "They have 5M users and 3B views.")
        // A plural is already said "five Ks".
        #expect(said("Two 5Ks this month.") == "Two 5Ks this month.")
        // A size is still a size.
        #expect(said("A 5 KB file and a 3 MB one.") == "A 5 kilobytes file and a 3 megabytes one.")
    }

    @Test func moneyWithKMOrBIsExpanded() {
        #expect(said("It cost $5K.") == "It cost 5 thousand dollars.")
        #expect(said("It cost $5k.") == "It cost 5 thousand dollars.")
        #expect(said("The fund raised $3M and then $2B.") == "The fund raised 3 million dollars and then 2 billion dollars.")
        #expect(said("A $1.5M round.") == "A 1.5 million dollars round.")
        #expect(said("£5K or €2M") == "5 thousand pounds or 2 million euros")
        // Money without a letter is the voice's own to read.
        #expect(said("It cost $5,000.") == "It cost $5,000.")
    }

    @Test func numbersInOddShapes() {
        #expect(said("The screen is 1920x1080.") == "The screen is 1920 by 1080.")
        #expect(said("Revenue grew 3x.") == "Revenue grew 3 times.")
        #expect(said("Version 2.0.1 is out.") == "Version 2 point 0 point 1 is out.")
        #expect(said("Call 555-0199 today.") == "Call 5 5 5, 0 1 9 9 today.")
        #expect(said("Call 415-555-0199.") == "Call 4 1 5, 5 5 5, 0 1 9 9.")
        #expect(said("Due 2026-11-15.") == "Due November 15, 2026.")
        #expect(said("It sold for $400K, then $3B.") == "It sold for 400 thousand dollars, then 3 billion dollars.")
        #expect(said("About 12k people came.") == "About 12 K people came.")
        #expect(said("Ships at 9am, closes at 5:30PM.") == "Ships at 9 A M, closes at 5:30 P M.")
        #expect(said("It has 10^6 items for USD 1,199.") == "It has 10 to the power of 6 items for 1,199 U.S. dollars.")
        #expect(said("The ratio is 3:1.") == "The ratio is 3 to 1.")
        #expect(said("Meet at 5:30.") == "Meet at 5:30.")
        #expect(said("Read pages 12-15 and items 10–20.") == "Read pages 12 to 15 and items 10 to 20.")
        #expect(said("Room 20-15 and code 12-0034 stay.") == "Room 20-15 and code 12-0034 stay.")
        #expect(said("See No. 5 and #7.") == "See number 5 and number 7.")
    }

    @Test func abbreviations() {
        #expect(said("St. Louis is on Main St. near 5th Ave.") == "St. Louis is on Main Street near 5th Avenue")
        #expect(said("See fig. 3 and pp. 10–12, approx. half.") == "See figure 3 and pages 10 to 12, approximately half.")
    }

    @Test func markdownMarksAreNotRead() {
        #expect(said("## Plan for the launch") == "Plan for the launch")
        #expect(said("- First item in a list") == "First item in a list")
        #expect(said("- [x] Done already") == "Done already")
        #expect(said("This is **bold**, _quiet_ and `code`.") == "This is bold, quiet and code.")
        #expect(said("Read [the docs](https://example.com/a) first.") == "Read the docs first.")
        #expect(said("> A quoted line") == "A quoted line")
        #expect(said("Name | Role") == "Name, Role")
        #expect(said("snake_case_name stays, and 2 * 3 too") == "snake_case_name stays, and 2 * 3 too")
    }

    @Test func symbols() {
        #expect(said("Settings → Sound, about ~5 minutes w/o help") == "Settings to Sound, about 5 minutes without help")
        #expect(said("Open 24/7 🎉") == "Open twenty-four seven")
        #expect(said("Salt & pepper") == "Salt and pepper")
    }

    @Test func romanNumeralsAfterACue() {
        #expect(said("Chapter IV covers World War II.") == "Chapter 4 covers World War 2.")
        #expect(said("Henry VIII and Super Bowl LVIII") == "Henry the eighth and Super Bowl 58")
        #expect(said("I think John I met was at IBM, in the mix.") == "I think John I met was at IBM, in the mix.")
        #expect(said("Vitamin C and the CIVIC center, Part MIX") == "Vitamin C and the CIVIC center, Part MIX")
    }

    @Test func accentsAndMoreAbbreviations() {
        #expect(said("The naïve café owner sent a résumé.") == "The naive cafay owner sent a resumay.")
        #expect(said("Meet Prof. Kim in Rm. 204 on Fri. with Bob Sr.") == "Meet Professor Kim in Room 204 on Friday with Bob Senior")
        #expect(said("Growth was 12% YoY.") == "Growth was 12% year over year.")
    }

    @Test func ordinaryProseIsUntouched() {
        let text = "The quarterly planning notes are attached. Please read them before Friday, and reply by email."
        #expect(said(text) == text)
    }
}

@Suite struct ReadingPauseTests {
    @Test func paragraphsAndHeadingsGetLongerPauses() {
        let text = "Plan for the launch\n\nFirst we ship. Then we rest! What next?\n\nThe end."
        let sentences = ReadingText.sentences(text)
        let pauses = sentences.indices.map { ReadingText.pause(after: $0, in: sentences) }
        #expect(sentences.map(\.text.count).count == 5)
        #expect(pauses[0] == 0.75)  // a heading
        #expect(pauses[1] == 0.26)  // a sentence inside a paragraph
        #expect(pauses[2] == 0.32)  // an exclamation
        #expect(pauses[3] == 0.6)   // the end of a paragraph
    }
}
