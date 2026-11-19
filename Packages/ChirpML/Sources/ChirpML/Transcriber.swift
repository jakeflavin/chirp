@preconcurrency import AVFoundation
import ChirpCore
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import TranscribeCpp

/// One recognised word with its time in the audio.
public struct TimedWord: Sendable, Equatable, Codable {
    public var text: String
    /// Seconds from the start of the audio to where the word begins.
    public var start: Double
    /// Seconds from the start of the audio to where the word ends.
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What recognition made of one piece of audio.
public struct Transcript: Sendable, Equatable {
    /// Everything that was said, with the space around it trimmed. Empty when no speech was found.
    public var text: String
    /// The same words one by one with their times, for lining text up with the audio.
    public var words: [TimedWord]
    /// Length of the audio in seconds.
    public var duration: Double
    /// How long recognition took, in seconds.
    public var processingTime: Double
    /// False when voice detection found no speech and the model was never asked. True otherwise,
    /// including when the model was asked and returned nothing.
    public var heardSpeech: Bool

    public init(
        text: String = "", words: [TimedWord] = [], duration: Double = 0, processingTime: Double = 0, heardSpeech: Bool = true
    ) {
        self.text = text
        self.words = words
        self.duration = duration
        self.processingTime = processingTime
        self.heardSpeech = heardSpeech
    }
}

/// The numbers voice detection and short clips run with. Each default was measured.
struct SpeechTuning: Sendable, Equatable {
    /// Clips under 30 seconds are only sent to the model when voice detection scores some stretch at
    /// least this high ("is anyone talking?"). On this detector
    /// 0.4 turned away fewer quiet utterances than the detector's own 0.85 and still let no sound
    /// through that the model made words of.
    var gateEnter: Float
    /// Inside such a stretch, speech is taken to go on until the score falls below this.
    var gateExit: Float
    /// The same pair for finding the pauses a long recording is cut at. These are the detector's own:
    /// lower ones (0.5 and 0.35) were tried and made no difference to the words.
    var cutEnter: Float
    var cutExit: Float
    /// A clip shorter than this is filled up to it with silence before the model sees it.
    var padSeconds: Double

    init(gateEnter: Float = 0.4, gateExit: Float = 0.25, cutEnter: Float = 0.85, cutExit: Float = 0.70, padSeconds: Double = 1.25) {
        self.gateEnter = gateEnter
        self.gateExit = gateExit
        self.cutEnter = cutEnter
        self.cutExit = cutExit
        self.padSeconds = padSeconds
    }
}

/// What can go wrong with speech: recognition, the voice, and reading or writing audio files.
/// The descriptions are shown to the user as they are.
public enum SpeechError: LocalizedError, Equatable {
    /// The model was asked to work before `load()` finished.
    case notLoaded
    /// An audio file could not be read or written. The text says why.
    case unreadableAudio(String)
    /// The model file did not arrive, or arrived damaged. The text says why.
    case downloadFailed(String)
    /// The worker process died.
    case workerCrashed
    /// The worker process stopped answering.
    case workerHung
    /// The run was stopped on purpose (the user cancelled). The model still counts as loaded.
    case cancelled
    /// The engine's compute backend failed (a lost GPU device, a failed graph). The worker it happened in
    /// may be of no further use. The text is the engine's own message.
    case backend(String)
    /// The engine itself refused the request. The text is its own message.
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The transcription model is not loaded yet."
        case .unreadableAudio(let why): "That audio could not be read: \(why)"
        case .workerCrashed, .workerHung: "The speech engine stopped. Try again."
        case .cancelled: "Cancelled."
        case .backend(let why): "The speech engine reported a problem: \(why)"
        // What the worker sends back already starts this way: the opening was said twice.
        case .engine(let why): why.hasPrefix("The speech engine") ? why : "The speech engine reported a problem: \(why)"
        case .downloadFailed(let why): "The speech model did not download: \(why). Check the connection and try again."
        }
    }
}

