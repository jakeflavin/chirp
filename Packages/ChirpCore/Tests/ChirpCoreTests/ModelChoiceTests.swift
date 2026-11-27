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

@Suite struct MacMemoryTests {
    let gb: UInt64 = 1_073_741_824

    @Test func onlySmallMacsKeepOneHeavyModel() {
        #expect(MacMemory.keepsOneHeavyModel(memoryBytes: 8 * gb))
        #expect(!MacMemory.keepsOneHeavyModel(memoryBytes: 12 * gb))
        #expect(!MacMemory.keepsOneHeavyModel(memoryBytes: 16 * gb))
    }

    @Test func deeperChecksEverywhereFollowTheMediumModel() {
        for memory in [8, 12, 15, 16, 24, 64].map({ UInt64($0) * gb }) {
            #expect(MacMemory.deepChecksEverywhereByDefault(memoryBytes: memory) == (LanguageModelSize.recommended(memoryBytes: memory) == .medium))
        }
        // A 16 GB Mac that reports a little less still counts.
        #expect(MacMemory.deepChecksEverywhereByDefault(memoryBytes: 16 * gb - 200_000_000))
        #expect(!MacMemory.deepChecksEverywhereByDefault(memoryBytes: 8 * gb))
    }

    @Test func eachSizeNamesItsOwnModel() {
        #expect(Set(LanguageModelSize.allCases.map(\.modelID)).count == LanguageModelSize.allCases.count)
        #expect(MacMemory.wholeGigabytes(16 * gb - 1000) == 16)
    }
}

@Suite struct HubReferenceTests {
    @Test func aReferenceSplitsIntoRepoAndRevision() {
        let pinned = HubReference.split("mlx-community/Qwen3.5-2B-MLX-4bit@93760be4f1f69842a46bc13dbdc0f19e291392a3")
        #expect(pinned.repo == "mlx-community/Qwen3.5-2B-MLX-4bit")
        #expect(pinned.revision == "93760be4f1f69842a46bc13dbdc0f19e291392a3")
        #expect(HubReference.split("BAAI/bge-small-en-v1.5").revision == nil)
        #expect(HubReference.split("BAAI/bge-small-en-v1.5@").revision == nil)
    }

    @Test func everyLanguageSizeIsPinnedToACommit() {
        for size in LanguageModelSize.allCases {
            #expect(size.revision.count == 40 && size.revision.allSatisfy(\.isHexDigit), "\(size)")
            let back = HubReference.split(size.hubReference)
            #expect(back.repo == size.modelID && back.revision == size.revision)
        }
    }
}
