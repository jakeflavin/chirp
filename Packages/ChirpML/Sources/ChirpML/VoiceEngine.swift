import ChirpCore
import CoreML
import FluidAudio
import Foundation

/// What the app asks the voice helper for one sentence.
struct VoiceRequest: Codable, Sendable {
    var text: String
    var voice: String
    var speed: Float
}

/// What comes back with the sentence's sound: what the app needs to work out each word's time.
struct VoiceAnswer: Codable, Sendable {
    /// The model's seven stages, in the order `stageMs` gives their times.
    static let stageNames = ["albert", "postAlbert", "alignment", "prosody", "noise", "vocoder", "tail"]
    var sampleRate: Double
    /// The sounds the voice made, and how long it gave each.
    var phonemes: String
    var durations: [Int32]
    /// The text the voice really spoke, after it wrote numbers and symbols out as words.
    var spokenText: String?
    var stageMs: [Double]
}

/// The helper process for the reading voice: the app's own executable started with `VoiceWorker.flag`.
public enum VoiceWorker {
    /// The first argument that makes the app's executable run as the voice helper instead of as the app.
    public static let flag = "--voice-worker"

    /// Whether this process was launched as the voice helper. Checked before the app starts.
    public static var isWorkerInvocation: Bool { HelperWorker.arguments.first == flag }

    /// The helper's whole life: load the voice when asked, make each sentence it is sent, until the app
    /// closes the pipe.
    public static func run() -> Never {
        let engine = VoiceEngine()
        HelperWorker.serve([
            "load": { _, _, _ in (Data(try await engine.load().utf8), Data()) },
            "cleanup": { _, _, _ in
                await engine.cleanup()
                return (Data(), Data())
            },
            "speak": { json, _, _ in
                let request = try JSONDecoder().decode(VoiceRequest.self, from: json)
                let made = try await engine.speak(request)
                return (try JSONEncoder().encode(made.answer), Data(floats: made.samples))
            },
        ])
    }
}

/// The voice itself: Kokoro through FluidAudio. Only ever used inside the voice helper; the app talks to
/// it through `Voice`.
actor VoiceEngine {
    /// The voice model. It is kept after `cleanup`, with its word list read in.
    private var manager: KokoroAneManager?
    /// Whether the model's seven parts are in memory.
    private var loaded = false
    /// True while the voice is saying words the British way (see `setAccent`).
    private var british = false
    /// After the British word list could not be fetched: when to try again.
    private var britishRetry = Date.distantPast

    /// Downloads the voice if needed and loads it. Returns how long it took and where that went, for the log.
    func load() async throws -> String {
        if loaded { return "0 ms: already loaded" }
        // Every stage on the processor. FluidAudio's own choice for macOS 27 (five stages on the Neural
        // Engine) takes 1.3 to 1.7 s for every load against 0.01 to 0.03 s, about 890 MB in use against
        // 215 MB, and is no faster.
        let units = KokoroAneComputeUnits(
            albert: .cpuOnly, postAlbert: .cpuOnly, alignment: .cpuOnly, prosody: .cpuOnly,
            noise: .cpuOnly, vocoder: .cpuOnly, tail: .cpuOnly)
        let started = Date()
        // The one kept from before a cleanup still has its word list read in.
        if manager == nil { british = false }
        let m = manager ?? KokoroAneManager(variant: .english, directory: Voice.customDirectory, computeUnits: units)
        do {
            try await m.initialize()
        } catch {
            // Start afresh next time, in case the kept one is what cannot load.
            manager = nil
            throw error
        }
        let models = Date()
        try? await m.prepareEnglishFrontend()
        manager = m
        loaded = true
        Voice.fetchMissingVoices()
        return String(
            format: "%.0f ms: models %.0f, text front end %.0f", Date().timeIntervalSince(started) * 1000,
            models.timeIntervalSince(started) * 1000, Date().timeIntervalSince(models) * 1000)
    }

    /// Frees the voice model's memory and keeps the list of how each word is said (see `Voice.unload`).
    func cleanup() async {
        await manager?.cleanup()
        loaded = false
    }

    /// Has a British voice ("bf_…", "bm_…") say words the British way, and any other voice the American way.
    ///
    /// Kokoro's own pipeline picks the word list by the voice's accent (`KPipeline`: `british=lang_code=='b'`).
    /// FluidAudio's Kokoro always reads the American list, so "schedule", "bath" and "tomato" came out
    /// American in a British voice. It does take a list of words to say differently, which is looked up
    /// before its own; the British list (the same Misaki list, from the same place as the American one,
    /// about 10 MB, fetched the first time a British voice is used) is handed to it that way. Words in
    /// neither list, and the "'s" on a word, are still worked out the American way.
    private func setAccent(for voice: String) async {
        guard let manager else { return }
        let wanted = voice.hasPrefix("b")
        guard wanted != british else { return }
        if wanted {
            guard Date() > britishRetry else { return }
            guard let words = await Self.britishWordList(), !words.isEmpty else {
                // No connection, most likely: the American way for now.
                britishRetry = Date().addingTimeInterval(300)
                return
            }
            await manager.setEnglishCustomLexicon(words)
        } else {
            await manager.setEnglishCustomLexicon([:])
        }
        british = wanted
    }

    /// Every word in the British list with the sounds it is said with, or nil when the list cannot be had.
    private nonisolated static func britishWordList() async -> [String: String]? {
        guard let folder = await KokoroAneResourceDownloader.ensureEnglishLexicon(directory: Voice.customDirectory, british: true),
            let vocab = try? KokoroAneVocab.load(from: Voice.modelDirectory.appendingPathComponent("kokoro-82m-coreml/ANE/vocab.json"))
        else { return nil }
        let list = LexiconAssetCache()
        guard (try? await list.ensureLoaded(
            kokoroDirectory: folder, allowedTokens: Set(vocab.map.keys.map(String.init)),
            fileName: LexiconAssetCache.englishFileName(british: true))) != nil
        else { return nil }
        let maps = await list.lexicons()
        var words: [String: String] = [:]
        words.reserveCapacity(maps.word.count + maps.caseSensitive.count)
        for (word, sounds) in maps.word where !sounds.isEmpty { words[word] = sounds.joined() }
        for (word, sounds) in maps.caseSensitive where !sounds.isEmpty { words[word] = sounds.joined() }
        // "AI" and "US" are said letter by letter (FluidAudio does this itself, but only after this list is looked in).
        for name in ["AI", "US"] {
            let letters = name.compactMap { maps.caseSensitive[String($0)]?.joined() }
            if letters.count == name.count { words[name] = letters.joined(separator: " ") }
        }
        return words
    }

    /// Makes one sentence: its sound, and what the app needs to time its words.
    func speak(_ request: VoiceRequest) async throws -> (answer: VoiceAnswer, samples: [Float]) {
        guard let manager, loaded else { throw SpeechError.notLoaded }
        await setAccent(for: request.voice)
        let result = try await manager.synthesizeDetailed(text: request.text, voice: request.voice, speed: request.speed)
        let t = result.timings
        return (
            VoiceAnswer(
                sampleRate: Double(result.sampleRate), phonemes: result.phonemes, durations: result.predictedDurations,
                spokenText: result.normalizedText,
                stageMs: [t.albert, t.postAlbert, t.alignment, t.prosody, t.noise, t.vocoder, t.tail]),
            result.samples
        )
    }
}
