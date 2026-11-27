import Foundation
import Testing

@testable import ChirpCore

@Suite struct SemanticSearchTests {
    @Test func vectorsRoundTripThroughData() {
        let v: [Float] = [0.25, -1, 3.5]
        #expect(SemanticSearch.vector(SemanticSearch.data(v)) == v)
        #expect(SemanticSearch.similarity([1, 0], [0, 1]) == 0)
        #expect(SemanticSearch.similarity([0.6, 0.8], [0.6, 0.8]) == 1)
    }

    @Test func passagesKeepOffsets() {
        let text = (1...30).map { "Sentence number \($0) talks about topic \($0)." }.joined(separator: " ")
        let passages = SemanticSearch.passages(text, size: 200)
        #expect(passages.count > 3)
        let ns = text as NSString
        for p in passages {
            #expect(ns.substring(from: p.offset).hasPrefix(String(p.text.prefix(30))))
        }
    }

    @Test func nearestRanksAndFilters() {
        let chunks = [
            Chunk(id: 1, itemID: 10, offset: 0, text: "budget", embedding: SemanticSearch.data([1, 0])),
            Chunk(id: 2, itemID: 11, offset: 0, text: "birds", embedding: SemanticSearch.data([0, 1])),
            Chunk(id: 3, itemID: 12, offset: 0, text: "costs", embedding: SemanticSearch.data([0.8, 0.6])),
        ]
        let hits = SemanticSearch.nearest([1, 0], in: chunks)
        #expect(hits.map(\.chunk.id) == [1, 3])
    }

    @Test func fusionPrefersItemsBothListsAgreeOn() throws {
        let lib = Library(store: try ChirpStore())
        let a = try lib.save(SavedItem(kind: .meeting, title: "Budget review", body: "We approved the budget."))
        let b = try lib.save(SavedItem(kind: .note, title: "Costs", body: "Spending went up this quarter."))
        let c = try lib.save(SavedItem(kind: .document, title: "Birds", body: "The budget of a bird's day."))
        let keyword = try lib.search("budget")
        #expect(Set(keyword.map(\.id)) == [a.id!, c.id!])
        let semantic = [
            SemanticSearch.PassageHit(chunk: Chunk(id: 1, itemID: b.id!, offset: 0, text: "Spending went up this quarter."), score: 0.8),
            SemanticSearch.PassageHit(chunk: Chunk(id: 2, itemID: a.id!, offset: 0, text: "We approved the budget."), score: 0.7),
        ]
        let items = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.id!, $0) })
        let results = SemanticSearch.fuse(keyword: keyword, semantic: semantic, items: items)
        #expect(results.first?.id == a.id)
        #expect(Set(results.map(\.id)) == [a.id!, b.id!, c.id!])
        #expect(results.first { $0.id == b.id }?.snippet == "Spending went up this quarter.")
    }

    @Test func chunksAreStoredAndListed() throws {
        let lib = Library(store: try ChirpStore())
        let m = try lib.save(SavedItem(kind: .meeting, title: "Sync", body: "notes"))
        try lib.save(SavedItem(kind: .dictation, body: "a dictation is not indexed for meaning"))
        #expect(try lib.itemsNeedingChunks().map(\.id) == [m.id])
        try lib.replaceChunks(itemID: m.id!, with: [Chunk(itemID: 0, offset: 0, text: "notes", embedding: SemanticSearch.data([1, 0]))])
        #expect(try lib.itemsNeedingChunks().isEmpty)
        #expect(try lib.chunks().count == 1)
        try lib.delete(m)
        #expect(try lib.chunks().isEmpty)
    }
}

@Suite struct TranscriptSearchTests {
    @Test func aWordOnlySaidInAMeetingIsFound() throws {
        let lib = Library(store: try ChirpStore())
        let meeting = try lib.save(SavedItem(kind: .meeting, title: "Weekly sync", summary: "## Summary\n- We talked about the launch."))
        let other = try lib.save(SavedItem(kind: .meeting, title: "Planning", summary: "## Summary\n- Budget."))
        try lib.replaceSegments(
            itemID: meeting.id!,
            with: [
                TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 4, text: "Shall we start with the launch?"),
                TranscriptSegment(itemID: 0, speaker: "Them", start: 4, end: 9, text: "Yes. The zeppelin vendor wants a deposit by Friday."),
            ])
        try lib.replaceSegments(itemID: other.id!, with: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 2, text: "Nothing about airships.")])
        // In no title, note or summary: only in what was said.
        let hits = try lib.search("zeppelin")
        #expect(hits.map(\.id) == [meeting.id!])
        #expect(hits.first?.snippet.contains("«zeppelin»") == true)
        // Words from two different lines of the same recording.
        #expect(try lib.search("launch deposit").map(\.id) == [meeting.id!])
        // Found by its summary and by its transcript: listed once, with the summary's excerpt.
        #expect(try lib.search("launch").map(\.id) == [meeting.id!])
        #expect(try lib.search("zeppelin", kinds: [.voiceNote]).isEmpty)
    }

    @Test func theIndexFollowsTheTranscript() throws {
        let lib = Library(store: try ChirpStore())
        let meeting = try lib.save(SavedItem(kind: .meeting, title: "Sync"))
        try lib.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 2, text: "The marmalade budget.")])
        #expect(try lib.search("marmalade").count == 1)
        try lib.replaceSegments(itemID: meeting.id!, with: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 2, text: "The jam budget.")])
        #expect(try lib.search("marmalade").isEmpty)
        #expect(try lib.search("jam").count == 1)
        try lib.delete(meeting)
        #expect(try lib.search("jam").isEmpty)
    }
}
