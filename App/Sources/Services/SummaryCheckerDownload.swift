import ChirpCore
import CryptoKit
import Foundation

/// Downloads the summary sentence checker (MiniCheck RoBERTa-Large, converted to safetensors) into Chirp's Models
/// folder the first time a summary needs it (Docs/MODELS.md).
///
/// It runs in the background: summaries made before it finishes use the rule check alone. Every file is checked
/// against its size and SHA-256 before the folder is put in place, so a cut-off or changed download is never used.
@MainActor
enum SummaryCheckerDownload {
    /// The Hugging Face repository the converted checker is published in.
    nonisolated static let repository = "jakeflavin/minicheck-roberta-large"

    /// Each file with its size and SHA-256.
    nonisolated static let files: [(name: String, bytes: Int64, sha256: String)] = [
        ("added_tokens.json", 75, "ffbab93e7b41fb5464d9ef1d16d898288280c141a84df766f18eb14b59e7683d"),
        ("config.json", 927, "bc066aacbd229584d5f8202bd42e55695c5e72706351e6ead7ea48f4b59b065c"),
        ("merges.txt", 456_318, "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
        ("model.safetensors", 710_774_892, "3e09b6056568075ca182171641a41de58ebced14c172e84856dccd425501baad"),
        ("special_tokens_map.json", 267, "397c86572c64f631570b56b0a36397dd4f54d7d0d6275e2af5768a9b197acea4"),
        ("tokenizer.json", 2_108_717, "1f325de61b2d8f48f2580c234ef57f927ffb952ea8617a9820559ec6b7b687e5"),
        ("tokenizer_config.json", 1427, "9036998b933c6204c820ef64854b13f3302822128439099a91f936888e3692f6"),
        ("vocab.json", 798_293, "ed19656ea1707df69134c4af35c8ceda2cc9860bf2c3495026153a133670ab5e"),
    ]

    private static var running: Task<Void, Never>?

    /// Starts the download unless it is running or already done. Test copies never download it.
    static func startIfNeeded() {
        guard running == nil, ModelCenter.summaryCheckerDirectory == nil, !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        running = Task.detached(priority: .utility) {
            do {
                try await download()
                Log.write("summary", "sentence checker downloaded")
            } catch {
                Log.write("summary", "sentence checker download failed: \(error.localizedDescription)")
            }
            await MainActor.run { running = nil }
        }
    }

    private struct Failed: LocalizedError {
        var errorDescription: String?
    }

    /// Fetches every file into a temporary folder, checks it, then moves the folder into place in one step.
    nonisolated private static func download() async throws {
        let manager = FileManager.default
        let target = ChirpStore.modelsDirectory.appendingPathComponent(ModelCenter.summaryCheckerFolder, isDirectory: true)
        let staging = ChirpStore.modelsDirectory.appendingPathComponent(".\(ModelCenter.summaryCheckerFolder)-download", isDirectory: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file.name)")!
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? manager.removeItem(at: temp)
                throw Failed(errorDescription: "\(file.name): the server did not send the file")
            }
            let size = (try manager.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == file.bytes, try sha256(of: temp) == file.sha256 else {
                try? manager.removeItem(at: temp)
                throw Failed(errorDescription: "\(file.name) did not arrive intact")
            }
            try manager.moveItem(at: temp, to: staging.appendingPathComponent(file.name))
        }
        try? manager.removeItem(at: target)
        try manager.moveItem(at: staging, to: target)
    }

    /// A file's SHA-256 as lowercase hex, read a few megabytes at a time.
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
