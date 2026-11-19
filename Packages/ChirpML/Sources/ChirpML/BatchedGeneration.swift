import Foundation
import MLX
import MLXLMCommon
import Tokenizers

// Several requests written in one pass of the one loaded model, as mlx-lm's `batch_generate` does. Writing an
// answer is limited by reading the model's weights once per word, not by arithmetic, so writing four answers at
// once costs little more than writing one.
//
// mlx-swift-lm has no batched decoding yet (its stack #771 / #773 / #775 / #777 / #785 is open), so this is
// the minimal part of mlx-lm's design (`mlx_lm/generate.py` `_merge_caches`, `mlx_lm/models/cache.py` `BatchKVCache`,
// `ArraysCache.merge`, at c4c9c762): each prompt is read on its own into its own cache, the caches are
// merged into one batch (the attention layers' keys left-padded to the same length with a mask over the padding and each
// row's own position for RoPE; the recurrent layers' fixed-size states stacked), and the batch is decoded together
// greedily. A row that finishes is taken out of the batch. Only the cache kinds Qwen3.5 uses are handled (Qwen3 uses
// only the first of them); any other makes the caller fall back to one request at a time.

/// One request in a batch: the same as a `LanguageRunRequest` without the testing fault.
struct LanguageBatchItem: Codable, Sendable {
    var instructions: String
    var text: String
    var maxTokens: Int
}

/// The payload of a `runBatch` message.
struct LanguageBatchRequest: Codable, Sendable {
    var items: [LanguageBatchItem]
    /// Read the start every prompt shares (the standing instruction) once and reuse it, as
    /// mlx-lm's `LRUPromptCache` does, instead of reading it again for every part.
    var sharePrefix = true
}

/// The shared start of the prompts read last, kept for the next batch. Only touched inside the model container.
final class PromptPrefix: @unchecked Sendable {
    var tokens: [Int] = []
    var cache: [KVCache] = []
}

/// The payload of a `batchItem` reply: one request of the batch, finished.
struct LanguageBatchReply: Codable, Sendable {
    var index: Int
    var counted: LanguageModel.Counted
}

enum BatchGenerationError: Error {
    /// The model uses a kind of cache this does not know how to put in a batch.
    case unsupportedCache(String)
}

/// A left-padded batch of attention keys and values, after mlx-lm's `BatchKVCache`. Every row's newest position is in
/// the same column; a row's padding on the left is masked out, and its own length is its RoPE position.
final class PaddedBatchKVCache: BaseKVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    /// Columns of padding at the left of each row, `[B]`.
    private var leftPadding: MLXArray
    /// Each row's own position, `[B]`: its RoPE offset for the next token.
    private var rows: MLXArray
    /// Columns in use, the same for every row.
    private var index: Int
    private let step = 256

    /// Merges single-row caches of different lengths, as `BatchKVCache.merge` does.
    init(merging caches: [KVCacheSimple]) {
        let states = caches.map(\.state)
        let lengths = states.map { $0.first?.dim(2) ?? 0 }
        let longest = lengths.max() ?? 0
        let padding = lengths.map { longest - $0 }
        if let example = states.first(where: { $0.count == 2 }) {
            let rowsKeys = zip(states, padding).map { state, pad -> MLXArray in
                pad == 0 ? state[0] : padded(state[0], left: pad)
            }
            let rowsValues = zip(states, padding).map { state, pad -> MLXArray in
                pad == 0 ? state[1] : padded(state[1], left: pad)
            }
            _ = example
            keys = concatenated(rowsKeys, axis: 0)
            values = concatenated(rowsValues, axis: 0)
        }
        leftPadding = MLXArray(padding.map(Int32.init))
        rows = MLXArray(lengths.map(Int32.init))
        index = longest
        super.init()
        offset = longest
    }

    override var ropeOffset: RoPEOffset { .batch(rows + 0) }

    override func innerState() -> [MLXArray] { [keys, values].compactMap { $0 } }

    override var state: [MLXArray] {
        get { [keys, values].compactMap { $0 }.map { $0[.ellipsis, ..<index, 0...] } }
        set { fatalError("a batch cache is not restored") }
    }

    override func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = index
        if keys == nil || previous + newKeys.dim(2) > keys!.dim(2) {
            let b = newKeys.dim(0), heads = newKeys.dim(1)
            let steps = (step + newKeys.dim(2) - 1) / step
            let grownK = MLXArray.zeros([b, heads, steps * step, newKeys.dim(3)], dtype: newKeys.dtype)
            let grownV = MLXArray.zeros([b, heads, steps * step, newValues.dim(3)], dtype: newValues.dtype)
            if let k = keys, let v = values {
                keys = concatenated([k[.ellipsis, ..<previous, 0...], grownK], axis: 2)
                values = concatenated([v[.ellipsis, ..<previous, 0...], grownV], axis: 2)
            } else {
                keys = grownK
                values = grownV
            }
        }
        index += newKeys.dim(2)
        offset = index
        rows = rows + Int32(newKeys.dim(2))
        keys![.ellipsis, previous ..< index, 0...] = newKeys
        values![.ellipsis, previous ..< index, 0...] = newValues
        return (keys![.ellipsis, ..<index, 0...], values![.ellipsis, ..<index, 0...])
    }

    /// `create_causal_mask(N, offset=_idx, left_padding=…)`: causal over the new positions, and never a row's padding.
    override func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let right = MLXArray(Int32(0) ..< Int32(index + n))[.newAxis]
        let left = MLXArray(Int32(index) ..< Int32(index + n))[0..., .newAxis]
        var mask = left .>= right
        mask = mask & (right .>= leftPadding[0..., .newAxis, .newAxis, .newAxis])
        return .array(mask)
    }

    /// Keeps only the rows at `kept` (mlx-lm's `filter`), and drops padding no row needs any more.
    func filter(_ kept: MLXArray) {
        keys = keys?[kept]
        values = values?[kept]
        leftPadding = leftPadding[kept]
        rows = rows[kept]
        let least = leftPadding.min().item(Int.self)
        if least > 0 {
            keys = keys?[.ellipsis, least..., 0...]
            values = values?[.ellipsis, least..., 0...]
            index -= least
            offset = index
            leftPadding = leftPadding - Int32(least)
        }
    }

    override func copy() -> any KVCache { fatalError("a batch cache is not copied") }
}

