// swift-tools-version: 6.2
import PackageDescription

// Model-backed services: speech, voice, language model, embeddings.
// Build with xcodebuild (MLX needs the Metal toolchain).
let package = Package(
    name: "ChirpML",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ChirpML", targets: ["ChirpML"])],
    dependencies: [
        .package(path: "../ChirpCore"),
        .package(path: "../TranscribeCpp"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
        // A revision of main past the last tag (3.32.3): it has the fix for the memory a Qwen3.5 model
        // left behind on every unload (mlx-swift-lm #631).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "c8dabc63e7018d0b1567b2171f8df5dd8a334a55"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ChirpML",
            dependencies: [
                .product(name: "ChirpCore", package: "ChirpCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "TranscribeCpp", package: "TranscribeCpp"),
                .product(name: "MLX", package: "mlx-swift"),
                // ModuleParameters, for the summary model's LoRA adapter.
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                // The sentence checker for summaries (MiniCheck, a cross-encoder), off unless switched on.
                .product(name: "MLXRerankers", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
