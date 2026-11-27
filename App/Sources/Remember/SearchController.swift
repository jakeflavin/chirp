import ChirpCore
import ChirpML
import Observation
import SwiftUI

/// Search across everything saved, by words and by meaning. It uses the small search model only, never
/// the language model.
@MainActor
@Observable
final class SearchController {
    /// What is typed in the search field.
    var query = ""
    /// The kinds of item to search. Empty means all of them.
    var kinds: Set<ItemKind> = []
    /// What the last search found, best first.
    private(set) var results: [SemanticSearch.Result] = []
    /// True from the first keystroke until the matches by meaning are in.
    private(set) var searching = false
    /// How many items still need to be read for search by meaning.
    private(set) var pendingIndex = 0
    /// True while saved items are being read for search by meaning.
    private(set) var indexing = false

    private let app: AppModel
    private let models: ModelCenter
    let library: Library
    /// The small model that turns a passage or a query into numbers that can be compared by meaning.
    private let embedder = Embedder()
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    /// The closest passages to the last query with their scores, for tests to read back.
    private var lastScores: [String] = []
    /// How long the last pieces of work took, in seconds, for tests to read back: preparing the index,
    /// turning the last query into numbers (the search model's part), and the last search from the
    /// pause in typing to its results.
    private var lastIndexSeconds = 0.0
    private var lastEmbedSeconds = 0.0
    private var lastSearchSeconds = 0.0

