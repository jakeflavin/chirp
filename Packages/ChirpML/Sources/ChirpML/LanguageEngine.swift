import ChirpCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// The model itself: loads it with MLX and generates. Only ever used inside the helper process
/// (`LanguageWorker`); the app talks to it through `LanguageModel`.
actor LanguageEngine {
    /// The loaded model with its tokenizer, or nil before `load`.
    private var container: ModelContainer?
    /// The loaded model, for the batched runs (`BatchedGeneration.swift`).
    var loadedContainer: ModelContainer? { container }
    /// The prompts' shared start, read once and reused by the batched runs (`BatchedGeneration.swift`).
    let promptPrefix = PromptPrefix()

    /// Downloads the model if needed and loads it. `progress` reports 0…1. `modelID` is a hub repository, pinned to a commit
    /// as "repo@revision" (`HubReference`); an absolute path is a model folder on this Mac
    /// (testing only: a converted model that is not on the hub). `adapterID` is a LoRA adapter on the hub in PEFT's format
    /// ("repo@revision"), downloaded the same way and fused into the model by mlx-swift-lm (`LoRAContainer.fuse`, which for a
    /// quantized layer dequantizes, adds the update and quantizes again, as mlx-lm's `fuse` does): the summary
    /// model has one.
    func load(modelID: String, adapterID: String? = nil, progress: (@Sendable (Double) -> Void)?) async throws {
        // Keep MLX's reusable buffer pool small; on an 8 GB Mac every spare megabyte matters.
        MLX.Memory.cacheLimit = 64 * 1_048_576
        let downloader = #hubDownloader()
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: modelID.hasPrefix("/") ? .init(directory: URL(fileURLWithPath: modelID)) : Self.configuration(modelID)
        ) { p in
            progress?(p.fractionCompleted * (adapterID == nil ? 1 : 0.99))
        }
        if let adapterID {
            let adapter = HubReference.split(adapterID)
            let folder = try await downloader.download(
                id: adapter.repo, revision: adapter.revision, matching: ["adapter_config.json", "adapter_model.safetensors"],
                useLatest: false, progressHandler: { _ in })
            try await loaded.perform { (context: ModelContext) in
                try context.model.fuse(with: try Self.peftAdapter(in: folder, for: context.model))
            }
        }
        container = loaded
    }

    /// The hub model a "repo@revision" names, at that revision (the hub's latest when none is named).
    static func configuration(_ reference: String) -> MLXLMCommon.ModelConfiguration {
        let hub = HubReference.split(reference)
        return hub.revision.map { MLXLMCommon.ModelConfiguration(id: hub.repo, revision: $0) } ?? MLXLMCommon.ModelConfiguration(id: hub.repo)
    }

    /// A PEFT LoRA adapter (`adapter_config.json`, `adapter_model.safetensors`) as mlx-swift-lm's `LoRAContainer`: the same
    /// rank and scale (alpha / r), its target modules, and its A and B matrices under the model's own names, turned the way
    /// mlx-swift-lm keeps them (`lora_a` is in × r, `lora_b` r × out).
    static func peftAdapter(in folder: URL, for model: any MLXLMCommon.LanguageModel) throws -> LoRAContainer {
        struct PEFTConfig: Decodable {
            var r: Int
            var lora_alpha: Float
            var target_modules: [String]
            var use_dora: Bool?
            var use_rslora: Bool?
            var fan_in_fan_out: Bool?
        }
        let config = try JSONDecoder().decode(PEFTConfig.self, from: Data(contentsOf: folder.appending(component: "adapter_config.json")))
        guard config.use_dora != true, config.use_rslora != true, config.fan_in_fan_out != true, let lora = model as? LoRAModel else {
            throw LanguageModelError.refused("This adapter's kind of LoRA is not supported.")
        }
        let keys = lora.loraDefaultKeys.filter { key in config.target_modules.contains { key == $0 || key.hasSuffix("." + $0) } }
        var weights: [String: MLXArray] = [:]
        for (name, array) in try MLX.loadArrays(url: folder.appending(component: "adapter_model.safetensors")) {
            let path = name.replacingOccurrences(of: "base_model.model.", with: "")
            if path.hasSuffix(".lora_A.weight") {
                weights[path.replacingOccurrences(of: ".lora_A.weight", with: ".lora_a")] = array.T
            } else if path.hasSuffix(".lora_B.weight") {
                weights[path.replacingOccurrences(of: ".lora_B.weight", with: ".lora_b")] = array.T
            }
        }
        let configuration = LoRAConfiguration(
            numLayers: lora.loraLayers.count, fineTuneType: .lora,
            loraParameters: .init(rank: config.r, scale: config.lora_alpha / Float(config.r), dropout: 0, keys: keys))
        return LoRAContainer(configuration: configuration, parameters: ModuleParameters.unflattened(weights))
    }

    /// Runs one instruction over the text. `onPiece` receives each piece of the answer as it is written.
    func runCounted(
        instructions: String, text: String, maxTokens: Int, temperature: Float,
        onPiece: @Sendable (String) -> Void
    ) async throws -> LanguageModel.Counted {
        guard let container else { throw LanguageModelError.notLoaded }
        var params = GenerateParameters()
        params.maxTokens = maxTokens
        params.temperature = temperature
        let session = ChatSession(
            container, instructions: instructions.isEmpty ? nil : instructions, generateParameters: params,
            // Editing tasks need the answer, not visible reasoning.
            additionalContext: ["enable_thinking": false])
        var out = ""
        var counted = LanguageModel.Counted(text: "", promptTokens: 0, outputTokens: 0, hitCap: false)
        MLX.Memory.peakMemory = 0  // starts the count again
        do {
            for try await piece in session.streamDetails(to: text) {
                try Task.checkCancellation()
                switch piece {
                case .chunk(let chunk):
                    out += chunk
                    onPiece(chunk)
                case .info(let info):
                    counted.promptTokens = info.promptTokenCount
                    counted.outputTokens = info.generationTokenCount
                    counted.hitCap = info.stopReason == .length
                    counted.promptSeconds = info.promptTime
                    counted.generateSeconds = info.generateTime
                default: break
                }
            }
            // A cancelled stream just ends. Say so, or the caller takes the cut-off text for the answer.
            try Task.checkCancellation()
        } catch {
            // The model may still be finishing its last step. Wait for it before the next run starts.
            await session.synchronize()
            throw error
        }
        counted.text = LanguageModel.stripThinking(out).trimmingCharacters(in: .whitespacesAndNewlines)
        counted.peakMegabytes = MLX.Memory.peakMemory / 1_048_576
        return counted
    }
}
