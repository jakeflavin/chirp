import ChirpCore
import Darwin
import Foundation

// A helper process for one model, and the app's side of it. The reading voice, voice detection, speaker
// labelling and the MLX models (the language model, the search model and the sentence checker, which share
// one: `LanguageWorker`) each run in one; speech has its own in `SpeechWorker`. So the app process loads no
// model: a fault in a model ends only its helper, and ending the helper gives all of its memory back.
//
// The pattern: the app's own executable started again with a flag; requests and replies as framed messages
// on its standard input and output; no request retried by itself; the next request after a death starts a
// fresh helper; a limit on restarts; a limit on silence; a cancel that is asked for first and enforced after
// a few seconds.
//
// Every request carries a number and its reply carries the same one, so several requests can be with the
// helper at once and none waits on another.

/// What can go wrong with a helper, in words for the user. `what` is the thing that runs in it, as it
/// reads in a sentence: "reading voice", "voice detection", "speaker labelling".
public enum HelperError: LocalizedError, Equatable {
    /// The helper went away in the middle of a request (it crashed, or macOS ended it).
    case stopped(String)
    /// The helper stopped answering and was ended.
    case noAnswer(String)
    /// The helper has gone away several times in a row; it is left alone for a minute.
    case keepsStopping(String)
    /// The model itself refused the request, with its reason.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .stopped(let what): "The \(what) stopped unexpectedly. Try again."
        case .noAnswer(let what): "The \(what) did not answer. Try again."
        case .keepsStopping(let what): "The \(what) keeps stopping. Try again in a minute."
        case .refused(let why): why
        }
    }
}

/// The kind of a message on the pipe. Requests are below 100 and replies above.
enum HelperFrameKind: UInt8 {
    /// A request, and the cancelling of one by its number.
    case request = 1, cancel = 2
    /// The things that can come back for a request: word that it is still at work (a download), its
    /// answer, a refusal with the reason, word that it was cancelled, and the next piece of an answer that
    /// streams (generated text, or one answer of a batch).
    case progress = 101, reply = 102, failed = 103, cancelled = 104, partial = 105
}

/// One message: its kind, the number of the request it belongs to, the name of what is asked (requests
/// only), a small piece of JSON and, for sound, a block of raw bytes.
struct HelperFrame: Sendable {
    var kind: HelperFrameKind
    var id: UInt32
    var op: String = ""
    var json = Data()
    var blob = Data()

    /// The frame as bytes: kind, id, the three lengths, then op, JSON and blob.
    var encoded: Data {
        var out = start(blobCount: blob.count)
        out.append(blob)
        return out
    }

