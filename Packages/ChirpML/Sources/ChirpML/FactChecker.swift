import ChirpCore
import Foundation

/// The app's side of the sentence checker (`CheckEngine` runs it in the helper). Summaries use it when its folder is
/// installed in Chirp's Models folder; nothing is downloaded for it.
public actor FactChecker {
    private let supervisor = LanguageSupervisor.shared

    public init() {}

    /// One group of claims and the text they are checked against, already cut into chunks.
    public struct Group: Sendable {
        public var chunks: [String]
        public var claims: [String]
        public init(chunks: [String], claims: [String]) {
            self.chunks = chunks
            self.claims = claims
        }
    }

    /// Loads the checker from `directory` in the helper, scores every group, and puts it away again. Returns each
    /// claim's score (0…1, "supported") by group, and the most memory MLX held while scoring.
    public func scores(_ groups: [Group], directory: URL) async throws -> (scores: [[Double]], peakMegabytes: Int) {
        await supervisor.embedGate.enter()
        defer { supervisor.embedGate.leave() }
        _ = try await supervisor.ensureRunning()
        let reply = try await supervisor.check(
            directory: directory.path, request: CheckRequest(groups: groups.map { CheckRequest.Group(chunks: $0.chunks, claims: $0.claims) }))
        return (reply.scores, reply.peakMegabytes)
    }
}
