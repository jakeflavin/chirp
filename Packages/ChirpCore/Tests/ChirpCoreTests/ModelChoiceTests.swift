import Testing
@testable import ChirpCore

@Suite struct ModelChoiceTests {
    let gb: UInt64 = 1_073_741_824

    @Test func smallMacsGetTheSmallModel() {
        #expect(LanguageModelSize.recommended(memoryBytes: 8 * gb) == .small)
        #expect(LanguageModelSize.recommended(memoryBytes: 12 * gb) == .small)
    }

    @Test func sixteenGigabytesAndUpGetTheMediumModel() {
        #expect(LanguageModelSize.recommended(memoryBytes: 16 * gb) == .medium)
        #expect(LanguageModelSize.recommended(memoryBytes: 18 * gb) == .medium)
        #expect(LanguageModelSize.recommended(memoryBytes: 64 * gb) == .medium)
    }

    @Test func aChoiceOverridesTheRecommendation() {
        #expect(LanguageModelSize.resolve(choice: "large", memoryBytes: 8 * gb) == .large)
        #expect(LanguageModelSize.resolve(choice: nil, memoryBytes: 8 * gb) == .small)
        #expect(LanguageModelSize.resolve(choice: "nonsense", memoryBytes: 32 * gb) == .medium)
    }

    @Test func comfortIsJudgedAgainstMemory() {
        #expect(LanguageModelSize.large.isComfortable(memoryBytes: 24 * gb))
        #expect(!LanguageModelSize.large.isComfortable(memoryBytes: 16 * gb))
        #expect(!LanguageModelSize.medium.isComfortable(memoryBytes: 8 * gb))
        #expect(LanguageModelSize.large.smaller == .medium)
        #expect(LanguageModelSize.small.smaller == nil)
    }
}
