import Foundation
import Testing

@testable import ChirpCore

@Suite struct RecordingLinesTests {
    func words(_ text: String, from start: Double, each: Double = 0.4) -> [SaidWord] {
        text.split(separator: " ").enumerated().map { i, w in
            SaidWord(text: String(w), start: start + Double(i) * each, end: start + Double(i) * each + each * 0.9)
        }
    }

    @Test func aLineNeverHoldsTwoPeoplesTurns() {
        let said = words("Shall we ship on Friday?", from: 0) + words("Yes, Friday works for me.", from: 2.1)
        let turns = [SpeakerTurn(speaker: "a", start: 0, end: 2.05), SpeakerTurn(speaker: "b", start: 2.05, end: 4.2)]
        let lines = MeetingText.lines(from: said, turns: turns)
        #expect(lines.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(lines.map(\.text) == ["Shall we ship on Friday?", "Yes, Friday works for me."])
        #expect(abs(lines[1].start - 2.1) < 0.001)
    }

    @Test func oneVoiceStaysOnePersonAndBreaksAtPauses() {
        let said = words("First thought.", from: 0) + words("Second thought, later.", from: 5)
        let lines = MeetingText.lines(from: said, turns: [SpeakerTurn(speaker: "a", start: 0, end: 7)])
        #expect(lines.map(\.speaker) == ["Me", "Me"])
        #expect(lines.map(\.text) == ["First thought.", "Second thought, later."])
    }

    @Test func aStrayWordInsideASentenceGoesBackToItsSpeaker() {
        let said = words("We should move the launch to March", from: 0)
        // The speaker step hears somebody else for one word in the middle.
        let turns = [
            SpeakerTurn(speaker: "a", start: 0, end: 1.2), SpeakerTurn(speaker: "b", start: 1.2, end: 1.6),
            SpeakerTurn(speaker: "a", start: 1.6, end: 3), SpeakerTurn(speaker: "b", start: 10, end: 20),
        ]
        let lines = MeetingText.lines(from: said, turns: turns)
        #expect(lines.count == 1)
        #expect(lines[0].speaker == "Speaker 1")
    }
}
