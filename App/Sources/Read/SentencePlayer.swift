@preconcurrency import AVFoundation
import ChirpML
import Foundation

/// Plays one sentence of synthesized speech at a time.
@MainActor
protocol SentencePlayer: AnyObject {
    /// Starts playing and calls `onFinish` when the sentence ends or is stopped.
    func play(_ samples: [Float], sampleRate: Int, rate: Double, onFinish: @escaping @MainActor () -> Void)
    func pause()
    func resume()
    /// Ends the sentence now. `onFinish` is still called, so whoever is waiting for it carries on.
    func stop()
    /// How fast to play, as a multiple of normal speed. Can be changed while a sentence plays.
    var rate: Double { get set }
    /// Position in the sentence, in seconds of audio at normal speed.
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    /// True while there is a sentence to carry on with: playing, or paused part-way through.
    var hasSentence: Bool { get }
}

/// Real audio through the Mac's output. Starting the audio hardware can take a moment, so every
/// call that touches it runs off the main thread and the window never stalls.
@MainActor
final class DevicePlayer: NSObject, SentencePlayer, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onFinish: (@MainActor () -> Void)?
    /// Every call into the audio hardware goes through here, in order and off the main thread.
    private let queue = DispatchQueue(label: "chirp.reader.audio", qos: .userInitiated)
    /// Goes up with each sentence, so a late answer about an earlier sentence is ignored.
    private var token = 0
    private(set) var isPlaying = false
    /// True once the hardware has really begun the current sentence. Until then the player is not asked
    /// for its position, because that call waits for the hardware and would stall the window.
    private var started = false
    /// Called when the Mac's sound output refuses to start.
    var onOutputFailure: (@MainActor () -> Void)?
    /// Uses the real audio hardware with the volume at zero, so playback can be checked without a sound.
    static let muted = ProcessInfo.processInfo.arguments.contains("--muted-device-audio")

    var rate: Double = 1 {
        didSet {
            let p = player, r = Float(rate)
            queue.async { p?.rate = r }
        }
    }

    var hasSentence: Bool { player != nil }
    var currentTime: Double { started ? player?.currentTime ?? 0 : 0 }

    func play(_ samples: [Float], sampleRate: Int, rate: Double, onFinish: @escaping @MainActor () -> Void) {
        stop()
        self.rate = rate
        self.onFinish = onFinish
        token += 1
        let mine = token
        guard let p = try? AVAudioPlayer(data: AudioFile.wavData(samples, sampleRate: sampleRate)) else {
            Log.write("read", "could not prepare audio for a sentence")
            finish(mine)
            return
        }
        if Self.muted { p.volume = 0 }
        p.enableRate = true
        p.rate = Float(rate)
        p.delegate = self
        player = p
        isPlaying = true
        started = false
        queue.async { [weak self] in
            let began = Date()
            let ok = p.play()
            Log.write("read", "audio \(ok ? "started" : "did not start") in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
            Task { @MainActor in
                guard let self, self.token == mine, self.player === p else { return }
                if ok {
                    self.started = true
                } else {
                    // Stop here rather than work through the document in silence.
                    self.player = nil
                    self.isPlaying = false
                    self.onOutputFailure?()
                    self.finish(mine)
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        let p = player
        queue.async { p?.pause() }
    }

    func resume() {
        guard let p = player else { return }
        isPlaying = true
        queue.async { p.play() }
    }

    func stop() {
        let p = player
        player = nil
        isPlaying = false
        started = false
        queue.async { p?.stop() }
        finish(token)
    }

    /// Tells the caller sentence `which` is over, once only, and only if it is still the current one.
    private func finish(_ which: Int) {
        guard which == token, let f = onFinish else { return }
        onFinish = nil
        isPlaying = false
        f()
    }

    /// Lets go of a sentence that has played to its end. Without this a pause before the next sentence,
    /// followed by play, would start the finished one again.
    private func letGo() {
        let p = player
        player = nil
        started = false
        queue.async { p?.stop() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.letGo()
            self.finish(self.token)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.letGo()
            self.finish(self.token)
        }
    }
}

/// Keeps time without making a sound. Used by automated runs so the reader can be tested end to end
/// on a machine with no one listening (and no working audio output).
@MainActor
final class SilentPlayer: SentencePlayer {
    private var duration = 0.0
    private var elapsed = 0.0  // seconds of audio already "played"
    private var resumedAt: Date?
    private var onFinish: (@MainActor () -> Void)?
    private var timer: Task<Void, Never>?
    private(set) var hasSentence = false

    var rate: Double = 1 {
        didSet {
            // Re-base the clock so the change applies from now on.
            if let resumedAt { elapsed += Date().timeIntervalSince(resumedAt) * oldValue }
            if resumedAt != nil { resumedAt = Date() }
            schedule()
        }
    }

    var isPlaying: Bool { resumedAt != nil }
    var currentTime: Double {
        min(duration, elapsed + (resumedAt.map { Date().timeIntervalSince($0) * rate } ?? 0))
    }

    func play(_ samples: [Float], sampleRate: Int, rate: Double, onFinish: @escaping @MainActor () -> Void) {
        stop()
        duration = Double(samples.count) / Double(sampleRate)
        elapsed = 0
        self.rate = rate
        self.onFinish = onFinish
        hasSentence = true
        resumedAt = Date()
        schedule()
    }

    func pause() {
        guard let resumedAt else { return }
        elapsed += Date().timeIntervalSince(resumedAt) * rate
        self.resumedAt = nil
        timer?.cancel()
    }

    func resume() {
        guard hasSentence, resumedAt == nil else { return }
        resumedAt = Date()
        schedule()
    }

    func stop() {
        timer?.cancel()
        resumedAt = nil
        hasSentence = false
        let f = onFinish
        onFinish = nil
        f?()
    }

    /// Sets the timer that ends the sentence when what is left of it would have played at the current rate.
    private func schedule() {
        timer?.cancel()
        guard resumedAt != nil else { return }
        let remaining = max(0, (duration - currentTime) / max(rate, 0.1))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            self.resumedAt = nil
            self.hasSentence = false
            let f = self.onFinish
            self.onFinish = nil
            f?()
        }
    }
}
