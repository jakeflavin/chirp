import AVFoundation
import ChirpCore
import ChirpML
import Foundation

/// Captures the microphone as 16 kHz mono samples and reports a live level.
final class AudioRecorder: @unchecked Sendable {
    /// Why the microphone could not be used, in words for the user.
    enum RecorderError: LocalizedError {
        case noInput
        case microphoneDenied
        case didNotStart

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone was found."
            case .microphoneDenied: "Chirp is not allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            case .didNotStart: "The microphone did not start. Check the input in System Settings › Sound, then try again."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    /// One channel at the microphone's own rate: what the converter is given.
    private var mono: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// True from `start()` to `stop()`.
    private(set) var isRunning = false
    /// True while the microphone is open but nothing is being kept, so a dictation can start instantly.
    private(set) var isStandingBy = false
    /// True while incoming sound is kept; false while only standing by. Read on the audio thread, so only
    /// changed under `lock`.
    private var capturing = false
    /// The last moment of sound heard while standing by, so the first word is never clipped.
    private var preRoll: [Float] = []
    private let preRollSamples = 8_000  // half a second
    /// Whether the sound is also kept here, to be returned by `stop()`. A meeting recording turns this off:
    /// it takes the sound from `onSamples` and writes it to disk, so an hour of it is not held in memory twice.
    /// Set before `start()`.
    var keepsSamples = true

    /// Called on an audio thread with a 0…1 level for each chunk of sound.
    var onLevel: (@Sendable (Double) -> Void)?
    /// Called on an audio thread with each new chunk of 16 kHz samples (for live transcription).
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// For tests and for trying Chirp without microphone permission: when set, "recording" returns this file's audio.
    static var feedFile: URL? = launchFile(after: "--feed-audio")

    /// The file named after a launch flag such as `--feed-audio`, which stands in for live input in automated runs.
    static func launchFile(after flag: String) -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// Opens the microphone and keeps only the last half second, ready for `start()`.
    func standBy() throws {
        guard Self.feedFile == nil, !isRunning, !isStandingBy else { return }
        try openMicrophone()
        isStandingBy = true
    }

    /// Closes the microphone when it was only standing by.
    func endStandBy() {
        guard isStandingBy, !isRunning else {
            isStandingBy = false
            return
        }
        closeMicrophone()
        isStandingBy = false
    }

