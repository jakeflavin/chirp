import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// The search model itself: loads it with MLX and turns texts into vectors. Only ever used inside the
/// helper process (`LanguageWorker`); the app talks to it through `Embedder`.
actor EmbedEngine {
    /// The loaded model with its tokenizer, or nil when not loaded.
    private var container: EmbedderModelContainer?

    /// Downloads the model if needed and loads it. `progress` reports 0…1. `modelID` is "repo@revision" (`HubReference`).
    func load(modelID: String, progress: (@Sendable (Double) -> Void)?) async throws {
        if container != nil { return }
        // Keep MLX's reusable buffer pool small; on an 8 GB Mac every spare megabyte matters. Without the limit
        // the pool grew to 3.4 GB while a library of 158 items was read. The language
        // model sets the same limit when it loads; whichever loads first, it is set.
        MLX.Memory.cacheLimit = 64 * 1_048_576
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: LanguageEngine.configuration(modelID)
        ) { p in
            progress?(p.fractionCompleted)
        }
    }

    /// Frees the model's memory (the helper stays, for the language model).
    func unload() {
        container = nil
        MLX.Memory.clearCache()
    }

    /// A unit-length vector for each text, in the same order. Text past about 510 tokens is not read.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let container else { throw EmbedderError.notLoaded }
        return await container.perform { context in
            let (model, tokenizer, pooling) = (context.model, context.tokenizer, context.pooling)
            var out: [[Float]] = []
            for text in texts {
                // The model reads 512 tokens at most. When text is cut to fit, the closing marker the
                // tokenizer put last is kept, because the model expects every input to end with it.
                let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
                let tokens = encoded.count > 512 ? Array(encoded.prefix(511)) + [encoded[encoded.count - 1]] : encoded
                let ids = MLXArray(tokens).expandedDimensions(axis: 0)
                let mask = MLXArray.ones(like: ids)
                let types = MLXArray.zeros(like: ids)
                let pooled = pooling(
                    model(ids, positionIds: nil, tokenTypeIds: types, attentionMask: mask), normalize: true)
                pooled.eval()
                out.append(pooled[0].asArray(Float.self))
            }
            return out
        }
    }
}
