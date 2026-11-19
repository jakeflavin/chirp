import Darwin
import Foundation
import TranscribeCpp

// Process isolation for the speech engine.
//
// All of the engine's native code (GPU setup, model load, transcription) runs in a child process: the
// app's own executable launched again with `SpeechWorker.flag`. A GPU driver fault, an assert in the
// engine, or a hang then takes down only the worker. The worker lives exactly as long as the model, so
// unloading gives all of its processor and GPU memory back to macOS. If the worker dies or stops
// answering while on the GPU, the next one runs on the processor only.

/// What a transcription returns across the process boundary.
struct SpeechResult: Codable, Sendable {
    /// One word with where it starts (`t0`) and ends (`t1`), in milliseconds from the start of the audio.
    struct Word: Codable, Sendable {
        var text: String
        var t0: Int64
        var t1: Int64
    }
    var text: String
    var words: [Word]
}

/// The kind of a message on the pipe. Each message is one kind byte, a four-byte little-endian length,
/// then that many bytes of payload. Requests are below 100 and replies above, so one can never be taken
/// for the other.
private enum Frame: UInt8 {
    case load = 1, run = 2
    /// `backendFailed` is a failed run whose cause was the compute backend, which can leave the worker
    /// of no further use. `failed` is any other refusal.
    case loaded = 101, transcript = 102, failed = 103, backendFailed = 104
}

/// Faults a test run can ask the worker for, through the `CHIRP_WORKER_FAULT` environment variable
/// Nothing sets it in normal use. Entries are separated by commas:
/// - `delay:<seconds>` waits that long before each transcription;
/// - `backend:<marker file>` makes every transcription fail with a backend error in the first worker to
///   reach one (the marker file records which that was), and work as usual in later workers;
/// - `backend-gpu` makes every transcription fail with a backend error in any worker on the GPU;
/// - `fail:<n>:<count file>` makes the first n transcriptions fail with an ordinary error (the file counts them).
/// The one-second clips used to warm the model up and to time it are never affected.
struct WorkerFaults {
    var delay: Double = 0
    var backendMarker: String?
    var backendOnGPU = false
    var failCount = 0
    var failFile: String?
    /// This worker is the one the marker picked.
    var chosen = false
    /// Whether this worker has already looked at the marker.
    var decided = false

    init(_ text: String? = ProcessInfo.processInfo.environment["CHIRP_WORKER_FAULT"]) {
        for entry in (text ?? "").split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "delay": delay = Double(parts.count > 1 ? parts[1] : "") ?? 0
            case "backend": backendMarker = parts.count > 1 ? parts[1] : nil
            case "backend-gpu": backendOnGPU = true
            case "fail":
                let rest = (parts.count > 1 ? parts[1] : "").split(separator: ":", maxSplits: 1).map(String.init)
                failCount = Int(rest.first ?? "") ?? 0
                failFile = rest.count > 1 ? rest[1] : nil
            default: break
            }
        }
    }

    /// Applies the faults to one transcription. Throws when it is to fail.
    mutating func apply(sampleCount: Int, onGPU: Bool) throws {
        // Warm-up and timing clips are a second long; real audio handed over is longer or padded past it.
        guard sampleCount > 16_000 else { return }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if backendOnGPU, onGPU { throw SpeechError.backend("injected backend error") }
        if let failFile, failCount > 0 {
            let done = ((try? FileManager.default.attributesOfItem(atPath: failFile)[.size]) as? Int) ?? 0
            if done < failCount {
                if let handle = FileHandle(forWritingAtPath: failFile) ?? { FileManager.default.createFile(atPath: failFile, contents: nil); return FileHandle(forWritingAtPath: failFile) }() {
                    handle.seekToEndOfFile()
                    handle.write(Data("x".utf8))
                    try? handle.close()
                }
                throw SpeechError.engine("injected failure")
            }
        }
        if let backendMarker {
            if !decided {
                decided = true
                // Only one process can create the file: that one is the worker that fails.
                let descriptor = open(backendMarker, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if descriptor >= 0 {
                    close(descriptor)
                    chosen = true
                }
            }
            if chosen { throw SpeechError.backend("injected backend error") }
        }
    }
}

