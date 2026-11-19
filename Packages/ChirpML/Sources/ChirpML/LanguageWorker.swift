import ChirpCore
import Darwin
import Foundation

// Process isolation for the models that run on MLX (the language model and the search model), the way
// the speech engine has it (`SpeechWorker`).
//
// The models are loaded and run only in a child process: the app's own executable launched again with
// `LanguageWorker.flag`. A fatal error in MLX, a GPU fault or running out of memory then ends only the
// worker; the app holds no model of its own. Ending the worker gives all of its memory back to macOS. A
// worker that died is not restarted by itself: the next request starts a fresh one.
//
// One worker serves both models, on two lanes: runs of the language model on one, the search model's
// work on the other, each answered on its own kinds of reply so the two never wait on each other.

/// The kind of a message on the pipe. Each message is one kind byte, a four-byte little-endian length,
/// then that many bytes of payload. Requests are below 100 and replies above.
enum LanguageFrame: UInt8 {
    case load = 1, run = 2, cancel = 3
    /// The search model's lane: load it, turn texts into vectors, let it go.
    case embedLoad = 5, embed = 6, embedUnload = 7
    /// The sentence checker's lane (summaries): load it from a folder, score claims against text, let it go.
    case checkLoad = 8, check = 9, checkUnload = 10
    /// Several runs written together in one batch (summaries): each comes back as a `batchItem` when its row is done,
    /// then `finished` with nothing in it ends the request.
    case runBatch = 11
    /// `progress` (a load is under way), `partial` (the next piece of an answer) and the rest, which each
    /// end a request.
    case progress = 101, loaded = 102, partial = 103, finished = 104, failed = 105, cancelled = 106, batchItem = 108
    /// Replies on the search model's lane.
    case embedProgress = 110, embedLoaded = 111, embedded = 112, embedFailed = 113, embedUnloaded = 114
    /// Replies on the sentence checker's lane (it shares the search model's: the two are never used at once).
    case checkLoaded = 115, checked = 116, checkFailed = 117, checkUnloaded = 118

    /// Whether this reply belongs to the search model's lane.
    var isSearchLane: Bool { rawValue >= 110 }
}

/// The payload of an `embed` message: the texts to turn into vectors, already prefixed for a query.
struct EmbedRequest: Codable, Sendable {
    var texts: [String]
    /// TESTING only (set by a debug link): `kill-embed` ends the worker as it starts on these texts.
    var fault: String?
}

/// The payload of a `check` message: groups of claims, each scored against every chunk of its group's text.
struct CheckRequest: Codable, Sendable {
    struct Group: Codable, Sendable {
        var chunks: [String]
        var claims: [String]
    }
    var groups: [Group]
}

/// The payload of a `checked` reply: for each group, each claim's best score over the chunks; and the most MLX held.
struct CheckReply: Codable, Sendable {
    var scores: [[Double]]
    var peakMegabytes: Int
}

/// The payload of a `load` message.
struct LanguageLoadRequest: Codable, Sendable {
    var modelID: String
    /// A LoRA adapter on the hub (PEFT format) fused into the model as it loads, or nil.
    var adapterID: String? = nil
}

/// The payload of a `run` message.
struct LanguageRunRequest: Codable, Sendable {
    var instructions: String
    var text: String
    var maxTokens: Int
    var temperature: Float
    /// TESTING only (set by a debug link, never otherwise): `kill:<n>` ends the worker after n pieces of
    /// the answer, `hang:<n>` stops answering after n, `fail` refuses the run.
    var fault: String?
}

