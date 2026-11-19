import Foundation
import Testing

@testable import ChirpCore

@Suite struct RecordingGapsTests {
    @Test func whatNoLineCoversIsFound() {
        let lines = [
            TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 10, text: "a"),
            TranscriptSegment(itemID: 0, speaker: "Me", start: 10.2, end: 20, text: "b"),
            TranscriptSegment(itemID: 0, speaker: "Me", start: 40, end: 50, text: "c"),
        ]
        let gaps = MeetingText.uncovered(samples: 100 * 16_000, lines: lines)
        #expect(gaps == [20 * 16_000..<40 * 16_000, 50 * 16_000..<100 * 16_000])
        #expect(MeetingText.uncovered(samples: 0, lines: []).isEmpty)
        #expect(MeetingText.uncovered(samples: 8 * 16_000, lines: []) == [0..<8 * 16_000])
    }
}