    /// Everything but the blob, for a frame whose blob of `blobCount` bytes is written straight after it
    /// (sound is written from where it is, not copied into the frame first).
    func start(blobCount: Int) -> Data {
        let name = Data(op.utf8)
        var out = Data([kind.rawValue])
        for value in [id, UInt32(name.count), UInt32(json.count), UInt32(blobCount)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(name)
        out.append(json)
        return out
    }

    /// Reads one frame, or nil when the other side has closed the pipe (or sent something that is not a frame).
    static func read(from handle: FileHandle) -> HelperFrame? {
        func exactly(_ count: Int) -> Data? {
            var data = Data()
            while data.count < count {
                guard let more = try? handle.read(upToCount: count - data.count), !more.isEmpty else { return nil }
                data.append(more)
            }
            return data
        }
        guard let header = exactly(17), let kind = HelperFrameKind(rawValue: header[header.startIndex]) else { return nil }
        func field(_ index: Int) -> Int {
            Int(header.dropFirst(1 + index * 4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        guard let name = exactly(field(1)), let json = exactly(field(2)), let blob = exactly(field(3)) else { return nil }
        return HelperFrame(kind: kind, id: UInt32(field(0)), op: String(decoding: name, as: UTF8.self), json: json, blob: blob)
    }
}

/// The helper's side: reads requests, runs each with the handler for its name, and writes the answers.
public enum HelperWorker {
    /// What a handler is given and gives back: the request's JSON and bytes, a way to report progress,
    /// and the answer's JSON and bytes.
    typealias Handler = @Sendable (_ json: Data, _ blob: Data, _ progress: @Sendable (Double) -> Void) async throws -> (json: Data, blob: Data)
    /// A handler whose answer also comes in pieces as it is made: each `partial` call sends one to the app
    /// ahead of the answer itself.
    typealias StreamingHandler = @Sendable (
        _ json: Data, _ blob: Data, _ progress: @Sendable (Double) -> Void, _ partial: @Sendable (Data) -> Void
    ) async throws -> (json: Data, blob: Data)

    /// The priority the app's own work on the main actor has: in the app these models ran at it, and at the
    /// next one down the voice's first sentence after a load took 0.7 s longer.
    static let interactive = TaskPriority(rawValue: 33)

    /// The arguments after the executable's name when it was started as a helper: the flag, then the role.
    static var arguments: [String] { Array(CommandLine.arguments.dropFirst()) }

    /// The requests in progress, so a cancel can reach one, and the test fault in force.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UInt32: Task<Void, Never>] = [:]
        private var faultText = ""
        func add(_ id: UInt32, _ task: Task<Void, Never>) { lock.withLock { tasks[id] = task } }
        func remove(_ id: UInt32) { lock.withLock { tasks[id] = nil } }
        func cancel(_ id: UInt32) { lock.withLock { tasks[id] }?.cancel() }
        var fault: String {
            get { lock.withLock { faultText } }
            set { lock.withLock { faultText = newValue } }
        }
    }

    /// The helper's whole life: answer requests from standard input on standard output, and exit when the
    /// app closes its end. An error is sent back as a `failed` reply, not a crash, so the app can tell a
    /// refused request from a dead helper.
    static func serve(_ handlers: [String: Handler], priority: TaskPriority = HelperWorker.interactive) -> Never {
        serve(streaming: handlers.mapValues { handler -> StreamingHandler in
            { json, blob, progress, _ in try await handler(json, blob, progress) }
        }, priority: priority)
    }

    /// `serve`, for handlers that may stream their answers. Each request runs at `priority`.
    static func serve(streaming handlers: [String: StreamingHandler], priority: TaskPriority = HelperWorker.interactive) -> Never {
        // Keep the reply pipe to ourselves: anything a library prints goes to the error stream instead.
        let out = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        // A reply written after the app has gone must fail quietly, not end the helper with a signal.
        signal(SIGPIPE, SIG_IGN)
        // If the app is killed while the model is busy, nothing closes the pipe for this process to
        // notice, and it would stay behind holding the model. So watch for the app going away.
        let app = getppid()
        Thread.detachNewThread {
            while true {
                sleep(2)
                if getppid() != app { _exit(0) }
            }
        }
        let writing = NSLock()
        let send: @Sendable (HelperFrame) -> Void = { frame in
            let bytes = frame.encoded
            writing.withLock { try? out.write(contentsOf: bytes) }
        }
        let state = State()
        Thread.detachNewThread {
            let requests = FileHandle.standardInput
            // Each frame in a pool of its own: this thread never returns to one, and without it every
            // block of sound read off the pipe stayed in memory (the helper grew by the size of all it was sent).
            while let frame = autoreleasepool(invoking: { HelperFrame.read(from: requests) }) {
                autoreleasepool {
                switch frame.kind {
                case .cancel:
                    state.cancel(frame.id)
                case .request:
                    // TESTING only: the app's debug link sets a fault for the requests that follow.
                    if frame.op == "_fault" {
                        state.fault = String(decoding: frame.json, as: UTF8.self)
                        send(HelperFrame(kind: .reply, id: frame.id))
                        return
                    }
                    guard let handler = handlers[frame.op] else {
                        send(HelperFrame(kind: .failed, id: frame.id, json: Data("unexpected request".utf8)))
                        return
                    }
                    let fault = HelperFault(state.fault, op: frame.op)
                    let id = frame.id
                    let task = Task(priority: priority) {
                        defer { state.remove(id) }
                        do {
                            fault.applyAtStart()
                            let answer = try await handler(frame.json, frame.blob, { fraction in
                                send(HelperFrame(kind: .progress, id: id, json: Data(String(fraction).utf8)))
                            }, { piece in
                                send(HelperFrame(kind: .partial, id: id, json: piece))
                            })
                            try Task.checkCancellation()
                            send(HelperFrame(kind: .reply, id: id, json: answer.json, blob: answer.blob))
                        } catch is CancellationError {
                            send(HelperFrame(kind: .cancelled, id: id))
                        } catch {
                            send(HelperFrame(kind: .failed, id: id, json: Data(error.localizedDescription.utf8)))
                        }
                    }
                    state.add(id, task)
                default:
                    break
                }
                }
            }
            // The app closed the pipe: the model is no longer wanted. `_exit`, not `exit`: a request may
            // still be at work, and the libraries' own clean-up must not race it. macOS takes the memory back.
            _exit(0)
        }
        dispatchMain()
    }
}

/// A fault a test asked for (see `ModelHelper.testFault`): `kill:<op>` ends the helper as that request
/// starts, `kill-after:<op>:<milliseconds>` ends it that long into the request, `hang:<op>` never answers
/// it. An op of `*` means every request.
struct HelperFault: Sendable {
    var kills = false
    var killAfter: Double?
    var hangs = false

    init(_ text: String, op: String) {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts[1] == op || parts[1] == "*" else { return }
        switch parts[0] {
        case "kill": kills = true
        case "kill-after": killAfter = (Double(parts.count > 2 ? parts[2] : "") ?? 0) / 1000
        case "hang": hangs = true
        default: break
        }
    }

    func applyAtStart() {
        // SIGKILL: the helper is gone at once, as when macOS ends it for memory, and nothing is reported.
        if kills { kill(getpid(), SIGKILL) }
        if let killAfter {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: killAfter)
                kill(getpid(), SIGKILL)
            }
        }
        if hangs { while true { sleep(1000) } }
    }
}

/// The app's side of one helper: starts it when a request needs it, sends requests, hands back answers,
/// and deals with a helper that dies, hangs or will not stop.
public final class ModelHelper: @unchecked Sendable {
    /// Called with a line for the app's log when a helper starts, stops, dies or is ended. Set once by the app.
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?