/// Writes whole frames to one end of a pipe, one at a time.
final class LanguageFrameWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(_ handle: FileHandle) { self.handle = handle }

    /// Writes one frame. Throws when the other side has gone.
    func write(_ kind: LanguageFrame, _ payload: Data = Data()) throws {
        var frame = Data([kind.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try lock.withLock { try handle.write(contentsOf: frame) }
    }

    func write<T: Encodable>(_ kind: LanguageFrame, json value: T) throws {
        try write(kind, try JSONEncoder().encode(value))
    }

    func close() { lock.withLock { try? handle.close() } }
}

/// Reads one frame, or nil when the other side has closed the pipe (or sent something that is not a frame).
func readLanguageFrame(from handle: FileHandle) -> (kind: LanguageFrame, payload: Data)? {
    func exactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let more = try? handle.read(upToCount: count - data.count), !more.isEmpty else { return nil }
            data.append(more)
        }
        return data
    }
    guard let header = exactly(5), let kind = LanguageFrame(rawValue: header[header.startIndex]) else { return nil }
    let length = header.dropFirst().withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    guard let payload = exactly(Int(length)) else { return nil }
    return (kind, payload)
}

/// The child process: loads the model it is told to and runs what it is sent, until the app closes the pipe.
public enum LanguageWorker {
    /// The first argument that makes the app's executable run as the language worker instead of as the app.
    public static let flag = "--language-worker"

    /// Whether this process was launched as the language worker. Checked before the app starts.
    public static var isWorkerInvocation: Bool {
        CommandLine.arguments.count > 1 && CommandLine.arguments[1] == flag
    }