/// `x` with `left` zero columns in front of its sequence axis (axis 2).
private func padded(_ x: MLXArray, left: Int) -> MLXArray {
    var shape = x.shape
    shape[2] = left
    return concatenated([MLXArray.zeros(shape, dtype: x.dtype), x], axis: 2)
}

/// Stacks single-row recurrent states (`ArraysCache.merge`).
private func mergedRecurrent(_ caches: [MambaCache]) -> MambaCache {
    let merged = MambaCache()
    for slot in 0 ..< 2 {
        let parts = caches.compactMap { $0[slot] }
        if parts.count == caches.count { merged[slot] = concatenated(parts, axis: 0) }
    }
    return merged
}

extension LanguageEngine {
    /// Writes the answers to several requests in one batch, greedily (temperature 0, as summaries ask). Each answer is
    /// handed to `onFinished` as soon as its row stops, so the first ones can be used while the rest are still being
    /// written. Throws `BatchGenerationError` before writing anything when the model's caches cannot be batched.
    func runBatch(_ items: [LanguageBatchItem], sharePrefix: Bool = true, onFinished: @escaping @Sendable (Int, LanguageModel.Counted) -> Void) async throws {
        guard let container = loadedContainer else { throw LanguageModelError.notLoaded }
        let kept = promptPrefix
        MLX.Memory.peakMemory = 0
        try await container.perform { (context: ModelContext) in
            let model = context.model
            var stops = context.configuration.eosTokenIds
            if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
            for token in context.configuration.extraEOSTokens {
                if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
            }
            // Each prompt read on its own, into its own cache; the start they all share read once (and kept for the next batch).
            var inputs: [[Int]] = []
            for item in items {
                // No instructions: the user's message alone, with no empty system turn (how the TLDR prompt was trained).
                let chat: [Chat.Message] = item.instructions.isEmpty ? [.user(item.text)] : [.system(item.instructions), .user(item.text)]
                let input = try await context.processor.prepare(input: UserInput(
                    chat: chat, additionalContext: ["enable_thinking": false]))
                inputs.append(input.text.tokens.asArray(Int.self))
            }
            var shared = inputs[0]
            for tokens in inputs.dropFirst() {
                var n = 0
                while n < shared.count, n < tokens.count, shared[n] == tokens[n] { n += 1 }
                shared = Array(shared.prefix(n))
            }
            // Never the whole of a prompt: the last token must be read with the rest to give the first word.
            shared = Array(shared.prefix(max(0, (inputs.map(\.count).min() ?? 1) - 1)))
            if !sharePrefix || shared.count < 16 { shared = [] }
            if !shared.isEmpty, kept.tokens != shared {
                let cache = try model.newCache(parameters: nil)
                switch try model.prepare(LMInput(text: .init(tokens: MLXArray(shared.map(Int32.init)))), cache: cache, state: nil, prefill: PrefillParameters()) {
                case .tokens(let rest): _ = model(rest[text: .newAxis], cache: cache, state: nil)
                case .logits: break
                }
                eval(cache.flatMap { $0.innerState() })
                kept.tokens = shared
                kept.cache = cache
            }
            var caches: [[KVCache]] = []
            var first: [Int] = []
            var promptTokens: [Int] = []
            var promptSeconds: [Double] = []
            for tokens in inputs {
                try Task.checkCancellation()
                let began = Date()
                let cache: [KVCache]
                let rest: [Int]
                if !shared.isEmpty {
                    cache = kept.cache.map { $0.copy() }
                    rest = Array(tokens.dropFirst(shared.count))
                } else {
                    cache = try model.newCache(parameters: nil)
                    rest = tokens
                }
                let logits: MLXArray
                switch try model.prepare(LMInput(text: .init(tokens: MLXArray(rest.map(Int32.init)))), cache: cache, state: nil, prefill: PrefillParameters()) {
                case .tokens(let remaining): logits = model.nextTokenLogits(remaining[text: .newAxis], cache: cache, state: nil).logits
                case .logits(let out): logits = out.logits
                }
                let token = argMax(logits[0..., -1, 0...], axis: -1)
                eval([token] + cache.flatMap { $0.innerState() })
                first.append(token.item(Int.self))
                promptTokens.append(rest.count)
                promptSeconds.append(Date().timeIntervalSince(began))
                caches.append(cache)
            }
            // The caches merged, layer by layer.
            var batch: [KVCache] = []
            for layer in caches[0].indices {
                let column = caches.map { $0[layer] }
                if let recurrent = column as? [MambaCache] {
                    batch.append(mergedRecurrent(recurrent))
                } else if let simple = column as? [KVCacheSimple] {
                    batch.append(PaddedBatchKVCache(merging: simple))
                } else {
                    throw BatchGenerationError.unsupportedCache(String(describing: type(of: column[0])))
                }
            }
            caches = []
            // Decoded together, one step ahead as mlx-lm's generation loop is: the next step is queued on the GPU before the
            // tokens of this one are read, so building the graph overlaps the work. A row that has finished is taken out a
            // step later, with the extra token it wrote. `live` maps a row of the batch to its request.
            var live = Array(items.indices)
            var written = [[Int]](repeating: [], count: items.count)
            let decodeBegan = Date()
            func step(_ tokens: MLXArray) -> MLXArray {
                let logits = model(LMInput.Text(tokens: tokens.reshaped([tokens.dim(0), 1])), cache: batch, state: nil).logits
                let chosen = argMax(logits[0..., -1, 0...], axis: -1)
                asyncEval([chosen] + batch.flatMap { $0.innerState() })
                return chosen
            }
            func finish(_ request: Int, stopped: Bool) {
                let text = context.tokenizer.decode(tokenIds: written[request])
                onFinished(request, LanguageModel.Counted(
                    text: LanguageModel.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines),
                    promptTokens: promptTokens[request], outputTokens: written[request].count, hitCap: !stopped,
                    peakMegabytes: MLX.Memory.peakMemory / 1_048_576, promptSeconds: promptSeconds[request],
                    generateSeconds: Date().timeIntervalSince(decodeBegan)))
            }
            // The first tokens came from reading the prompts.
            var current = MLXArray(first.map(Int32.init))
            var steps = 0
            while !live.isEmpty {
                try Task.checkCancellation()
                let ahead = step(current)
                let values = current.asArray(Int.self)
                var kept: [Int] = []
                for (row, request) in live.enumerated() {
                    let token = values[row]
                    if stops.contains(token) {
                        finish(request, stopped: true)
                        continue
                    }
                    written[request].append(token)
                    if written[request].count >= items[request].maxTokens { finish(request, stopped: false) } else { kept.append(row) }
                }
                if kept.isEmpty { break }
                if kept.count == live.count {
                    current = ahead
                } else {
                    let index = MLXArray(kept.map(Int32.init))
                    for cache in batch {
                        if let c = cache as? PaddedBatchKVCache { c.filter(index) } else if let c = cache as? ArraysCache { c.filter(batchIndices: index) }
                    }
                    current = ahead[index]
                    live = kept.map { live[$0] }
                }
                steps += 1
                if steps % 256 == 0 { MLX.Memory.clearCache() }
            }
        }
    }
}
