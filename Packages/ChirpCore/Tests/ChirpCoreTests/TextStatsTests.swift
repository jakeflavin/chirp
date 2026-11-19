import Foundation
import Testing

@testable import ChirpCore

@Suite struct TextStatsTests {
    @Test func wordsAreCountedBetweenSpacesTabsAndLineBreaks() {
        #expect(TextStats.words("one two\tthree\nfour  five") == 5)
        #expect(TextStats.words("   ") == 0)
    }

    @Test func aFileNameHasNoSlashOrColonAndFallsBackWhenEmpty() {
        #expect(TextStats.fileName("Plan: 2/3 done") == "Plan- 2-3 done")
        #expect(TextStats.fileName(String(repeating: "a", count: 100), limit: 60).count == 60)
        #expect(TextStats.fileName("   ", fallback: "Note") == "Note")
    }

    @Test func floatsSurviveTheTripToBytesAndBack() {
        let values: [Float] = [1.5, -2, 0.25]
        #expect(Data(floats: values).floats == values)
        #expect(Data([0x01, 0x02]).floats.isEmpty)
    }
}