    init(app: AppModel, models: ModelCenter) {
        self.app = app
        self.models = models
        library = Library(store: app.store)
        let embedder = embedder
        models.register(
            .search, onDisk: { ModelCenter.hubModelExists(Embedder.modelID) },
            load: { progress in try await embedder.load(progress: progress) }, unload: { await embedder.unload() })
        pendingIndex = (try? library.countItemsNeedingChunks()) ?? 0

        LinkHandler.commands["search"] = { [weak self] q in
            self?.query = q["q"] ?? ""
            self?.search()
        }
        LinkHandler.commands["search-index"] = { [weak self] _ in self?.buildIndex() }
        LinkHandler.stateProviders["search"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "query": self.query, "results": self.results.map { "\($0.item.kind.rawValue): \($0.item.title)" },
                "snippets": self.results.map(\.snippet), "searching": self.searching, "pending": self.pendingIndex,
                "indexing": self.indexing, "scores": self.lastScores, "chunks": (try? self.library.chunks().count) ?? 0,
                "indexSeconds": self.lastIndexSeconds, "embedSeconds": self.lastEmbedSeconds, "searchSeconds": self.lastSearchSeconds,
            ]
        }
    }

    /// Whether search by meaning is available (the small search model is on disk).
    var meaningAvailable: Bool { models.state(.search) != .notDownloaded }

    // MARK: Index

    /// Reads any items not yet prepared for search by meaning. Downloads the search model on first use.
    func buildIndex() {
        guard indexTask == nil else { return }
        indexing = true
        let started = Date()
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.lastIndexSeconds = Date().timeIntervalSince(started)
                self.indexing = false
                self.indexTask = nil
            }
            do {
                try await self.models.ensure(.search)
                let items = try self.library.itemsNeedingChunks()
                self.pendingIndex = items.count
                for item in items {
                    guard let id = item.id else { continue }
                    let segments = (try? self.library.segments(itemID: id)) ?? []
                    // Each part is split on its own, so a passage never mixes the transcript with generated notes.
                    let passages = Library.searchableParts(item, segments: segments).flatMap { SemanticSearch.passages($0) }
                    guard !passages.isEmpty else {
                        // Nothing in it to search by meaning. An empty passage is kept as a note that it
                        // has been looked at, so it is not counted as new again every time. (Passages
                        // with no numbers are never searched.)
                        try self.library.replaceChunks(itemID: id, with: [Chunk(itemID: id, offset: 0, text: "", embedding: Data())])
                        self.pendingIndex -= 1
                        continue
                    }
                    let vectors = try await self.embedder.embed(passages.map(\.text))
                    // Reading it took a while. If the item was deleted meanwhile there is nothing to keep;
                    // if its text changed, what was read is out of date and it is left for the next pass.
                    guard let now = try self.library.item(id) else {
                        self.pendingIndex -= 1
                        continue
                    }
                    guard now.body == item.body, now.rawText == item.rawText, now.summary == item.summary else { continue }
                    let chunks = zip(passages, vectors).map {
                        Chunk(itemID: id, offset: $0.offset, text: $0.text, embedding: SemanticSearch.data($1))
                    }
                    try self.library.replaceChunks(itemID: id, with: chunks)
                    self.pendingIndex -= 1
                }
                // Counted again, not set to zero: items whose text changed while they were read are still waiting.
                self.refreshPending()
                if !self.query.isEmpty { self.search() }
            } catch {
                self.app.report(error, doing: "prepare search by meaning")
            }
        }
    }

    // MARK: Search

    /// Searches for `query` once typing pauses, dropping any search still under way. Matching words
    /// show first and matches by meaning join them.
    func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            // Wait for typing to pause.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let started = Date()
            // Exact-word matches are instant, so show them at once; matches by meaning join them when the
            // search model has loaded, which can take several seconds the first time. The word matches
            // are looked up once and used for both.
            let filter = self.kinds.isEmpty ? nil : Array(self.kinds)
            let keyword = (try? self.library.search(q, kinds: filter, limit: 40)) ?? []
            let quick = await self.find(q, limit: 30, keyword: keyword, filter: filter, byMeaning: false)
            guard !Task.isCancelled else { return }
            self.results = quick
            let found = await self.find(q, limit: 30, keyword: keyword, filter: filter)
            guard !Task.isCancelled else { return }
            self.results = found
            self.lastSearchSeconds = Date().timeIntervalSince(started)
            self.searching = false
        }
    }

    /// The keyword hits already found (`keyword`, for the kinds in `filter`) fused with meaning hits,
    /// when the search model is loaded.
    private func find(
        _ q: String, limit: Int, keyword: [Library.Hit], filter: [ItemKind]?, byMeaning: Bool = true
    ) async -> [SemanticSearch.Result] {
        var semantic: [SemanticSearch.PassageHit] = []
        var items: [Int64: SavedItem] = [:]
        // With every feature that saves items switched off, the search model stays put away.
        let wanted = byMeaning && Features.shared.set.needs(.search)
        var ready = wanted && models.state(.search) == .loaded
        if wanted, !ready, meaningAvailable { ready = (try? await models.ensure(.search)) != nil }
        let asked = Date()
        if ready {
            let vector = try? await embedder.embed([q], asQuery: true).first
            lastEmbedSeconds = Date().timeIntervalSince(asked)
            if let vector, let chunks = try? library.chunks() {
                // Only automated runs read the scores back, so they are only worked out for them.
                if LinkHandler.debugEnabled {
                    lastScores = SemanticSearch.nearest(vector, in: chunks, limit: 30, minimum: 0).map { "\(String(format: "%.2f", $0.score)) \($0.chunk.text.prefix(30))" }
                }
                semantic = SemanticSearch.nearest(vector, in: chunks, limit: 30, minimum: 0.48)
                for id in Set(semantic.map(\.chunk.itemID)) {
                    if let item = try? library.item(id), filter?.contains(item.kind) ?? true { items[id] = item }
                }
            }
        }
        for hit in keyword { if let id = hit.item.id { items[id] = hit.item } }
        return SemanticSearch.fuse(keyword: keyword, semantic: semantic, items: items, limit: limit)
    }

    /// Counts again how many items still need reading for search by meaning.
    func refreshPending() { pendingIndex = (try? library.countItemsNeedingChunks()) ?? 0 }
}
