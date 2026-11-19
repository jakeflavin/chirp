import Foundation

/// Search by meaning: stores a vector per passage and compares them directly. A personal library is
/// small enough (tens of thousands of passages) that this takes milliseconds without a vector index.
public enum SemanticSearch {
    /// A vector as the bytes stored with a passage.
    public static func data(_ vector: [Float]) -> Data { Data(floats: vector) }

    /// The vector stored in `data`.
    public static func vector(_ data: Data) -> [Float] { data.floats }

    /// Dot product; for unit-length vectors this is the cosine similarity.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// Splits an item's searchable text into overlapping passages for embedding.
    public static func passages(_ text: String, size: Int = 700) -> [(offset: Int, text: String)] {
        var out: [(Int, String)] = []
        var offset = 0
        let ns = text as NSString
        for piece in TextChunker.chunks(text, maxCharacters: size) {
            // Find where this piece starts so a hit can point back into the text.
            let range = ns.range(of: String(piece.prefix(40)), options: [], range: NSRange(location: offset, length: ns.length - offset))
            let start = range.location == NSNotFound ? offset : range.location
            out.append((start, piece))
            offset = min(ns.length, start + 1)
        }
        return out
    }

    /// A passage with how close it is to the query (1 is the same meaning).
    public struct PassageHit: Sendable, Equatable {
        public var chunk: Chunk
        public var score: Float

        public static func == (a: PassageHit, b: PassageHit) -> Bool { a.chunk.id == b.chunk.id && a.score == b.score }
    }

    /// The passages closest in meaning to the query vector.
    public static func nearest(_ query: [Float], in chunks: [Chunk], limit: Int = 20, minimum: Float = 0.35) -> [PassageHit] {
        chunks.map { PassageHit(chunk: $0, score: similarity(query, vector($0.embedding))) }
            .filter { $0.score >= minimum }
            .sorted { $0.score > $1.score }
            .prefix(limit).map { $0 }
    }

    /// One search result: an item with the passage that best explains why it matched.
    public struct Result: Sendable, Identifiable {
        public var item: SavedItem
        public var snippet: String
        /// Offset of the matching passage in the item's searchable text, when known.
        public var offset: Int?
        public var score: Double
        public var id: Int64 { item.id ?? 0 }
    }

    /// Merges keyword hits and meaning hits into one ranking (reciprocal rank fusion): an item that
    /// both lists agree on rises to the top.
    public static func fuse(keyword: [Library.Hit], semantic: [PassageHit], items: [Int64: SavedItem], limit: Int = 30) -> [Result] {
        var scores: [Int64: Double] = [:]
        var snippets: [Int64: (String, Int?)] = [:]
        for (rank, hit) in keyword.enumerated() {
            guard let id = hit.item.id else { continue }
            scores[id, default: 0] += 1.0 / Double(60 + rank)
            snippets[id] = (hit.snippet, nil)
        }
        var seen = Set<Int64>()
        var rank = 0
        for hit in semantic {
            let id = hit.chunk.itemID
            guard items[id] != nil, seen.insert(id).inserted else { continue }
            scores[id, default: 0] += 1.0 / Double(60 + rank)
            rank += 1
            if snippets[id] == nil {
                let text = hit.chunk.text
                snippets[id] = (text.count > 220 ? String(text.prefix(220)) + "…" : text, hit.chunk.offset)
            }
        }
        // Equal scores are common (first in one list against first in the other). They go keyword match
        // first, then newest, so the same search gives the same order every time.
        let matchedWords = Set(keyword.compactMap(\.item.id))
        let ranked = scores.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            let aMatched = matchedWords.contains(a.key), bMatched = matchedWords.contains(b.key)
            return aMatched != bMatched ? aMatched : a.key > b.key
        }
        return ranked.prefix(limit).compactMap { id, score in
            guard let item = items[id] ?? keyword.first(where: { $0.item.id == id })?.item else { return nil }
            let s = snippets[id]
            return Result(item: item, snippet: s?.0 ?? "", offset: s?.1, score: score)
        }
    }

    /// The numbered passages given to the language model to answer a question from the user's notes.
    public static func askContext(question: String, passages: [(title: String, text: String)]) -> String {
        var s = "QUESTION: \(question)\n\nPASSAGES FROM MY NOTES:\n"
        for (i, p) in passages.enumerated() {
            s += "[\(i + 1)] (\(p.title)) \(p.text)\n\n"
        }
        return s
    }
}