/// Speech-to-text with Parakeet TDT v2 (English). Used for dictation, voice notes, meetings and audio files.
///
/// It runs on the transcribe.cpp engine with a quantized model file, on the GPU with the processor as the
/// fallback. The weights stay quantized in GPU memory,
/// so macOS cannot push them out between dictations the way it did with the Core ML copy.
public actor Transcriber {
    /// Samples per second the model expects. All audio handed to it must already be at this rate, in mono.
    public static let sampleRate = 16_000
    /// The pinned model file for Parakeet V2: file, size, and checksum.
    static let modelFile = "parakeet-tdt-0.6b-v2-Q8_0.gguf"
    static let modelBytes: Int64 = 729_574_912
    static let modelSHA256 = "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"
    static let modelSource = URL(
        string: "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf/resolve/07cee0616125a08ef619729bb47f40ef747e4bc4/parakeet-tdt-0.6b-v2-Q8_0.gguf")!

    /// How long the last transcription took, in seconds.
    public private(set) var lastProcessingTime: Double = 0
    /// Seconds each part took to load (diagnostics).
    public private(set) var loadTimings: [String: Double] = [:]
    /// A non-fatal problem met while loading (diagnostics).
    public private(set) var loadError: String?
    /// Where the model is running, e.g. "Metal" (diagnostics). Follows the worker, so it changes when a
    /// GPU failure moves speech to the processor.
    public var backendName: String { engine.backendName }
    /// When the model was last used or asked for, for unloading it after a quiet spell.
    public private(set) var lastUsed = Date()
    /// Recordings in progress. The model is not unloaded while this is above zero.
    public private(set) var holds = 0 {
        didSet { holdMirror.set(holds) }
    }
    /// A copy of `holds` that can be read without waiting for a transcription in progress to end.
    private let holdMirror = LockedCount()
    /// Recordings in progress, read at once from any thread.
    public nonisolated var holdsNow: Int { holdMirror.get() }
    /// Voice-detection thresholds and the short-clip length in use.
    private let tuning = SpeechTuning()

    /// Runs the model in a separate worker process, so a fault in the engine cannot take the app down.
    private let engine = SpeechSupervisor()
    /// Finds where speech is in the audio. It runs in a helper process of its own (`ListenWorker`,
    /// `VoiceDetectionEngine`), on the processor, and goes when the speech model is unloaded.
    private let voiceDetection = ModelHelper(
        arguments: [ListenWorker.flag, ListenWorker.voiceDetection], what: "voice detection")
    /// The helper voice detection was loaded in, by its number; nil when it is in none (it failed to
    /// load, or speech is unloaded).
    private var voiceDetectionIn: Int?
    /// Whether voice detection is wanted: from the speech model's load to its unload.
    private var voiceDetectionWanted = false
    /// Seconds the voice-detection helper may go without a word on one request.
    private static let voiceSilence: Double = 30
    /// The load in progress, if any. A second caller waits for it and does not start another.
    private var loading: Task<Void, Error>?
    /// A second of faint noise for warming the model up and timing it. Made once, not for every probe.
    private static let faintNoise: [Float] = (0..<Transcriber.sampleRate).map { _ in Float.random(in: -0.001...0.001) }

    public init() {}

    /// Whether the model is ready to transcribe. Stays true while a crashed worker is being replaced.
    public var isLoaded: Bool { engine.isLoaded }

    /// The folder the model file is kept in.
    public nonisolated static var modelDirectory: URL {
        ChirpStore.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where the model file is, or will be once downloaded.
    nonisolated static var modelURL: URL { modelDirectory.appendingPathComponent(modelFile) }

    /// Whether the model file is already on disk (so loading needs no download).
    public nonisolated static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? 0
        return size == modelBytes
    }

    /// Downloads the model if needed and loads it. `progress` reports 0…1 while downloading.
    /// Callers that arrive while a load is under way wait for that one; only the first caller's
    /// `progress` is reported to.
    public func load(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        lastUsed = Date()
        if let loading { return try await loading.value }
        if engine.isLoaded { return }
        let task = Task<Void, Error> {
            // Cleared here, on the actor, before anyone waiting on the task carries on.
            defer { self.loading = nil }
            try await self.loadNow(progress: progress)
        }
        loading = task
        // Stopping the first caller stops the load (and its download), as it did before.
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The load itself. Only ever one at a time: see `load`.
    private func loadNow(progress: (@Sendable (Double) -> Void)?) async throws {
        loadError = nil
        if !Self.isDownloaded { try await Self.download(progress: progress) }
        let t0 = Date()
        // The accelerator setting: automatic picks the GPU and falls back to the processor.
        let wantsProcessor = UserDefaults.standard.string(forKey: "speechBackend") == "cpu"
        let backend: Backend = wantsProcessor ? .cpu : .auto
        // Voice detection loads in its own helper while the speech model loads in its worker.
        voiceDetectionWanted = true
        let t2 = Date()
        let helper = voiceDetection
        // Apart from this actor, which is held while the speech model loads.
        let detection = Task.detached { () -> Int in
            let number = try await helper.ensureRunning()
            _ = try await helper.call("load", silence: 300)
            return number
        }
        do {
            _ = try engine.load(path: Self.modelURL.path, backend: backend)
        } catch {
            voiceDetectionWanted = false
            detection.cancel()
            await voiceDetection.stop()
            voiceDetectionIn = nil
            throw error
        }
        loadTimings["asr"] = Date().timeIntervalSince(t0)
        // The first run on the GPU compiles its programs. Do that now so the first dictation does not wait.
        let t1 = Date()
        _ = try? engine.run(Self.faintNoise)
        loadTimings["warmup"] = Date().timeIntervalSince(t1)
        do {
            voiceDetectionIn = try await detection.value
        } catch {
            loadError = "voice detection: \(error.localizedDescription)"
        }
        loadTimings["vad"] = Date().timeIntervalSince(t2)
        lastUsed = Date()
        progress?(1)
    }

    /// Fetches the model file and checks it against the pinned checksum before putting it in place, so
    /// a cut-off or altered download is never loaded.
    private static func download(progress: (@Sendable (Double) -> Void)?) async throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let watcher = DownloadProgress(expected: modelBytes, report: progress)
        let (temp, response) = try await URLSession.shared.download(from: modelSource, delegate: watcher)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // What arrived is an error page, not the model: do not leave it behind.
            try? FileManager.default.removeItem(at: temp)
            throw SpeechError.downloadFailed("the server did not send the file")
        }
        guard try sha256(of: temp) == modelSHA256 else {
            try? FileManager.default.removeItem(at: temp)
            throw SpeechError.downloadFailed("the file did not arrive intact")
        }
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: temp, to: modelURL)
    }

    /// The file's SHA-256 as lowercase hex. Read a few megabytes at a time: the model is far too big to
    /// hold in memory just to check it.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Frees the model's memory. Voice detection's helper goes with it.
    public func unload() async {
        engine.unload()
        voiceDetectionWanted = false
        voiceDetectionIn = nil
        await voiceDetection.stop()
    }

    /// Starts the voice-detection helper if it is not running and loads the model in it.
    private func loadVoiceDetection() async throws {
        let number = try await voiceDetection.ensureRunning()
        if voiceDetectionIn == number { return }
        _ = try await voiceDetection.call("load", silence: 300)
        voiceDetectionIn = number
    }

    /// Whether voice detection can be asked right now. A helper that died is replaced here, once for each
    /// request; when that fails too, the request goes without (as it did when the model could not load).
    private func voiceDetectionReady() async -> Bool {
        guard voiceDetectionWanted else { return false }
        if let voiceDetectionIn, voiceDetectionIn == voiceDetection.running { return true }
        return (try? await loadVoiceDetection()) != nil
    }

    /// The voice-detection helper: helpers started since launch, and the running one's process id.
    public nonisolated var voiceDetectionStarts: Int { voiceDetection.helperStarts }
    public nonisolated var voiceDetectionPID: Int32? { voiceDetection.helperPID }

    /// Stops the worker from any thread without waiting for a transcription in progress (that
    /// transcription fails). The app calls this as it quits.
    public nonisolated func unloadNow() {
        engine.stopNow()
        voiceDetection.stopNow()
    }

    /// Whether a GPU failure has moved speech to the processor.
    public nonisolated var gpuUnavailable: Bool { engine.gpuUnavailable }

    /// Stops the transcription in progress, if there is one, from any thread: its worker is ended and that
    /// transcription fails as cancelled. The model still counts as loaded; the next use starts a fresh
    /// worker for it. Does nothing when no transcription is running.
    public nonisolated func cancelRun() { engine.cancelRun() }

    /// Where the model is running right now, read at once from any thread (diagnostics).
    public nonisolated var backendNow: String { engine.backendName }

    /// How many transcriptions the engine has been asked for since launch (diagnostics).
    public nonisolated var runCount: Int { engine.runCount }

    /// How many workers have been started since launch (diagnostics).
    public nonisolated var workerStarts: Int { engine.workerStarts }

    /// Forgets a GPU failure and unloads, so the next load may use the GPU again.
    public nonisolated func retryGPU() {
        engine.retryGPU()
        engine.unload()
    }

    /// Sends the worker's restarts and fallbacks to the app's log.
    public nonisolated func onNote(_ note: @escaping @Sendable (String) -> Void) { engine.note = note }

    /// A recording has started: keep the model loaded until `release()`.
    public func hold() {
        holds += 1
        lastUsed = Date()
    }

    /// A recording has ended. Call once for each `hold()`; the quiet spell before unloading starts now.
    public func release() {
        holds = max(0, holds - 1)
        lastUsed = Date()
    }

    /// The stretches of speech in the audio, as sample ranges, or nil when voice detection is unavailable.
    /// Used to find the pauses a long recording is cut at: a quarter second is speech, a tenth of a second
    /// of quiet ends a stretch, with 30 ms of padding. The detector is FluidAudio's Silero, which scores a
    /// quarter second at a time, so the two thresholds were measured on it.
    public func speechSegments(_ samples: [Float]) async -> [Range<Int>]? {
        await speechSegments(samples, enter: tuning.cutEnter, exit: tuning.cutExit, forCuts: true)
    }

    /// As above with the thresholds given: speech starts at a score of `enter` and lasts until it falls
    /// below `exit`. `forCuts` picks the durations for cutting; otherwise the detector's own, as the
    /// "is anyone talking?" check uses.
    public func speechSegments(_ samples: [Float], enter: Float, exit: Float, forCuts: Bool) async -> [Range<Int>]? {
        guard await voiceDetectionReady(),
            let found = try? await voiceDetection.call(
                "segments", VoiceSegmentsRequest(enter: enter, exit: exit, forCuts: forCuts), samples: samples,
                silence: Self.voiceSilence, as: [[Int]].self)
        else { return nil }
        return found.answer.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }
    }

    /// The detector's settings for one pair of thresholds. It takes the lower one and the gap between them.
    static func segmentation(enter: Float, exit: Float, forCuts: Bool) -> VadSegmentationConfig {
        let exit = min(exit, enter)
        var config = forCuts
            ? VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.1, maxSpeechDuration: 3600, speechPadding: 0.03)
            : VadSegmentationConfig()
        config.negativeThreshold = exit
        config.negativeThresholdOffset = enter - exit
        config.silenceThresholdForSplit = max(config.silenceThresholdForSplit, exit)
        return config
    }

    /// The detector's score for the next quarter second of a live stream (4,096 samples), with the state to
    /// hand back for the frame after it; nil when voice detection is unavailable. For cutting a stream by
    /// voice as it arrives (`VoiceSegmenter`).
    public func voiceScore(_ frame: [Float], after state: VoiceStreamState?) async -> (score: Float, state: VoiceStreamState)? {
        guard await voiceDetectionReady() else { return nil }
        // A stream begun in a helper that has since gone starts again in the new one.
        let stream = state.flatMap { $0.helper == voiceDetectionIn ? $0.stream : nil }
        guard let scored = try? await voiceDetection.call(
            "score", VoiceScoreRequest(stream: stream), samples: frame, silence: Self.voiceSilence,
            as: VoiceScoreAnswer.self), let helper = voiceDetectionIn
        else { return nil }
        return (scored.answer.probability, VoiceStreamState(stream: scored.answer.stream, helper: helper))
    }

    /// How long the model takes on a second of faint noise, or nil when it is not loaded.
    public func probeSeconds() async -> Double? {
        guard engine.isLoaded else { return nil }
        let started = Date()
        _ = try? engine.run(Self.faintNoise)
        return Date().timeIntervalSince(started)
    }

    /// Transcribes 16 kHz mono samples of any length. `gate` false skips the "is anyone talking?" check
    /// (for measuring what the model makes of audio the check would have turned away).
    public func transcribe(_ samples: [Float], gate: Bool = true) async throws -> Transcript {
        guard engine.isLoaded else { throw SpeechError.notLoaded }
        lastUsed = Date()
        let duration = Double(samples.count) / Double(Self.sampleRate)
        // Under a quarter second there is nothing to recognise.
        guard duration >= 0.25 else { return Transcript(duration: duration, heardSpeech: false) }
        if gate, duration < 30,
            let segments = await speechSegments(samples, enter: tuning.gateEnter, exit: tuning.gateExit, forCuts: false),
            segments.isEmpty
        {
            return Transcript(duration: duration, heardSpeech: false)  // silence or noise only
        }
        // The model needs a little over a second of input; short clips are filled up with silence.
        var input = samples
        let least = Int(tuning.padSeconds * Double(Self.sampleRate))
        if input.count < least { input += [Float](repeating: 0, count: least - input.count) }
        let started = Date()
        let result = try engine.run(input)
        lastProcessingTime = Date().timeIntervalSince(started)
        lastUsed = Date()
        let words = result.words.map { TimedWord(text: $0.text, start: Double($0.t0) / 1000, end: Double($0.t1) / 1000) }
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), words: words, duration: duration,
            processingTime: lastProcessingTime)
    }

    /// Transcribes an audio file of any common format and length.
    public func transcribe(file url: URL) async throws -> Transcript {
        guard engine.isLoaded else { throw SpeechError.notLoaded }
        return try await transcribe(try AudioFile.samples(from: url))
    }
}