    /// What the helper is started with after the executable: its flag and, if it has one, its role.
    private let arguments: [String]
    /// The priority macOS gives the helper's process.
    private let qualityOfService: QualityOfService
    /// What runs in it, for messages ("reading voice") and for the log ("reading voice helper").
    let what: String

    /// One request with the helper: who to answer, and the timer that ends a helper gone silent.
    private struct Pending {
        var continuation: CheckedContinuation<HelperFrame, Error>
        var progress: (@Sendable (Double) -> Void)?
        var partial: (@Sendable (Data) -> Void)?
        var silence: Double
        var watchdog: DispatchWorkItem
        /// Whether its answer counts as the helper working, for the restart limit.
        var succeeds: Bool
    }

    /// Guards everything below; only ever held for a moment.
    private let lock = NSLock()
    private var process: Process?
    private var toHelper: FileHandle?
    private var pending: [UInt32: Pending] = [:]
    /// Held while a frame is written, so two requests' bytes are never mixed on the pipe (they were, when a
    /// recording asked about both of its sides at once, and the helper took the muddle for the end).
    private let writing = NSLock()
    private var nextID: UInt32 = 0
    /// Helpers started since launch. Also the number of the running one: a model loaded in helper 3 is
    /// gone once the count says 4.
    private var starts = 0
    private var restarts = RestartLimit()
    /// The helper was ended on purpose: because it did not answer in time, or by `stop()`.
    private var timedOut = false
    private var stopping = false
    /// TESTING only: a fault for the requests that follow (see `HelperFault`). Sent to each new helper.
    private var faultText = ""
    /// Starting and stopping, one at a time.
    private let startGate = TurnGate()