/// The payload of a `load` message, as JSON: which model file, and whether to keep off the GPU.
private struct LoadRequest: Codable {
    var path: String
    var cpuOnly: Bool
}

/// The five bytes that start a frame: the kind, then the payload's length.
private func frameHeader(_ kind: Frame, byteCount: Int) throws -> Data {
    // The length travels as four bytes. Audio that long (over 18 hours) is refused, not cut short.
    guard let length = UInt32(exactly: byteCount) else {
        throw SpeechError.unreadableAudio("the recording is too long to transcribe in one piece")
    }
    var header = Data([kind.rawValue])
    withUnsafeBytes(of: length.littleEndian) { header.append(contentsOf: $0) }
    return header
}

/// Writes one frame: the kind, the payload's length, then the payload.
private func write(_ kind: Frame, _ payload: Data, to handle: FileHandle) throws {
    try handle.write(contentsOf: try frameHeader(kind, byteCount: payload.count))
    if !payload.isEmpty { try handle.write(contentsOf: payload) }
}

/// Writes one frame whose payload is the samples themselves, straight from the array. A long recording
/// is tens of megabytes, so it is not copied into a second buffer first.
private func write(_ kind: Frame, samples: [Float], to handle: FileHandle) throws {
    try handle.write(contentsOf: try frameHeader(kind, byteCount: samples.count * MemoryLayout<Float>.size))
    try samples.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, raw.count > 0 else { return }
        // The array outlives the write, so the data can point at it without owning it.
        let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none)
        try handle.write(contentsOf: bytes)
    }
}

/// Reads exactly `count` bytes, or nil when the other side has closed the pipe first.
private func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data()
    while data.count < count {
        guard let more = try? handle.read(upToCount: count - data.count), !more.isEmpty else { return nil }
        data.append(more)
    }
    return data
}

/// Reads the start of a frame: its kind and how many bytes of payload follow. Nil when the other side has
/// closed the pipe.
private func readHeader(from handle: FileHandle) -> (kind: Frame, byteCount: Int)? {
    guard let header = readExactly(5, from: handle), let kind = Frame(rawValue: header[header.startIndex]) else { return nil }
    let length = header.dropFirst().withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    return (kind, Int(length))
}

/// Reads one frame, or nil when the other side has closed the pipe.
private func read(from handle: FileHandle) -> (kind: Frame, payload: Data)? {
    guard let header = readHeader(from: handle), let payload = readExactly(header.byteCount, from: handle) else { return nil }
    return (header.kind, payload)
}