/// Which live stream a frame belongs to. What the voice detector remembers between one frame and the
/// next is kept in its helper, under this number.
public struct VoiceStreamState: Sendable {
    let stream: Int
    /// The helper the stream is in.
    let helper: Int
}

extension Data {
    /// This JSON as a value, or nil.
    func decoded<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: self) }
}

/// The loaded model and its session. This is what runs inside the worker process.
final class SpeechEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var model: Model?
    private var session: Session?

    /// Whether a model is loaded and ready to run.
    var isLoaded: Bool { lock.withLock { session != nil } }

    /// Loads the model and returns the name of what it runs on.
    func load(path: String, backend: Backend) throws -> String {
        try lock.withLock {
            let model = try Model(path: path, options: ModelOptions(backend: backend))
            session = try model.session()
            self.model = model
            return model.backend
        }
    }

    /// Transcribes 16 kHz mono samples, with a time for each word.
    func run(_ samples: [Float]) throws -> SpeechResult {
        try lock.withLock {
            guard let session else { throw SpeechError.notLoaded }
            let out: TranscribeCpp.Transcript
            do {
                out = try session.run(samples, options: RunOptions(timestamps: .word))
            } catch TranscribeError.backend(let why) {
                throw SpeechError.backend(why)
            }
            return SpeechResult(text: out.text, words: out.words.map { .init(text: $0.text, t0: $0.t0Ms, t1: $0.t1Ms) })
        }
    }

    /// Lets go of the model. The session goes first because it uses the model.
    func unload() {
        lock.withLock {
            session = nil
            model = nil
        }
    }
}

