import ChirpCore
import CoreML
import FluidAudio
import Foundation

// The helper for the two small models that listen to recorded sound: voice detection (where speech is)
// and speaker labelling (who spoke when). Each runs in its own copy of the helper, so putting speaker
// labelling away ends its process and returns its memory while voice detection carries on.
//
// They are not in the speech worker, though they work on the same sound. Kept apart on purpose: the
// speech worker counts a worker lost in the middle of a request as a
// failure of the graphics chip and moves speech to the processor; a fault in one of these models must not
// do that, and dictation's worker is left exactly as it was measured.

/// What the app asks voice detection for the stretches of speech in some sound.
struct VoiceSegmentsRequest: Codable, Sendable {
    var enter: Float
    var exit: Float
    var forCuts: Bool
}

/// What the app asks for the score of the next frame of a live stream: which stream it belongs to (nil
/// starts one).
struct VoiceScoreRequest: Codable, Sendable {
    var stream: Int?
}

/// The score, and the stream to name with the next frame.
struct VoiceScoreAnswer: Codable, Sendable {
    var probability: Float
    var stream: Int
}

/// One speaker's turn, as it crosses the pipe.
struct SpeakerTurnAnswer: Codable, Sendable {
    var speaker: String
    var start: Double
    var end: Double
}

/// The helper process: the app's own executable started with `ListenWorker.flag` and a role.
public enum ListenWorker {
    /// The first argument that makes the app's executable run as this helper instead of as the app.
    public static let flag = "--listen-worker"
    /// The second argument: which of the two models this copy runs.
    static let voiceDetection = "voice-detection"
    static let speakers = "speakers"

    /// Whether this process was launched as this helper. Checked before the app starts.
    public static var isWorkerInvocation: Bool { HelperWorker.arguments.first == flag }

    /// The helper's whole life, for whichever role it was started with.
    public static func run() -> Never {
        if HelperWorker.arguments.dropFirst().first == speakers {
            let engine = SpeakerEngine()
            HelperWorker.serve([
                "load": { _, _, _ in
                    try await engine.load()
                    return (Data(), Data())
                },
                "turns": { _, blob, _ in
                    (try JSONEncoder().encode(try await engine.turns(in: blob.floats)), Data())
                },
                "turnsFile": { json, _, _ in
                    (try JSONEncoder().encode(try await engine.turns(inFile: URL(fileURLWithPath: String(decoding: json, as: UTF8.self)))), Data())
                },
            ])
        }
        let engine = VoiceDetectionEngine()
        HelperWorker.serve([
            "load": { _, _, _ in
                try await engine.load()
                return (Data(), Data())
            },
            "segments": { json, blob, _ in
                let request = try JSONDecoder().decode(VoiceSegmentsRequest.self, from: json)
                return (try JSONEncoder().encode(try await engine.segments(blob.floats, request)), Data())
            },
            "score": { json, blob, _ in
                let request = try JSONDecoder().decode(VoiceScoreRequest.self, from: json)
                return (try JSONEncoder().encode(try await engine.score(blob.floats, stream: request.stream)), Data())
            },
        ])
    }
}

/// Voice detection itself (FluidAudio's Silero, on the processor). Only ever used inside the helper.
actor VoiceDetectionEngine {
    private var vad: VadManager?
    /// What the detector remembers between one frame of a live stream and the next, by stream. Only the
    /// newest few are kept: a recording uses one.
    private var streams: [Int: VadStreamState] = [:]
    private var lastStream = 0

    func load() async throws {
        if vad != nil { return }
        var config = VadConfig.default
        config.computeUnits = .cpuOnly
        let v = try await VadManager(config: config)
        // The first use compiles the model: do it now, so the first dictation does not wait.
        _ = try? await v.segmentSpeech([Float](repeating: 0, count: Transcriber.sampleRate))
        vad = v
    }

    /// The stretches of speech, as pairs of sample positions.
    func segments(_ samples: [Float], _ request: VoiceSegmentsRequest) async throws -> [[Int]] {
        guard let vad else { throw SpeechError.notLoaded }
        let found = try await vad.segmentSpeech(
            samples, config: Transcriber.segmentation(enter: request.enter, exit: request.exit, forCuts: request.forCuts))
        return found.compactMap { segment in
            let from = max(0, segment.startSample(sampleRate: Transcriber.sampleRate))
            let to = min(samples.count, segment.endSample(sampleRate: Transcriber.sampleRate))
            return from < to ? [from, to] : nil
        }
    }

    /// The score for the next quarter second of a live stream.
    func score(_ frame: [Float], stream: Int?) async throws -> VoiceScoreAnswer {
        guard let vad else { throw SpeechError.notLoaded }
        let id: Int
        if let stream, streams[stream] != nil {
            id = stream
        } else {
            lastStream += 1
            id = lastStream
            streams = streams.filter { $0.key > id - 4 }
        }
        let result = try await vad.processStreamingChunk(frame, state: streams[id] ?? VadStreamState.initial())
        streams[id] = result.state
        return VoiceScoreAnswer(probability: result.probability, stream: id)
    }
}

/// Speaker labelling itself (pyannote community-1 through FluidAudio, on the processor). Only ever used
/// inside the helper. Not an actor: FluidAudio's manager cannot be handed across one. Calls are made one
/// at a time by the meeting recorder, as they were when this ran in the app.
final class SpeakerEngine: @unchecked Sendable {
    private var manager: OfflineDiarizerManager?

    func load() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: .default)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly  // loads fast; see Transcriber
        try await m.prepareModels(configuration: configuration)
        manager = m
    }

    func turns(in samples: [Float]) async throws -> [SpeakerTurnAnswer] {
        guard let manager else { throw SpeechError.notLoaded }
        return Self.sorted(try await manager.process(audio: samples))
    }

    /// The file is read a part at a time (FluidAudio maps it), so its sound is never held whole in memory.
    func turns(inFile url: URL) async throws -> [SpeakerTurnAnswer] {
        guard let manager else { throw SpeechError.notLoaded }
        return Self.sorted(try await manager.process(url))
    }

    private static func sorted(_ result: DiarizationResult) -> [SpeakerTurnAnswer] {
        result.segments
            .map { SpeakerTurnAnswer(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }
}
