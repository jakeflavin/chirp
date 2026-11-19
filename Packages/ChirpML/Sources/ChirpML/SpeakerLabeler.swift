import ChirpCore
import FluidAudio
import Foundation

/// Works out who spoke when in a finished recording (pyannote community-1, run after the meeting).
/// Calls are made one at a time by the meeting recorder.
///
/// This is the app's side. The models are loaded and run in a helper process (`ListenWorker`,
/// `SpeakerEngine`), so a fault in them cannot take the app down, and unloading ends that process and
/// returns its memory.
public final class SpeakerLabeler: @unchecked Sendable {
    private let helper = ModelHelper(arguments: [ListenWorker.flag, ListenWorker.speakers], what: "speaker labelling")
    private let lock = NSLock()
    /// Whether the models count as loaded, and the helper they were loaded in.
    private var loaded = false
    private var loadedIn: Int?

    /// Seconds the helper may go without a word while it loads (a first use downloads the models).
    private static let loadSilence: Double = 600
    /// Seconds it may go without a word while it labels: at least five minutes, and four times the length
    /// of the sound. (A recording that waited for ever on this step is what this limit is for.)
    static func labelSilence(seconds: Double) -> Double { max(300, seconds * 4) }

    public init() {}

    /// Whether the models are in use and ready to label a recording.
    public var isLoaded: Bool { lock.withLock { loaded } }

    /// Whether the models' folder is on disk. Only the folder is looked for, not each file in it.
    /// (FluidAudio is asked only where its folder is; nothing of it is loaded in the app.)
    public nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(
            atPath: MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer).path)
    }

    /// Downloads the models if needed and loads them in the helper. Does nothing when they are already loaded.
    public func load() async throws {
        if lock.withLock({ loaded && loadedIn != nil && loadedIn == helper.running }) { return }
        try await loadInHelper()
        lock.withLock { loaded = true }
    }

    private func loadInHelper() async throws {
        let number = try await helper.ensureRunning()
        _ = try await helper.call("load", silence: Self.loadSilence)
        lock.withLock { loadedIn = number }
    }

    /// Frees the models' memory by ending the helper.
    public func unload() {
        lock.withLock {
            loaded = false
            loadedIn = nil
        }
        Task { await helper.stop() }
    }

    /// Ends the helper at once without waiting, for when the app quits.
    public func stopNow() { helper.stopNow() }

    /// Helpers started since launch, and the running one's process id (diagnostics and tests).
    public var helperStarts: Int { helper.helperStarts }
    public var helperPID: Int32? { helper.helperPID }

    /// Makes sure the helper that is running has the models: one that died is replaced here.
    private func ready() async throws {
        guard lock.withLock({ loaded }) else { throw SpeechError.notLoaded }
        if lock.withLock({ loadedIn == nil || loadedIn != helper.running }) { try await loadInHelper() }
    }

    /// Speaker turns for 16 kHz mono audio, sorted by start time.
    public func turns(in samples: [Float]) async throws -> [SpeakerTurn] {
        try await ready()
        let seconds = Double(samples.count) / Double(Transcriber.sampleRate)
        let frame = try await helper.call("turns", samples: samples, silence: Self.labelSilence(seconds: seconds))
        return try Self.turns(frame.json)
    }

    /// Speaker turns for an audio file of any common format. The file is read a part at a time in the
    /// helper, so its sound is never held whole in memory for this.
    public func turns(inFile url: URL) async throws -> [SpeakerTurn] {
        try await ready()
        // The length is not known here: an hour's allowance, which a three-hour file stays well inside.
        let frame = try await helper.call("turnsFile", json: Data(url.path.utf8), silence: 3600)
        return try Self.turns(frame.json)
    }

    private static func turns(_ json: Data) throws -> [SpeakerTurn] {
        try JSONDecoder().decode([SpeakerTurnAnswer].self, from: json).map { SpeakerTurn(speaker: $0.speaker, start: $0.start, end: $0.end) }
    }
}