/// Reports how much of a download has arrived.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// The size the finished file should be, in bytes. The server's own figure is not relied on.
    let expected: Int64
    /// Called with 0…0.99 as bytes arrive. The last step to 1 is left to the caller, after the file
    /// has been checked and loaded.
    let report: (@Sendable (Double) -> Void)?
    /// Keeps the observation of the download's byte count alive.
    private var watch: NSKeyValueObservation?

    init(expected: Int64, report: (@Sendable (Double) -> Void)?) {
        self.expected = expected
        self.report = report
    }

    /// Starts watching the byte count as soon as the download task exists.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        watch = task.progress.observe(\.completedUnitCount) { [expected, report] progress, _ in
            report?(min(0.99, Double(progress.completedUnitCount) / Double(expected)))
        }
    }
}

/// Reading and writing audio files and WAV data, for recordings, voice notes and read-aloud exports.
public enum AudioFile {
    /// Mono samples as 16-bit WAV data in memory.
    public static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for s in samples { append(Int16(max(-1, min(1, s)) * 32767)) }
        return data
    }

    /// The settings for a mono AAC file at this sample rate and bit rate.
    static func aacSettings(sampleRate: Double, bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
    }

    /// The samples in a buffer ready to be written to a file. Nil when the buffer cannot be made.
    /// Empty input gives an empty buffer.
    static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            // An empty array may have no address at all.
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }

    /// Reads any audio file as 16 kHz mono samples.
    public static func samples(from url: URL) throws -> [Float] {
        do { return try AudioConverter().resampleAudioFile(url) } catch {
            throw SpeechError.unreadableAudio(error.localizedDescription)
        }
    }

    /// Mixes two raw tracks (16 kHz mono, 32-bit floats, no header) into one AAC `.m4a`, a few seconds at a
    /// time, so an hour-long recording is never held in memory.
    public static func writeMix(of tracks: [URL], gain: Float = 0.6, sampleRate: Double = 16_000, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Ten seconds at a time.
        let chunk = Int(sampleRate) * 10
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
        else { throw SpeechError.unreadableAudio("could not create an audio buffer") }
        let settings = aacSettings(sampleRate: sampleRate, bitRate: 32_000)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let handles = tracks.compactMap { try? FileHandle(forReadingFrom: $0) }
        defer { for handle in handles { try? handle.close() } }
        let out = buffer.floatChannelData![0]
        while true {
            var longest = 0
            for i in 0..<chunk { out[i] = 0 }
            for handle in handles {
                guard let data = try handle.read(upToCount: chunk * MemoryLayout<Float>.size), !data.isEmpty else { continue }
                let count = data.count / MemoryLayout<Float>.size
                data.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Float.self)
                    for i in 0..<count { out[i] += samples[i] * gain }
                }
                longest = max(longest, count)
            }
            guard longest > 0 else { break }
            buffer.frameLength = AVAudioFrameCount(longest)
            try file.write(from: buffer)
        }
    }

    /// Writes 16 kHz mono samples as a compact AAC `.m4a`, or WAV when the extension is `wav`.
    public static func write(_ samples: [Float], sampleRate: Double = 16_000, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = pcmBuffer(samples, format: format)
        else { throw SpeechError.unreadableAudio("could not create an audio buffer") }
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let settings = url.pathExtension.lowercased() == "wav" ? wavSettings : aacSettings(sampleRate: sampleRate, bitRate: 32_000)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if samples.isEmpty { return }
        try file.write(from: buffer)
    }
}

/// Writes speech to an `.m4a` file a piece at a time, so a whole book never has to sit in memory.
public final class AudioFileWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    /// Creates the file, and the folder for it if needed. `sampleRate` is the rate of the samples that
    /// will be appended. The file is finished when the writer is let go.
    public init(url: URL, sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SpeechError.unreadableAudio("could not create an audio format")
        }
        self.format = format
        file = try AVAudioFile(
            forWriting: url,
            settings: AudioFile.aacSettings(sampleRate: sampleRate, bitRate: 48_000),
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Adds mono samples to the end of the file. An empty piece is skipped.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, let buffer = AudioFile.pcmBuffer(samples, format: format) else { return }
        try file.write(from: buffer)
    }
}

/// A number that can be read from any thread without waiting.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ v: Int) { lock.withLock { value = v } }
    func get() -> Int { lock.withLock { value } }
}