    /// The run in progress, so a `cancel` can reach it.
    private final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func set(_ t: Task<Void, Never>?) { lock.withLock { task = t } }
        func cancel() { lock.withLock { task }?.cancel() }
    }

    /// The worker's whole life: answer requests from standard input on standard output, and exit when the
    /// app closes its end. An error is sent back as a `failed` reply, not a crash, so the app can tell a
    /// refused run from a dead worker.
    public static func run() -> Never {
        // Keep the reply pipe to ourselves: anything a library prints goes to the error stream instead.
        let replies = LanguageFrameWriter(FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true))
        dup2(STDERR_FILENO, STDOUT_FILENO)
        // A reply written after the app has gone must fail quietly, not end the worker with a signal.
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
        let engine = LanguageEngine()
        let search = EmbedEngine()
        let checker = CheckEngine()
        let current = Current()
        Thread.detachNewThread {
            let requests = FileHandle.standardInput
            while let frame = autoreleasepool(invoking: { readLanguageFrame(from: requests) }) {
                switch frame.kind {
                case .load:
                    guard let request = try? JSONDecoder().decode(LanguageLoadRequest.self, from: frame.payload) else {
                        try? replies.write(.failed, Data("unreadable request".utf8))
                        continue
                    }
                    Task(priority: .userInitiated) {
                        do {
                            try await engine.load(modelID: request.modelID, adapterID: request.adapterID) { fraction in
                                try? replies.write(.progress, Data(String(fraction).utf8))
                            }
                            try? replies.write(.loaded)
                        } catch {
                            try? replies.write(.failed, Data(error.localizedDescription.utf8))
                        }
                    }
                case .run:
                    guard let request = try? JSONDecoder().decode(LanguageRunRequest.self, from: frame.payload) else {
                        try? replies.write(.failed, Data("unreadable request".utf8))
                        continue
                    }
                    current.set(Task(priority: .userInitiated) {
                        do {
                            let fault = LanguageFault(request.fault)
                            if fault.fails { throw LanguageModelError.refused("injected failure") }
                            let pieces = PieceCount()
                            let counted = try await engine.runCounted(
                                instructions: request.instructions, text: request.text, maxTokens: request.maxTokens,
                                temperature: request.temperature
                            ) { piece in
                                fault.apply(after: pieces.next())
                                try? replies.write(.partial, Data(piece.utf8))
                            }
                            try? replies.write(.finished, json: counted)
                        } catch is CancellationError {
                            try? replies.write(.cancelled)
                        } catch {
                            try? replies.write(.failed, Data(error.localizedDescription.utf8))
                        }
                    })
                case .runBatch:
                    guard let request = try? JSONDecoder().decode(LanguageBatchRequest.self, from: frame.payload) else {
                        try? replies.write(.failed, Data("unreadable request".utf8))
                        continue
                    }
                    current.set(Task(priority: .userInitiated) {
                        do {
                            try await engine.runBatch(request.items, sharePrefix: request.sharePrefix) { index, counted in
                                try? replies.write(.batchItem, json: LanguageBatchReply(index: index, counted: counted))
                            }
                            try? replies.write(.finished)
                        } catch is CancellationError {
                            try? replies.write(.cancelled)
                        } catch {
                            try? replies.write(.failed, Data("batch: \(error)".utf8))
                        }
                    })
                case .cancel:
                    current.cancel()
                case .embedLoad:
                    let modelID = String(decoding: frame.payload, as: UTF8.self)
                    Task(priority: .userInitiated) {
                        do {
                            try await search.load(modelID: modelID) { fraction in
                                try? replies.write(.embedProgress, Data(String(fraction).utf8))
                            }
                            try? replies.write(.embedLoaded)
                        } catch {
                            try? replies.write(.embedFailed, Data(error.localizedDescription.utf8))
                        }
                    }
                case .embed:
                    guard let request = try? JSONDecoder().decode(EmbedRequest.self, from: frame.payload) else {
                        try? replies.write(.embedFailed, Data("unreadable request".utf8))
                        continue
                    }
                    Task(priority: .userInitiated) {
                        do {
                            LanguageFault(request.fault).applyToEmbed()
                            try? replies.write(.embedded, json: try await search.embed(request.texts))
                        } catch {
                            try? replies.write(.embedFailed, Data(error.localizedDescription.utf8))
                        }
                    }
                case .embedUnload:
                    Task(priority: .userInitiated) {
                        await search.unload()
                        try? replies.write(.embedUnloaded)
                    }
                case .checkLoad:
                    let path = String(decoding: frame.payload, as: UTF8.self)
                    Task(priority: .userInitiated) {
                        do {
                            try await checker.load(directory: URL(fileURLWithPath: path))
                            try? replies.write(.checkLoaded)
                        } catch {
                            try? replies.write(.checkFailed, Data(error.localizedDescription.utf8))
                        }
                    }
                case .check:
                    guard let request = try? JSONDecoder().decode(CheckRequest.self, from: frame.payload) else {
                        try? replies.write(.checkFailed, Data("unreadable request".utf8))
                        continue
                    }
                    Task(priority: .userInitiated) {
                        do {
                            try? replies.write(.checked, json: try await checker.score(request))
                        } catch {
                            try? replies.write(.checkFailed, Data(error.localizedDescription.utf8))
                        }
                    }
                case .checkUnload:
                    Task(priority: .userInitiated) {
                        await checker.unload()
                        try? replies.write(.checkUnloaded)
                    }
                default:
                    try? replies.write(.failed, Data("unexpected request".utf8))
                }
            }
            // The app closed the pipe: the model is no longer wanted. `_exit`, not `exit`: a run may still
            // be on the GPU, and the libraries' own clean-up must not race it. macOS takes the memory back.
            _exit(0)
        }
        dispatchMain()
    }
}

/// Counts the pieces of an answer as they are written (the callback runs on the model's actor, one at a time).
private final class PieceCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A fault a test asked for, carried in the run request. See `LanguageRunRequest.fault`.
struct LanguageFault: Sendable {
    var killAfter: Int?
    var hangAfter: Int?
    var fails = false
    var killsEmbed = false

    init(_ text: String?) {
        let parts = (text ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "kill": killAfter = Int(parts.count > 1 ? parts[1] : "") ?? 1
        case "hang": hangAfter = Int(parts.count > 1 ? parts[1] : "") ?? 1
        case "fail": fails = true
        case "kill-embed": killsEmbed = true
        default: break
        }
    }

    /// For the search lane: `kill-embed` ends the worker as it starts on a batch of texts.
    func applyToEmbed() {
        if killsEmbed { kill(getpid(), SIGKILL) }
    }