/// Reads a payload of samples straight into an array, so a long recording is held once, not twice.
/// Nil when the other side has closed the pipe first.
private func readSamples(byteCount: Int, from handle: FileHandle) -> [Float]? {
    let size = MemoryLayout<Float>.size
    var samples = [Float](repeating: 0, count: byteCount / size)
    let descriptor = handle.fileDescriptor
    let complete = samples.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var done = 0
        while done < raw.count {
            let got = Darwin.read(descriptor, base + done, raw.count - done)
            if got > 0 {
                done += got
            } else if got < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
    guard complete else { return nil }
    // Bytes that do not make up a whole sample are still part of the frame: take them off the pipe.
    if byteCount % size != 0, readExactly(byteCount % size, from: handle) == nil { return nil }
    return samples
}

/// The child process: loads the model it is told to and transcribes what it is sent, until the app
/// closes the pipe.
public enum SpeechWorker {
    /// The first argument that makes the app's executable run as the worker instead of as the app.
    public static let flag = "--transcribe-worker"

    /// Whether this process was launched as the speech worker. Checked before the app starts.
    public static var isWorkerInvocation: Bool {
        CommandLine.arguments.count > 1 && CommandLine.arguments[1] == flag
    }

    /// The worker's whole life: answer one request at a time from standard input on standard output,
    /// and exit when the app closes its end. An error is sent back as a `failed` reply, not a crash,
    /// so the app can tell an engine error from a dead worker.
    public static func run() -> Never {
        // Keep the reply pipe to ourselves: anything a library prints goes to the error stream instead.
        let replies = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let requests = FileHandle.standardInput
        let engine = SpeechEngine()
        var faults = WorkerFaults()
        var onGPU = false
        // If the app is killed while the engine is stuck, nothing closes the pipe for this process to
        // notice, and it would stay behind holding the model. So watch for the app going away.
        let app = getppid()
        Thread.detachNewThread {
            while true {
                sleep(2)
                // `_exit`, not `exit`: the engine may be stuck, and its clean-up must not be run from here.
                if getppid() != app { _exit(0) }
            }
        }
        serving: while let header = readHeader(from: requests) {
            do {
                switch header.kind {
                case .load:
                    guard let payload = readExactly(header.byteCount, from: requests) else { break serving }
                    let request = try JSONDecoder().decode(LoadRequest.self, from: payload)
                    let backend = try engine.load(path: request.path, backend: request.cpuOnly ? .cpu : .auto)
                    onGPU = !request.cpuOnly && !backend.isEmpty && backend.lowercased() != "cpu"
                    try write(.loaded, Data(backend.utf8), to: replies)
                case .run:
                    guard let samples = readSamples(byteCount: header.byteCount, from: requests) else { break serving }
                    try faults.apply(sampleCount: samples.count, onGPU: onGPU)
                    try write(.transcript, try JSONEncoder().encode(engine.run(samples)), to: replies)
                default:
                    guard readExactly(header.byteCount, from: requests) != nil else { break serving }
                    try write(.failed, Data("unexpected request".utf8), to: replies)
                }
            } catch SpeechError.backend(let why) {
                // Its own reply, so the app can replace this worker: after a backend error it may never work again.
                try? write(.backendFailed, Data(why.utf8), to: replies)
            } catch {
                try? write(.failed, Data(error.localizedDescription.utf8), to: replies)
            }
        }
        // The engine's GPU library stops the process if a model is still loaded at exit.
        engine.unload()
        exit(0)
    }
}

/// The app's side: owns the one worker and hides its restarts and fallbacks.
final class SpeechSupervisor: @unchecked Sendable {
    /// Guards everything below. It is held for the whole of a load or a transcription, so requests
    /// reach the worker one at a time. Methods named `…Locked` must be called with it held.
    private let lock = NSLock()
    private var process: Process?
    /// The worker's standard input: requests go out here. Closing it tells the worker to exit.
    private var toWorker: FileHandle?
    /// The worker's standard output: replies come back here.
    private var fromWorker: FileHandle?
    /// The model file in use, or nil when unloaded. Kept while a crashed worker is replaced, so the
    /// model still counts as loaded and the next request starts a new worker.
    private var loadedPath: String?
    /// The worker in use was started for the processor only.
    private var cpuOnly = false
    /// The user chose the processor.
    private var userWantsCPU = false

    /// Guards the few values below, and is only ever held for a moment. They are read from the main
    /// thread (the Speak page, quitting), which must never wait behind a transcription for `lock`.
    private let stateLock = NSLock()
    private var gpuFailedFlag = false
    private var noteHandler: (@Sendable (String) -> Void)?
    private var loadedBackend = ""
    /// The running worker's process id, so `stopNow()` can end it without waiting for `lock`.
    private var workerPID: pid_t?
    /// `stopNow()` ended the worker in the middle of a request: that request must fail, not start a new worker.
    private var stoppingFlag = false
    /// A transcription is with the worker right now.
    private var runInFlight = false
    /// `cancelRun()` ended the worker in the middle of a transcription: it fails as cancelled, with no retry.
    private var cancellingFlag = false
    private var runs = 0
    private var starts = 0
    /// The GPU worker before this one ended on a backend error and no transcription has succeeded on the
    /// GPU since. A second one in a row moves speech to the processor. Guarded by `lock`.
    private var gpuBackendError = false

    /// Transcriptions sent to a worker since launch, retries included (diagnostics).
    var runCount: Int { stateLock.withLock { runs } }
    /// Workers started since launch (diagnostics).
    var workerStarts: Int { stateLock.withLock { starts } }

    /// A GPU worker crashed or hung: stay on the processor until `retryGPU()`.
    private var gpuFailed: Bool {
        get { stateLock.withLock { gpuFailedFlag } }
        set { stateLock.withLock { gpuFailedFlag = newValue } }
    }
    private var stopping: Bool {
        get { stateLock.withLock { stoppingFlag } }
        set { stateLock.withLock { stoppingFlag = newValue } }
    }
    /// Called with a line for the log when the worker is restarted or falls back.
    var note: (@Sendable (String) -> Void)? {
        get { stateLock.withLock { noteHandler } }
        set { stateLock.withLock { noteHandler = newValue } }
    }
    /// What the model last loaded on, e.g. "Metal". Changes when a GPU failure moves it to the processor.
    var backendName: String { stateLock.withLock { loadedBackend } }

    // Three minutes to load, at least a minute to answer: a large model on a busy Mac can need that long.
    private static let loadTimeout: Double = 180
    /// Seconds a worker gets to exit by itself after its input closes, before it is killed.
    private static let shutdownGrace: Double = 2
    /// Seconds to wait for a transcription: ten times the length of the audio, and never under a
    /// minute (five minutes on the processor, which is much slower).
    private static func runTimeout(samples: Int, cpuOnly: Bool) -> Double {
        let audio = Double(samples) / 16_000
        return cpuOnly ? max(300, audio * 10) : max(60, audio * 10)
    }

    /// The model counts as loaded while its worker is being replaced after a crash.
    var isLoaded: Bool { lock.withLock { loadedPath != nil } }

    /// Starts a worker and loads the model in it. Returns the name of what it runs on.
    func load(path: String, backend: Backend) throws -> String {
        try lock.withLock {
            stopping = false
            userWantsCPU = backend == .cpu
            return try loadLocked(path: path, wantCPU: userWantsCPU || gpuFailed)
        }
    }

    /// Replaces any worker with a fresh one that has the model loaded. Falls back to the processor when
    /// the GPU cannot load it, unless the user chose the processor (then there is nothing to fall back to).
    private func loadLocked(path: String, wantCPU: Bool) throws -> String {
        stopLocked()
        do {
            return try startLocked(path: path, cpuOnly: wantCPU)
        } catch where !wantCPU && !userWantsCPU && !stopping {
            // A GPU that fails to load the model is retried on the processor.
            note?("speech worker could not load on the GPU (\(error.localizedDescription)); using the processor")
            gpuFailed = true
            stopLocked()
            return try startLocked(path: path, cpuOnly: true)
        }
    }

    /// Launches the app's own executable as a worker, wires up its pipes, and asks it to load the model.
    /// Returns the name of what the model runs on.
    private func startLocked(path: String, cpuOnly: Bool) throws -> String {
        guard let executable = Bundle.main.executableURL else { throw SpeechError.notLoaded }
        let process = Process()
        process.executableURL = executable
        process.arguments = [SpeechWorker.flag]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Writing to a worker that has just died must fail with an error. Without this the write raises
        // SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.process = process
        let pid = process.processIdentifier
        stateLock.withLock {
            workerPID = pid
            starts += 1
        }
        toWorker = input.fileHandleForWriting
        fromWorker = output.fileHandleForReading
        self.cpuOnly = cpuOnly
        do {
            let request = try JSONEncoder().encode(LoadRequest(path: path, cpuOnly: cpuOnly))
            let reply = try callLocked(timeout: Self.loadTimeout) { try write(.load, request, to: $0) }
            guard reply.kind == .loaded else { throw SpeechError.engine(String(decoding: reply.payload, as: UTF8.self)) }
            loadedPath = path
            let name = String(decoding: reply.payload, as: UTF8.self)
            stateLock.withLock { loadedBackend = name }
            return name
        } catch {
            // A worker that could not load the model is of no use: do not leave it running.
            stopLocked()
            throw error
        }
    }

    /// Transcribes, retrying once:
    /// after a crash or hang on the GPU, on the processor; after a crash on the processor, in a fresh
    /// worker; never after a hang or a backend error on the processor. A first backend error on the GPU
    /// is tried again in a fresh GPU worker without using up that retry; a second in a row moves to the
    /// processor.
    func run(_ samples: [Float]) throws -> SpeechResult {
        try lock.withLock {
            guard let path = loadedPath else { throw SpeechError.notLoaded }
            stopping = false
            var retried = false
            while true {
                if process?.isRunning != true { _ = try loadLocked(path: path, wantCPU: userWantsCPU || gpuFailed) }
                do {
                    stateLock.withLock {
                        runs += 1
                        cancellingFlag = false
                        runInFlight = true
                    }
                    defer { stateLock.withLock { runInFlight = false } }
                    let reply = try callLocked(timeout: Self.runTimeout(samples: samples.count, cpuOnly: cpuOnly)) {
                        try write(.run, samples: samples, to: $0)
                    }
                    let result = try decode(reply)
                    // A run succeeded: a later backend error on the GPU is a new one.
                    if !cpuOnly { gpuBackendError = false }
                    return result
                } catch let failure as SpeechError where failure.losesWorker {
                    if stopping {
                        // The worker was ended on purpose by `stopNow()`: the model is unloaded, and this
                        // request fails without a retry.
                        loadedPath = nil
                        throw failure
                    }
                    if stateLock.withLock({ cancellingFlag }) {
                        // Ended on purpose by `cancelRun()`: no retry, and the model still counts as loaded.
                        stateLock.withLock { cancellingFlag = false }
                        loadedPath = path
                        throw SpeechError.cancelled
                    }
                    let onGPU = !cpuOnly
                    var isBackend = false
                    var freshGPU = false
                    if case .backend = failure {
                        isBackend = true
                        // The worker answered, so it is still running; it is replaced all the same.
                        stopLocked()
                        if onGPU, !gpuBackendError {
                            gpuBackendError = true
                            freshGPU = true
                        } else if onGPU {
                            gpuFailed = true
                        }
                    } else if onGPU {
                        gpuFailed = true
                    }
                    loadedPath = path  // Still the model in use while its worker is replaced.
                    if (!onGPU && (failure == .workerHung || isBackend)) || (retried && !freshGPU) { throw failure }
                    if freshGPU {
                        note?("speech worker reported a backend error on the GPU; retrying in a fresh GPU worker")
                    } else {
                        retried = true
                        let what = isBackend ? "reported a second backend error" : failure == .workerHung ? "did not answer" : "stopped"
                        note?("speech worker \(what) on the \(onGPU ? "GPU; retrying on the processor" : "processor; retrying in a fresh worker")")
                    }
                }
            }
        }
    }

    /// Ends the worker if a transcription is with it right now, from any thread and without waiting. That
    /// transcription fails as cancelled and is not retried; the model still counts as loaded, and the
    /// next use starts a fresh worker. Otherwise does nothing.
    func cancelRun() {
        let pid = stateLock.withLock { () -> pid_t? in
            guard runInFlight, let workerPID else { return nil }
            cancellingFlag = true
            return workerPID
        }
        if let pid {
            note?("speech worker stopped: the transcription was cancelled")
            kill(pid, SIGKILL)
        }
    }

    /// Whether a GPU worker crashed or hung, so models now load on the processor.
    var gpuUnavailable: Bool { gpuFailed }

    /// An explicit change of the GPU/processor setting forgets the GPU failure, so the next
    /// load may use the GPU again. A new failure sets it again.
    func retryGPU() {
        let wasFailed = stateLock.withLock { () -> Bool in
            let was = gpuFailedFlag
            gpuFailedFlag = false
            return was
        }
        if wasFailed { note?("speech GPU no longer marked unavailable: the setting changed") }
    }

    /// Turns a reply into a result. Any reply other than a transcript carries the engine's error text.
    private func decode(_ reply: (kind: Frame, payload: Data)) throws -> SpeechResult {
        if reply.kind == .backendFailed { throw SpeechError.backend(String(decoding: reply.payload, as: UTF8.self)) }
        guard reply.kind == .transcript else { throw SpeechError.engine(String(decoding: reply.payload, as: UTF8.self)) }
        return try JSONDecoder().decode(SpeechResult.self, from: reply.payload)
    }

    /// Sends a request (`send` writes it to the worker's input) and waits for the answer. A worker that
    /// has died or does not answer in time is killed, and the call fails as crashed or hung.
    private func callLocked(timeout: Double, send: (FileHandle) throws -> Void) throws -> (kind: Frame, payload: Data) {
        guard let toWorker, let fromWorker, process?.isRunning == true else { throw SpeechError.workerCrashed }
        do { try send(toWorker) } catch {
            // Audio too long to send is refused before anything is written: the worker is still fine.
            if let refused = error as? SpeechError, case .unreadableAudio = refused { throw refused }
            stopLocked()
            throw SpeechError.workerCrashed
        }
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(read(from: fromWorker))
            done.signal()
        }
        var hung = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            hung = true
            note?("speech worker did not answer in \(Int(timeout)) s; stopping it")
            if let process { kill(process.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + Self.shutdownGrace)
        }
        guard !hung, let reply = box.get() else {
            let path = loadedPath
            stopLocked()
            loadedPath = path
            throw hung ? SpeechError.workerHung : SpeechError.workerCrashed
        }
        return reply
    }

    /// Stops the worker, which frees the model and all of its memory. Waits for a request in progress.
    func unload() { lock.withLock { stopLocked() } }

    /// Stops the worker without waiting for a request in progress, for when the app quits. An idle worker
    /// is closed in the usual way. A busy one is killed: its request then fails, and is not retried.
    func stopNow() {
        if lock.`try`() {
            stopLocked()
            lock.unlock()
            return
        }
        let pid = stateLock.withLock { () -> pid_t? in
            stoppingFlag = true
            return workerPID
        }
        if let pid { kill(pid, SIGKILL) }
    }

    /// Closes the worker's input, gives it a moment to unload and exit by itself, then kills it if it is
    /// still there. Also forgets the loaded model;
    /// callers that are only replacing the worker put `loadedPath` back.
    private func stopLocked() {
        stateLock.withLock { workerPID = nil }
        loadedPath = nil
        try? toWorker?.close()  // The worker exits when its input closes.
        toWorker = nil
        if let process, process.isRunning {
            let deadline = Date().addingTimeInterval(Self.shutdownGrace)
            while process.isRunning, Date() < deadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? fromWorker?.close()
        fromWorker = nil
        process = nil
    }
}

/// Carries the worker's reply from the thread that reads the pipe to the one waiting on it. Stays empty
/// when the worker died or the wait timed out.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (kind: Frame, payload: Data)?
    func set(_ v: (kind: Frame, payload: Data)?) { lock.withLock { value = v } }
    func get() -> (kind: Frame, payload: Data)? { lock.withLock { value } }
}

extension SpeechError {
    /// The worker this happened in is gone or must be replaced: it died, stopped answering, or its
    /// compute backend failed.
    var losesWorker: Bool {
        switch self {
        case .workerCrashed, .workerHung, .backend: true
        default: false
        }
    }
}
