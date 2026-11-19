import Foundation
import Testing

@testable import ChirpCore

/// When each word shown is spoken, from the voice's own lengths for its sounds.
struct WordTimingTests {
    /// Durations in frames for "ab cd": start mark, a, b, space, c, d, end mark.
    @Test func spansCountFromTheStartOfTheAudioAndShareTheGap() throws {
        let spans = try #require(WordTiming.spans(phonemes: "ab cd", durations: [13, 4, 4, 2, 6, 6, 9]))
        #expect(spans.count == 2)
        // The opening silence is 13 frames; the first word starts 3 frames before it ends.
        #expect(abs(spans[0].start - 10.0 / 40) < 1e-9)
        // Half the 2-frame gap goes to each word.
        #expect(abs(spans[0].end - 19.0 / 40) < 1e-9)
        #expect(spans[1].start == spans[0].end)
        #expect(abs(spans[1].end - 32.0 / 40) < 1e-9)
    }

    @Test func spansAreNilWhenTheLengthsDoNotLineUp() {
        #expect(WordTiming.spans(phonemes: "ab cd", durations: [1, 2, 3]) == nil)
        #expect(WordTiming.spans(phonemes: "", durations: [1, 1]) == nil)
    }

    private func spans(_ n: Int) -> [SpokenSpan] { (0..<n).map { SpokenSpan(start: Double($0), end: Double($0) + 1) } }

    @Test func sameWordsAreTimedOneToOne() throws {
        let t = try #require(WordTiming.wordTimings(sentence: "Hello, big world.", spokenText: "Hello, big world.", spans: spans(3)))
        #expect(t.map(\.start) == [0, 1, 2])
        #expect(t.map(\.end) == [1, 2, 3])
    }

    @Test func aNumberSharesTheTimeOfItsSpokenWords() throws {
        // "$45" is said as three words; the words after it keep their own times.
        let t = try #require(WordTiming.wordTimings(sentence: "It costs $45 today", spokenText: "It costs forty five dollars today", spans: spans(6)))
        #expect(t.count == 4)
        #expect(t[1].start == 1 && t[1].end == 2)
        #expect(t[2].start == 2 && t[2].end == 5)
        #expect(t[3].start == 5 && t[3].end == 6)
    }

    @Test func twoShownWordsShareWhatWasSaidForThem() throws {
        // "25 s" becomes "twenty five seconds".
        let t = try #require(WordTiming.wordTimings(sentence: "Wait 25 s now", spokenText: "Wait twenty five seconds now", spans: spans(5)))
        #expect(t[1].start == 1)
        #expect(t[2].end == 4)
        #expect(t[1].end == t[2].start)
        #expect(t[3].start == 4)
    }

    @Test func aWordThatIsNotSaidTakesNoTime() throws {
        let t = try #require(WordTiming.wordTimings(sentence: "Birds sing [3] loudly", spokenText: "Birds sing loudly", spans: spans(3)))
        #expect(t[2].start == t[2].end)
        #expect(t[3].start == 2 && t[3].end == 3)
        // The word being said is found past the one with no time.
        #expect(ReadingText.wordIndex(at: 2.5, in: t) == 3)
    }

    @Test func lettersSpelledOutAreOneWord() throws {
        // "FBI" is said as three groups of sounds.
        let t = try #require(WordTiming.wordTimings(sentence: "The FBI came", spokenText: "The FBI came", spans: spans(5)))
        #expect(t[1].start == 1 && t[1].end == 4)
        #expect(t[2].start == 4)
    }

    @Test func aMarkOnItsOwnIsNotASpokenWord() throws {
        let t = try #require(WordTiming.wordTimings(sentence: "Yes — no", spokenText: "Yes — no", spans: spans(2)))
        #expect(t.count == 3)
        #expect(t[0].start == 0)
        #expect(t[2].start == 1 && t[2].end == 2)
    }

    @Test func nilWhenTheSpokenWordsCannotBeCounted() {
        #expect(WordTiming.wordTimings(sentence: "One two three", spokenText: "One two three", spans: spans(2)) == nil)
        #expect(WordTiming.wordTimings(sentence: "", spokenText: "x", spans: spans(1)) == nil)
    }

    @Test func timesNeverGoBackwards() throws {
        let t = try #require(WordTiming.wordTimings(sentence: "a b c d e", spokenText: "x a y c z e", spans: spans(6)))
        for (one, next) in zip(t, t.dropFirst()) { #expect(next.start >= one.end - 1e-9) }
    }

    /// A sentence that opens with a quotation mark: the voice writes the mark as a group of its own.
    /// It is not a word, and the words after it keep the voice's own times.
    @Test func aQuotationMarkOnItsOwnIsNotAWord() {
        let sounds = "“ wAt,” ʃi sɛd"
        // One length a sound, with the start and end marks: every sound 2 frames, spaces 1.
        let durations: [Int32] = [4] + sounds.unicodeScalars.map { $0 == " " ? 1 : 2 } + [4]
        let spans = WordTiming.spans(phonemes: sounds, durations: durations)
        #expect(spans?.count == 3)
        let timed = WordTiming.wordTimings(sentence: "“Wait,” she said", spokenText: "“Wait,” she said", spans: spans ?? [])
        #expect(timed?.count == 3)
        // "she" starts where the voice says it does, not a third of the way through.
        if let timed, let spans { #expect(abs(timed[1].start - spans[1].start) < 0.001) }
    }
}