    /// Seconds a helper gets to answer a cancel before it is ended.
    static let cancelGrace: Double = 5
    /// Seconds a helper gets to exit by itself after its input closes, before it is killed.
    static let shutdownGrace: Double = 2

    public init(arguments: [String], what: String, qualityOfService: QualityOfService = .userInteractive) {
        self.arguments = arguments
        self.what = what
        self.qualityOfService = qualityOfService
        Self.registry.withLock { Self.known.append(Weak(helper: self)) }
    }

    // MARK: Every helper, for the app's state read-back and test links

    private struct Weak { weak var helper: ModelHelper? }
    private static let registry = NSLock()
    nonisolated(unsafe) private static var known: [Weak] = []

    /// Every helper the app has made, by what runs in it.
    public static var all: [ModelHelper] { registry.withLock { known.compactMap(\.helper) } }
    /// What runs in this helper, as its messages name it.
    public var name: String { what }

    /// The running helper's number, or nil when there is none.
    public var running: Int? { lock.withLock { process?.isRunning == true ? starts : nil } }
    /// Helpers started since launch (diagnostics).
    public var helperStarts: Int { lock.withLock { starts } }
    /// The running helper's process id (diagnostics and tests).
    public var helperPID: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }

    /// TESTING only (debug links): see `HelperFault`. An empty string clears it.
    public func setTestFault(_ fault: String) async {
        lock.withLock { faultText = fault }
        if running != nil { _ = try? await call("_fault", json: Data(fault.utf8), silence: 10, starting: false) }
    }

    // MARK: Requests

    /// Sends a request and waits for its answer. Starts a helper if none is running (unless `starting` is
    /// false). `silence` is how long the helper may go without a word on this request before it is ended.
    /// When the calling task is cancelled the helper is told to stop the request, and is ended if it does not.
    /// Sound goes as `samples`: it is written to the pipe from the array itself, so a long recording is
    /// not held two or three times over while it is sent. `partial` gets each piece of a streamed answer,
    /// in order, before the call returns; each piece, like progress, starts the silence again. With
    /// `succeeds` false the answer does not count as the helper working (see `succeeded()`); with `cancels`
    /// false a cancelled caller still waits for the answer, and the helper is not told.
    func call(
        _ op: String, json: Data = Data(), samples: [Float] = [], silence: Double, starting: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil, partial: (@Sendable (Data) -> Void)? = nil, succeeds: Bool = true,
        cancels: Bool = true
    ) async throws -> HelperFrame {
        if starting { _ = try await ensureRunning() }
        let id = lock.withLock { () -> UInt32 in
            nextID &+= 1
            return nextID
        }
        let request = Request(id: id, op: op, json: json, silence: silence, progress: progress, partial: partial, succeeds: succeeds)
        // A request that must finish once begun (a model load) is not cancelled with its caller.
        guard cancels else { return try await send(request, samples: samples) }
        return try await withTaskCancellationHandler {
            try await send(request, samples: samples)
        } onCancel: {
            self.cancel(id)
        }
    }

    /// What `call` hands to `send`.
    private struct Request: Sendable {
        var id: UInt32
        var op: String
        var json: Data
        var silence: Double
        var progress: (@Sendable (Double) -> Void)?
        var partial: (@Sendable (Data) -> Void)?
        var succeeds: Bool
    }