    /// Called with how many pieces of the answer have been written so far.
    func apply(after pieces: Int) {
        // SIGKILL: the worker is gone at once, as when macOS ends it for memory, and nothing is reported.
        if let killAfter, pieces >= killAfter { kill(getpid(), SIGKILL) }
        if let hangAfter, pieces >= hangAfter { while true { sleep(1000) } }
    }
}

/// Replies from the worker, handed from the thread that reads the pipe to whoever awaits them.
final class LanguageReplies: @unchecked Sendable {
    typealias Reply = (kind: LanguageFrame, payload: Data)
    private let lock = NSLock()
    private var waiting: [Reply] = []
    private var closed = false
    private var waiter: CheckedContinuation<Reply?, Never>?

    /// Called by the reading thread with each reply.
    func push(_ reply: Reply) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: reply)
        } else {
            waiting.append(reply)
            lock.unlock()
        }
    }

    /// Called by the reading thread when the worker's end of the pipe has closed: the worker is gone.
    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// The next reply, or nil once the worker is gone and nothing is left to read. One reader at a time.
    func next() async -> Reply? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Reply?, Never>) in
            lock.lock()
            if !waiting.isEmpty {
                let reply = waiting.removeFirst()
                lock.unlock()
                continuation.resume(returning: reply)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// The app's side: owns the one worker. `LanguageModel` and `Embedder` share it; each sends one request
/// at a time on its own lane.
final class LanguageSupervisor: @unchecked Sendable {
    /// The one supervisor: there is one helper for all MLX work.
    static let shared = LanguageSupervisor()

    /// Runs of the language model take turns here (two at once crashed MLX; see `LanguageModel`).
    let runGate = TurnGate()
    /// The search model's requests take turns here, apart from the language model's runs, so a search
    /// typed during a summary does not wait for the summary's current step.
    let embedGate = TurnGate()
    /// Starting and stopping the worker, one at a time.
    private let startGate = TurnGate()

    /// Guards everything below; only ever held for a moment.
    private let lock = NSLock()
    private var process: Process?
    private var toWorker: LanguageFrameWriter?
    private var replies: LanguageReplies?
    /// Replies on the search model's lane.
    private var searchReplies: LanguageReplies?
    /// Workers started since launch. Also the number of the running one: a model loaded in worker 3 is
    /// gone once the count says 4.
    private var starts = 0
    /// Stops a worker that keeps dying from being started over and over.
    private var restarts = RestartLimit()
    /// The worker whose death has been counted, so one death seen on both lanes counts once.
    private var countedDeath = 0
    /// Whether the language model is loaded in the running worker.
    private var languageLoaded = false
    /// TESTING only: a fault for the requests that follow to ask the worker for. Set by a debug link.
    private var faultText: String?
    var testFault: String? {
        get { lock.withLock { faultText } }
        set { lock.withLock { faultText = newValue } }
    }
    /// The worker was ended on purpose because it did not answer in time.
    private var timedOut = false
    /// Called with a line for the log when a worker starts, stops or is ended.
    private var noteHandler: (@Sendable (String) -> Void)?

    var note: (@Sendable (String) -> Void)? {
        get { lock.withLock { noteHandler } }
        set { lock.withLock { noteHandler = newValue } }
    }

    /// Seconds a load may go without a word from the worker (a download reports as it goes).
    static let loadSilence: Double = 180
    /// Seconds a run may go without a word: the prompt is read in silence, then pieces come steadily.
    static let runSilence: Double = 120
    /// Seconds a worker gets to answer a cancel before it is ended.
    static let cancelGrace: Double = 5
    /// Seconds a worker gets to exit by itself after its input closes, before it is killed.
    static let shutdownGrace: Double = 2

    /// Whether a worker is running.
    var isRunning: Bool { lock.withLock { process?.isRunning == true } }
    /// Workers started since launch (diagnostics).
    var workerStarts: Int { lock.withLock { starts } }
    /// The running worker's process id (diagnostics and tests).
    var workerPID: pid_t? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }

    /// The running worker's number, or nil when there is none.
    var running: Int? { lock.withLock { process?.isRunning == true ? starts : nil } }

    /// Makes sure a worker is running, starting one if need be, and returns its number. Refuses while a
    /// worker that kept dying is being left alone.
    func ensureRunning() async throws -> Int {
        await startGate.enter()
        defer { startGate.leave() }
        if let running { return running }
        guard lock.withLock({ restarts.mayStart(at: Date()) }) else { throw LanguageModelError.keepsStopping }
        try await start()
        return lock.withLock { starts }
    }

    /// A request finished: the worker is working.
    func succeeded() { lock.withLock { restarts.succeeded() } }

    /// Ends the worker for an unload, after the search model's request in progress (if any) has finished.
    /// Call with the run gate held.
    func stopForUnload() async {
        await embedGate.enter()
        defer { embedGate.leave() }
        await startGate.enter()
        defer { startGate.leave() }
        await stop()
    }

    /// Launches the app's own executable as a worker and wires up its pipes. Any worker before it is ended.
    private func start() async throws {
        await stop()
        guard let executable = Bundle.main.executableURL else { throw LanguageModelError.workerStopped }
        let process = Process()
        process.executableURL = executable
        process.arguments = [LanguageWorker.flag]
        // The user is waiting on what it writes: it gets the priority the app's own work has.
        process.qualityOfService = .userInitiated
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Writing to a worker that has just died must fail with an error. Without this the write raises
        // SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let replies = LanguageReplies()
        let searchReplies = LanguageReplies()
        let reading = output.fileHandleForReading
        Thread.detachNewThread {
            while let reply = autoreleasepool(invoking: { readLanguageFrame(from: reading) }) {
                (reply.kind.isSearchLane ? searchReplies : replies).push(reply)
            }
            replies.close()
            searchReplies.close()
            try? reading.close()
        }
        lock.withLock {
            self.process = process
            toWorker = LanguageFrameWriter(input.fileHandleForWriting)
            self.replies = replies
            self.searchReplies = searchReplies
            starts += 1
            timedOut = false
            languageLoaded = false
        }
        note?("language worker started (pid \(process.processIdentifier))")
    }

    /// Asks the worker to load the model. `progress` reports 0…1 while it downloads.
    func load(modelID: String, adapterID: String? = nil, progress: (@Sendable (Double) -> Void)?) async throws {
        try send(.load, json: LanguageLoadRequest(modelID: modelID, adapterID: adapterID))
        while true {
            guard let reply = await next(silence: Self.loadSilence) else { throw gone() }
            switch reply.kind {
            case .progress: progress?(Double(String(decoding: reply.payload, as: UTF8.self)) ?? 0)
            case .loaded:
                lock.withLock { languageLoaded = true }
                return
            case .failed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
            default: break
            }
        }
    }

    /// Runs one request in the worker. `onPiece` receives each piece of the answer as it is written. When
    /// the calling task is cancelled the worker is told to stop, and is ended if it does not.
    func run(_ request: LanguageRunRequest, onPiece: @Sendable (String) -> Void) async throws -> LanguageModel.Counted {
        try send(.run, json: request)
        let id = lock.withLock { () -> Int in
            lastRun += 1
            runInFlight = lastRun
            return lastRun
        }
        defer { lock.withLock { if runInFlight == id { runInFlight = nil } } }
        return try await withTaskCancellationHandler {
            while true {
                guard let reply = await next(silence: Self.runSilence) else {
                    // Ended because it would not stop when asked: to the caller that is a cancel.
                    if Task.isCancelled { throw CancellationError() }
                    throw gone()
                }
                switch reply.kind {
                case .partial: onPiece(String(decoding: reply.payload, as: UTF8.self))
                case .finished: return try JSONDecoder().decode(LanguageModel.Counted.self, from: reply.payload)
                case .cancelled: throw CancellationError()
                case .failed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
                default: break
                }
            }
        } onCancel: {
            try? self.send(.cancel)
            // A worker that is stuck never reads the cancel. Give it a moment, then end it, but only if
            // it is still on this same run (the next run may have started by then).
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) {
                let stuck = self.lock.withLock { self.runInFlight == id ? self.process : nil }
                if let stuck, stuck.isRunning {
                    self.note?("language worker did not stop when asked; ending it")
                    kill(stuck.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Runs several requests as one batch in the worker. `onItem` gets each request's answer, by its index, as soon as it
    /// is done. Cancelling works as for `run`.
    func runBatch(_ request: LanguageBatchRequest, onItem: @Sendable (Int, LanguageModel.Counted) -> Void) async throws {
        try send(.runBatch, json: request)
        let id = lock.withLock { () -> Int in
            lastRun += 1
            runInFlight = lastRun
            return lastRun
        }
        defer { lock.withLock { if runInFlight == id { runInFlight = nil } } }
        try await withTaskCancellationHandler {
            while true {
                guard let reply = await next(silence: Self.runSilence) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw gone()
                }
                switch reply.kind {
                case .batchItem:
                    let item = try JSONDecoder().decode(LanguageBatchReply.self, from: reply.payload)
                    onItem(item.index, item.counted)
                case .finished: return
                case .cancelled: throw CancellationError()
                case .failed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
                default: break
                }
            }
        } onCancel: {
            try? self.send(.cancel)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) {
                let stuck = self.lock.withLock { self.runInFlight == id ? self.process : nil }
                if let stuck, stuck.isRunning {
                    self.note?("language worker did not stop when asked; ending it")
                    kill(stuck.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Closes the worker's input, gives it a moment to exit by itself, then kills it if it is still there.
    /// All of the model's memory goes back to macOS with it.
    func stop() async {
        let (process, writer) = lock.withLock { () -> (Process?, LanguageFrameWriter?) in
            let pair = (self.process, toWorker)
            self.process = nil
            toWorker = nil
            replies = nil
            searchReplies = nil
            languageLoaded = false
            return pair
        }
        writer?.close()  // The worker exits when its input closes.
        guard let process else { return }
        let deadline = Date().addingTimeInterval(Self.shutdownGrace)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        note?("language worker stopped")
    }

    /// Ends the worker at once, from any thread, without waiting: for when the app quits.
    func stopNow() {
        let process = lock.withLock { self.process }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: The search model's lane

    /// Seconds the search model may go without a word.
    static let embedSilence: Double = 60

    /// Asks the worker to load the search model.
    func embedLoad(modelID: String, progress: (@Sendable (Double) -> Void)?) async throws {
        try send(.embedLoad, Data(modelID.utf8))
        while true {
            guard let reply = await next(silence: Self.loadSilence, searchLane: true) else { throw gone() }
            switch reply.kind {
            case .embedProgress: progress?(Double(String(decoding: reply.payload, as: UTF8.self)) ?? 0)
            case .embedLoaded: return
            case .embedFailed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
            default: break
            }
        }
    }

    /// Turns texts into vectors in the worker.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try send(.embed, json: EmbedRequest(texts: texts, fault: testFault))
        while true {
            guard let reply = await next(silence: Self.embedSilence, searchLane: true) else { throw gone() }
            switch reply.kind {
            case .embedded:
                succeeded()
                return try JSONDecoder().decode([[Float]].self, from: reply.payload)
            case .embedFailed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
            default: break
            }
        }
    }

    /// Ends worker number `helper` if it is still the one running and holds only the search model.
    /// Returns whether it was ended.
    func endIfOnlySearch(_ helper: Int) async -> Bool {
        await startGate.enter()
        defer { startGate.leave() }
        guard lock.withLock({ process?.isRunning == true && starts == helper && !languageLoaded }) else { return false }
        note?("language worker ended: the search model sat unused")
        await stop()
        return true
    }

    /// Lets the search model go. With the language model loaded the worker stays and only drops it;
    /// otherwise nothing is left to keep the worker for, and it is ended.
    func embedUnload() async {
        if lock.withLock({ languageLoaded }) {
            guard (try? send(.embedUnload)) != nil else { return }
            while let reply = await next(silence: 10, searchLane: true) {
                if reply.kind == .embedUnloaded { return }
            }
        } else {
            await startGate.enter()
            defer { startGate.leave() }
            await stop()
        }
    }

    // MARK: The sentence checker's lane

    /// Loads the sentence checker from a folder, scores the request, and lets the checker go, in one call. The
    /// caller has put the language model away first: one model at a time.
    func check(directory: String, request: CheckRequest) async throws -> CheckReply {
        try send(.checkLoad, Data(directory.utf8))
        while true {
            guard let reply = await next(silence: Self.loadSilence, searchLane: true) else { throw gone() }
            if reply.kind == .checkLoaded { break }
            if reply.kind == .checkFailed { throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self)) }
        }
        try send(.check, json: request)
        var result: CheckReply?
        while result == nil {
            guard let reply = await next(silence: Self.embedSilence * 3, searchLane: true) else { throw gone() }
            switch reply.kind {
            case .checked: result = try JSONDecoder().decode(CheckReply.self, from: reply.payload)
            case .checkFailed: throw LanguageModelError.refused(String(decoding: reply.payload, as: UTF8.self))
            default: break
            }
        }
        succeeded()
        // The checker goes again at once; the worker stays for the language model.
        if (try? send(.checkUnload)) != nil {
            while let reply = await next(silence: 10, searchLane: true) { if reply.kind == .checkUnloaded { break } }
        }
        return result!
    }

    // MARK: Plumbing

    /// The run with the worker right now, by its number, or nil when there is none.
    private var runInFlight: Int?
    private var lastRun = 0

    private func send(_ kind: LanguageFrame, _ payload: Data = Data()) throws {
        guard let writer = lock.withLock({ toWorker }) else { throw LanguageModelError.workerStopped }
        do { try writer.write(kind, payload) } catch { throw LanguageModelError.workerStopped }
    }

    private func send<T: Encodable>(_ kind: LanguageFrame, json value: T) throws {
        try send(kind, try JSONEncoder().encode(value))
    }

    /// The next reply. A worker that says nothing for `silence` seconds is ended, and nil comes back, as
    /// it does when the worker has died.
    private func next(silence: Double, searchLane: Bool = false) async -> LanguageReplies.Reply? {
        guard let (replies, process) = lock.withLock({ () -> (LanguageReplies, Process)? in
            guard let replies = searchLane ? searchReplies : replies, let process else { return nil }
            return (replies, process)
        }) else { return nil }
        let watchdog = DispatchWorkItem { [weak self] in
            guard process.isRunning else { return }
            self?.lock.withLock { self?.timedOut = true }
            self?.note?("language worker did not answer in \(Int(silence)) s; ending it")
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + silence, execute: watchdog)
        let reply = await replies.next()
        watchdog.cancel()
        return reply
    }

    /// The error for a worker that went away mid-request, and the worker's remains cleared.
    private func gone() -> LanguageModelError {
        let (hung, process) = lock.withLock { () -> (Bool, Process?) in
            let state = (timedOut, self.process)
            self.process = nil
            toWorker?.close()
            toWorker = nil
            replies = nil
            searchReplies = nil
            languageLoaded = false
            timedOut = false
            if countedDeath != starts {
                countedDeath = starts
                restarts.died(at: Date())
            }
            return state
        }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        note?(hung ? "language worker ended: it did not answer" : "language worker stopped unexpectedly")
        return hung ? .workerHung : .workerStopped
    }
}