    /// Starts keeping what the microphone hears. Opens the microphone unless it was already standing by.
    func start() throws {
        if let feed = Self.feedFile {
            let fed = try AudioFile.samples(from: feed)
            lock.withLock { samples = fed }
            isRunning = true
            onLevel?(0.5)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { throw RecorderError.microphoneDenied }
        if isStandingBy {
            // Already listening: begin with what was heard just before the key went down.
            lock.withLock {
                samples = preRoll
                capturing = true
            }
        } else {
            lock.withLock {
                samples.removeAll()
                capturing = true
            }
            do { try openMicrophone() } catch {
                // Nothing is being recorded: a later stand-by must not start keeping sound.
                lock.withLock { capturing = false }
                throw error
            }
        }
        isRunning = true
    }

    /// Opens the chosen microphone and starts turning what it hears into 16 kHz mono.
    private func openMicrophone() throws {
        let input = engine.inputNode
        // Record from the microphone chosen in Settings, if it is connected.
        if let device = AudioDevices.recordingDevice() {
            do { try input.auAudioUnit.setDeviceID(device) } catch {
                Log.write("mic", "could not select \(AudioDevices.name(of: device)): \(error.localizedDescription)")
            }
            Log.write("mic", "using \(AudioDevices.name(of: device))")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        // The channels are mixed down here (`MicDownmix`), and only the change of rate is left to the
        // system's converter. Handed a microphone with three channels, as the built-in one opens while a
        // call app holds it, that converter gives back silence and no error.
        guard let single = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else {
            throw RecorderError.noInput
        }
        mono = single
        converter = AVAudioConverter(from: single, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        let began = Date()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.write("mic", "did not start after \(Int(Date().timeIntervalSince(began) * 1000)) ms: \(error.localizedDescription)")
            throw RecorderError.didNotStart
        }
        Log.write("mic", "open in \(Int(Date().timeIntervalSince(began) * 1000)) ms, \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    /// Stops listening and lets go of the microphone.
    private func closeMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Stops and returns everything captured. The microphone stays open if it was standing by.
    @discardableResult
    func stop() -> [Float] {
        if Self.feedFile == nil, isRunning {
            lock.withLock {
                capturing = false
                preRoll.removeAll(keepingCapacity: true)
            }
            if !isStandingBy { closeMicrophone() }
        }
        isRunning = false
        // The sound is handed over, not copied: nothing of a finished recording stays in memory here.
        return lock.withLock { () -> [Float] in
            let captured = samples
            samples = []
            return captured
        }
    }

    /// Samples captured so far.
    var sampleCount: Int { lock.withLock { samples.count } }

    /// A copy of what has been captured from `index` on, while recording continues.
    func samples(from index: Int) -> [Float] {
        lock.withLock { index < samples.count ? Array(samples[index...]) : [] }
    }

    /// Seconds captured so far.
    var duration: Double { Double(lock.withLock { samples.count }) / 16_000 }

    /// What the microphone delivered as one channel, whatever it has (`MicDownmix`: one or two as they
    /// are, the first two of a microphone with more). Nil when the buffer is not plain samples.
    static func mixedDown(_ buffer: AVAudioPCMBuffer, to mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let target = out.floatChannelData else { return nil }
        let count = Int(buffer.format.channelCount)
        var mixed: [Float]
        if let data = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let all = UnsafeBufferPointer(start: data[0], count: frames * count)
                mixed = MicDownmix.mono((0..<MicDownmix.channelsUsed(of: count)).map { c in stride(from: c, to: all.count, by: count).map { all[$0] } })
            } else {
                mixed = MicDownmix.mono((0..<count).map { UnsafeBufferPointer(start: data[$0], count: frames) })
            }
        } else if let data = buffer.int16ChannelData {
            let step = buffer.format.isInterleaved ? count : 1
            mixed = MicDownmix.mono((0..<MicDownmix.channelsUsed(of: count)).map { c in
                let source = buffer.format.isInterleaved ? data[0] + c : data[c]
                return (0..<frames).map { Float(source[$0 * step]) / 32_768 }
            })
        } else {
            return nil
        }
        guard mixed.count == frames else { return nil }
        mixed.withUnsafeBufferPointer { target[0].update(from: $0.baseAddress!, count: frames) }
        out.frameLength = buffer.frameLength
        return out
    }

    /// TESTING (a debug link): a tone in a microphone format of `channels` channels with no speaker layout,
    /// as the built-in microphone has during a call, put through the system's converter alone (how it
    /// was) and through `mixedDown` first (how it is). Returns the loudest sample each way.
    static func channelTrial(channels: UInt32) -> (before: Float, after: Float) {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels),
            let single = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        else { return (-1, -1) }
        let format = channels <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)! : AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800), let data = buffer.floatChannelData else { return (-1, -1) }
        buffer.frameLength = 4800
        for c in 0..<Int(channels) { for i in 0..<4800 { data[c][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 48_000) } }
        func peak(_ source: AVAudioPCMBuffer?) -> Float {
            guard let source, let converter = AVAudioConverter(from: source.format, to: target),
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1700)
            else { return -1 }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return source
            }
            guard error == nil, let samples = out.floatChannelData else { return -1 }
            return (0..<Int(out.frameLength)).reduce(Float(0)) { max($0, abs(samples[0][$1])) }
        }
        return (peak(buffer), peak(mixedDown(buffer, to: single)))
    }

    /// Runs on an audio thread for each buffer: converts it to 16 kHz mono, then keeps it (recording) or
    /// only its last half second (standing by).
    private func process(_ input: AVAudioPCMBuffer) {
        guard let converter, let mono, let buffer = Self.mixedDown(input, to: mono) else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        let keeping = lock.withLock { () -> Bool in
            if capturing {
                if keepsSamples { samples.append(contentsOf: chunk) }
            } else {
                preRoll.append(contentsOf: chunk)
                if preRoll.count > preRollSamples { preRoll.removeFirst(preRoll.count - preRollSamples) }
            }
            return capturing
        }
        // While only standing by, nothing leaves this function: no levels, no samples.
        guard keeping else { return }
        onSamples?(chunk)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        // Map roughly -50 dB…-10 dB onto 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(Double(max(0, min(1, (db + 50) / 40))))
    }
}