    /// Writes one request to the helper and waits for its answer.
    private func send(_ request: Request, samples: [Float]) async throws -> HelperFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperFrame, Error>) in
            let id = request.id
            let watchdog = self.watchdog(for: id, silence: request.silence)
            let handle = lock.withLock { () -> FileHandle? in
                guard let toHelper, process?.isRunning == true else { return nil }
                pending[id] = Pending(
                    continuation: continuation, progress: request.progress, partial: request.partial, silence: request.silence,
                    watchdog: watchdog, succeeds: request.succeeds)
                return toHelper
            }
            guard let handle else {
                continuation.resume(throwing: HelperError.stopped(what))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + request.silence, execute: watchdog)
            do {
                let start = HelperFrame(kind: .request, id: id, op: request.op, json: request.json)
                    .start(blobCount: samples.count * MemoryLayout<Float>.size)
                try writing.withLock {
                    try handle.write(contentsOf: start)
                    try samples.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress, raw.count > 0 else { return }
                        // The array outlives the write, so the data can point at it without owning it.
                        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none))
                    }
                }
            } catch {
                // The helper has just died: the reading thread will see the pipe close and fail this request.
            }
        }
    }

    /// A request with a Codable body and answer.
    func call<Body: Encodable, Answer: Decodable>(
        _ op: String, _ body: Body, samples: [Float] = [], silence: Double, as: Answer.Type = Answer.self,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (answer: Answer, blob: Data) {
        let frame = try await call(op, json: try JSONEncoder().encode(body), samples: samples, silence: silence, progress: progress)
        return (try JSONDecoder().decode(Answer.self, from: frame.json), frame.blob)
    }

    /// The timer that ends a helper which has said nothing about request `id` for `silence` seconds.
    private func watchdog(for id: UInt32, silence: Double) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stuck = self.lock.withLock { () -> Process? in
                guard self.pending[id] != nil, let process = self.process, process.isRunning else { return nil }
                self.timedOut = true
                return process
            }
            if let stuck {
                Self.log?("\(self.what) helper did not answer in \(Int(silence)) s; ending it")
                kill(stuck.processIdentifier, SIGKILL)
            }
        }
    }

    /// Tells the helper to stop request `id`, and ends the helper if it is still on it a few seconds later.
    private func cancel(_ id: UInt32) {
        let handle = lock.withLock { pending[id] == nil ? nil : toHelper }
        guard let handle else { return }
        let bytes = HelperFrame(kind: .cancel, id: id).encoded
        writing.withLock { try? handle.write(contentsOf: bytes) }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) { [weak self] in
            guard let self else { return }
            let stuck = self.lock.withLock { self.pending[id] == nil ? nil : self.process }
            if let stuck, stuck.isRunning {
                Self.log?("\(self.what) helper did not stop when asked; ending it")
                kill(stuck.processIdentifier, SIGKILL)
            }
        }
    }

    /// Counts as the helper working, for the restart limit. Every answer does unless its call says otherwise;
    /// a caller that only knows the helper works after several calls (a load, then a run) says so here.
    func succeeded() { lock.withLock { restarts.succeeded() } }

    /// One reply from the helper, handed to whoever is waiting for it.
    private func received(_ frame: HelperFrame) {
        if frame.kind == .progress || frame.kind == .partial {
            let found = lock.withLock { () -> Pending? in
                guard var entry = pending[frame.id] else { return nil }
                // Word from the helper: the silence starts again.
                entry.watchdog.cancel()
                entry.watchdog = watchdog(for: frame.id, silence: entry.silence)
                pending[frame.id] = entry
                return entry
            }
            guard let found else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + found.silence, execute: found.watchdog)
            // Called here, on the thread that reads the pipe, so the pieces arrive in order and all of them
            // before the answer.
            if frame.kind == .partial {
                found.partial?(frame.json)
            } else {
                found.progress?(Double(String(decoding: frame.json, as: UTF8.self)) ?? 0)
            }
            return
        }
        guard let entry = lock.withLock({ pending.removeValue(forKey: frame.id) }) else { return }
        entry.watchdog.cancel()
        switch frame.kind {
        case .reply:
            if entry.succeeds { succeeded() }
            entry.continuation.resume(returning: frame)
        case .cancelled: entry.continuation.resume(throwing: CancellationError())
        default: entry.continuation.resume(throwing: HelperError.refused(String(decoding: frame.json, as: UTF8.self)))
        }
    }

    /// The helper's end of the pipe closed: it is gone. Every request with it fails.
    private func ended(_ gone: Process) {
        let (waiting, hung, onPurpose) = lock.withLock { () -> ([Pending], Bool, Bool) in
            guard process === gone else { return ([], false, true) }
            let waiting = Array(pending.values)
            pending.removeAll()
            let state = (timedOut, stopping)
            process = nil
            try? toHelper?.close()
            toHelper = nil
            timedOut = false
            // A death the app did not ask for counts against the restart limit, once.
            if !state.1 { restarts.died(at: Date()) }
            return (waiting, state.0, state.1)
        }
        if !onPurpose {
            Self.log?(hung ? "\(what) helper ended: it did not answer" : "\(what) helper stopped unexpectedly")
        }
        for entry in waiting {
            entry.watchdog.cancel()
            entry.continuation.resume(throwing: hung ? HelperError.noAnswer(what) : HelperError.stopped(what))
        }
    }

    // MARK: Starting and stopping

    /// Makes sure a helper is running, starting one if need be, and returns its number. Refuses while a
    /// helper that kept dying is being left alone.
    public func ensureRunning() async throws -> Int {
        await startGate.enter()
        defer { startGate.leave() }
        if let running { return running }
        guard lock.withLock({ restarts.mayStart(at: Date()) }) else { throw HelperError.keepsStopping(what) }
        guard let executable = Bundle.main.executableURL else { throw HelperError.stopped(what) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The user is waiting on what it makes: it gets the priority the app's own work has.
        process.qualityOfService = qualityOfService
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Writing to a helper that has just died must fail with an error. Without this the write raises
        // SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw HelperError.stopped(what) }
        let reading = output.fileHandleForReading
        let (number, fault) = lock.withLock { () -> (Int, String) in
            self.process = process
            toHelper = input.fileHandleForWriting
            starts += 1
            timedOut = false
            stopping = false
            return (starts, faultText)
        }
        Thread.detachNewThread { [weak self] in
            // Each frame in a pool of its own, as in the helper: this thread never returns to one.
            while let frame = autoreleasepool(invoking: { HelperFrame.read(from: reading) }) {
                autoreleasepool { self?.received(frame) }
            }
            try? reading.close()
            self?.ended(process)
        }
        Self.log?("\(what) helper started (pid \(process.processIdentifier))")
        if !fault.isEmpty { _ = try? await call("_fault", json: Data(fault.utf8), silence: 10, starting: false) }
        return number
    }

    /// Closes the helper's input, gives it a moment to exit by itself, then kills it if it is still there.
    /// All of the model's memory goes back to macOS with it. Requests still with it fail.
    public func stop() async {
        await startGate.enter()
        defer { startGate.leave() }
        let (process, handle) = lock.withLock { () -> (Process?, FileHandle?) in
            stopping = true
            let pair = (self.process, toHelper)
            toHelper = nil
            return pair
        }
        try? handle?.close()  // The helper exits when its input closes.
        guard let process else { return }
        let deadline = Date().addingTimeInterval(Self.shutdownGrace)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // The reading thread clears the rest when it sees the pipe close; do not wait on it for long.
        let cleared = Date().addingTimeInterval(1)
        while lock.withLock({ self.process === process }), Date() < cleared { try? await Task.sleep(for: .milliseconds(10)) }
        Self.log?("\(what) helper stopped")
    }

    /// Ends the helper at once, from any thread, without waiting: for when the app quits.
    public func stopNow() {
        let process = lock.withLock { () -> Process? in
            stopping = true
            return self.process
        }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
