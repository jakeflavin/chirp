import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXRerankers
import Tokenizers

/// The sentence checker for summaries: MiniCheck-RoBERTa-Large, a cross-encoder that scores whether a claim is
/// supported by a text, run with mlx-swift-lm's reranker API. Only ever used inside the helper process; off unless
/// switched on. MiniCheck's own code (`minicheck/inference.py`) cuts the text into chunks of about 400 tokens at
/// sentence ends, scores the claim against each, and takes the best; the app makes the chunks, this scores them.
actor CheckEngine {
    private var container: RerankerContainer?

    /// Loads the checker from a folder holding `config.json` (with `id2label` naming class 1 "entailment"),
    /// `model.safetensors` and the tokenizer.
    func load(directory: URL) async throws {
        if container != nil { return }
        MLX.Memory.cacheLimit = 64 * 1_048_576
        container = try await RerankerModelFactory.shared.loadContainer(
            from: directory, using: #huggingFaceTokenizerLoader(), allowUnverifiedModel: true)
    }

    func unload() {
        container = nil
        MLX.Memory.clearCache()
    }

    /// Each claim's best "supported" probability over its group's chunks.
    func score(_ request: CheckRequest) async throws -> CheckReply {
        guard let container else { throw LanguageModelError.notLoaded }
        MLX.Memory.peakMemory = 0
        var out: [[Double]] = []
        for group in request.groups {
            var best = [Double](repeating: 0, count: group.claims.count)
            guard !group.claims.isEmpty else { out.append(best); continue }
            for chunk in group.chunks {
                try Task.checkCancellation()
                // The chunk first and the claim second, as MiniCheck pairs them.
                let response = try await container.scores(query: chunk, documents: group.claims, instruction: nil, options: .init())
                for result in response.results { best[result.index] = max(best[result.index], result.score) }
            }
            out.append(best)
        }
        return CheckReply(scores: out, peakMegabytes: MLX.Memory.peakMemory / 1_048_576)
    }
}
