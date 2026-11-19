import AppKit
import ChirpCore
import CryptoKit
import Foundation
import Observation

/// Transcribes what a link points at: a sound or video file, a podcast episode from its feed, or a video
/// page. Only the sound is fetched, to a temporary file that is deleted once it has been read; the
/// transcription is the same as for a dropped file, on this Mac.
///
/// A file link and a podcast feed need nothing else. A page (YouTube and the like) needs yt-dlp, which
/// Chirp downloads the first time from yt-dlp's own releases and only installs when it matches the
/// release's list of checksums, so a changed or broken download is never run.
@MainActor
@Observable
final class LinkImporter {
    static let shared = LinkImporter()

    /// What is being done with a link, for whoever shows it.
    enum Phase: Equatable {
        case idle
        /// Looking at what the link is.
        case looking
        /// Downloading the tool for pages, 0 to 1.
        case gettingTool(Double)
        /// Downloading the sound, 0 to 1 when the size is known.
        case fetching(Double?)
        case transcribing
    }

    private(set) var phase = Phase.idle
    /// True while the window is asking for a link, with what has been typed so far.
    var asking = false
    var typed = ""
    /// A feed's latest episodes, while the user is choosing one.
    var choice: (podcast: String, episodes: [PodcastEpisode])?
    /// The last thing that went wrong, in words for the user (for automated runs too).
    private(set) var lastProblem = ""
    /// The title of the last link transcribed (for automated runs).
    private(set) var lastTitle = ""
    private var work: Task<Void, Never>?
    /// The place in the line of jobs of the link being fetched now.
    private var place: Int?
    private var process: Process?
    private weak var dictation: DictationController?

    /// What the link being fetched is called until its title is known: the site, or the file's name.
    private(set) var name = ""

    /// How many of a feed's episodes are offered.
    static let episodesOffered = 6

    var isBusy: Bool { phase != .idle }

    /// One line on what is happening, with a percentage when there is one.
    var line: String {
        func percent(_ fraction: Double?) -> String { fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? "" }
        switch phase {
        case .idle: return ""
        case .looking: return "Looking at the link"
        case .gettingTool(let done): return "Getting the link tool (yt-dlp)" + percent(done)
        case .fetching(let done): return "Getting the sound" + percent(done)
        case .transcribing: return "Transcribing"
        }
    }

    // MARK: Starting and stopping

    /// Takes what was typed or pasted and begins. Says why at once when it is not a link.
    func start(_ text: String, dictation: DictationController) {
        guard Features.shared.set.records else { return }
        guard let url = MediaLink.url(from: text) else { return fail("That is not a web link.") }
        // A link asked for while another is being fetched, or while something else is being transcribed
        // or written, waits its turn and says so. It is not turned away.
        let shown = MediaLink.soundEndings.contains(url.pathExtension.lowercased()) ? MediaLink.fileTitle(url) : (url.host ?? "Link")
        run(name: shown, dictation: dictation) { try await self.sort(url) }
    }

    /// Transcribes the episode picked from a feed.
    func choose(_ episode: PodcastEpisode) {
        let podcast = choice?.podcast ?? ""
        choice = nil
        run(name: episode.title, dictation: dictation) { try await self.transcribeFile(at: episode.audio, title: episode.title, shownLink: episode.audio, podcast: podcast) }
    }

    /// Stops whatever is being done with a link, at any stage: the download is ended and what it had
    /// fetched removed; a transcription under way is stopped too and nothing is saved.
    func cancel() {
        guard isBusy else { return }
        work?.cancel()
        process?.terminate()
        if phase == .transcribing { dictation?.cancelImport() }
        Log.write("links", "cancelled")
    }

    private func run(name shown: String, dictation: DictationController?, _ job: @escaping @MainActor () async throws -> Void) {
        let turn = Jobs.shared.add("the link", title: shown)
        Task {
            defer { Jobs.shared.done(turn) }
            guard await Jobs.shared.turn(turn) else { return }
            // The tool being downloaded from Settings is not in the line: wait for that too.
            while isBusy { try? await Task.sleep(for: .milliseconds(200)) }
            self.dictation = dictation
            lastProblem = ""
            name = shown
            place = turn
            phase = .looking
            show()
            await self.fetch(job)
            place = nil
        }
    }

    /// One link from looking at it to its transcript, saying what went wrong if something does.
    private func fetch(_ job: @escaping @MainActor () async throws -> Void) async {
        let task = Task {
            do {
                try await job()
            } catch is CancellationError {
                PerchController.shared?.say("Stopped", seconds: 3)
            } catch let problem as Problem {
                fail(problem.words)
            } catch let error as URLError {
                fail(error.code == .cancelled ? nil : Problem.network(error).words)
            } catch {
                fail(Problem.download.words)
            }
            phase = .idle
            process = nil
        }
        work = task
        await task.value
    }

    /// Says what went wrong, in the notice and the log.
    private func fail(_ words: String?) {
        guard let words else { return }
        lastProblem = words
        Log.write("links", "failed: \(words)")
        if let perch = PerchController.shared { perch.say(words, seconds: 8, error: true) } else { Toast.show(words, seconds: 8) }
    }

    /// Shows the line for the phase, with Cancel while something is being downloaded. (Not for a download
    /// started in Settings, which shows its own progress there.)
    private func show() {
        guard isBusy, phase != .transcribing, dictation != nil else { return }
        PerchController.shared?.say(line, seconds: 600, action: ("Cancel", { [weak self] in self?.cancel() }))
    }

    private func set(_ new: Phase) {
        guard new != phase else { return }
        // A percentage is only said again when it has moved a whole point.
        let old = line
        phase = new
        if line != old { show() }
    }

    // MARK: What the link is

    /// Looks at what the server sends for the link and goes the way that fits it.
    private func sort(_ url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var first = Data()
        for try await byte in bytes {
            first.append(byte)
            if first.count >= 600 { break }
        }
        bytes.task.cancel()
        let http = response as? HTTPURLResponse
        // Gone is gone, whatever kind of link it was.
        if let status = http?.statusCode, status == 404 || status == 410 { throw Problem.unavailable }
        let kind = MediaLink.kind(of: response.url ?? url, contentType: http?.value(forHTTPHeaderField: "Content-Type"), firstBytes: first)
        Log.write("links", "the link is a \(kind)")
        switch kind {
        case .file:
            guard (200..<300).contains(http?.statusCode ?? 200) else { throw Problem.unavailable }
            try await transcribeFile(at: url, title: MediaLink.fileTitle(url), shownLink: url, podcast: "")
        case .feed:
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let feed = PodcastFeed.parse(data), !feed.episodes.isEmpty else { throw Problem.emptyFeed }
            // The latest few are offered; the window asks which.
            choice = (feed.podcast, Array(feed.episodes.prefix(Self.episodesOffered)))
            PerchController.shared?.say("Choose an episode in Chirp's window", seconds: 6)
        case .page:
            try await transcribePage(url)
        }
    }

    // MARK: A sound file

    private func transcribeFile(at url: URL, title: String, shownLink: URL, podcast: String) async throws {
        set(.fetching(nil))
        let ending = MediaLink.soundEndings.contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "mp3"
        let target = try Self.temporaryFile(ending: ending)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try await download(url, to: target) { [weak self] done in self?.set(.fetching(done)) }
        try await transcribe(target, title: podcast.isEmpty ? title : "\(title) · \(podcast)", link: shownLink)
    }

    /// Fetches a file to `target`, reporting how much has arrived when the server says how big it is.
    private func download(_ url: URL, to target: URL, progress: @escaping @MainActor (Double?) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        let watcher = DownloadWatcher { fraction in Task { @MainActor in progress(fraction) } }
        let (file, response) = try await URLSession.shared.download(for: request, delegate: watcher)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200) else {
            try? FileManager.default.removeItem(at: file)
            throw Problem.unavailable
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
    }

    // MARK: A page

    private func transcribePage(_ url: URL) async throws {
        let tool = try await installedTool()
        do {
            try await fetchWithTool(tool, url)
        } catch let problem as Problem where problem == .download || problem == .unsupported {
            // Sites change and the tool follows them: when there is a newer one, it is fetched and tried once more.
            guard try await updateTool() else { throw problem }
            try await fetchWithTool(tool, url)
        }
    }

    private func fetchWithTool(_ tool: URL, _ url: URL) async throws {
        set(.fetching(nil))
        let folder = try Self.temporaryFile(ending: "x").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = Process()
        run.executableURL = tool
        run.arguments = LinkTool.arguments(link: url, folder: folder, name: "sound")
        let out = Pipe(), errors = Pipe()
        run.standardOutput = out
        run.standardError = errors
        run.standardInput = FileHandle.nullDevice
        try run.run()
        process = run
        var title = ""
        // What the tool prints is read a line at a time; bytes that are not text are skipped, not fatal.
        let reading = Task.detached { () -> String in
            String(decoding: (try? errors.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        }
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                switch LinkTool.read(line: line) {
                case .progress(let done): set(.fetching(done))
                case .title(let found):
                    title = found
                    name = found
                case nil: break
                }
            }
        } catch {
            run.terminate()
            throw CancellationError()
        }
        run.waitUntilExit()
        let said = await reading.value
        if Task.isCancelled { throw CancellationError() }
        guard run.terminationStatus == 0 else {
            Log.write("links", "the link tool ended with \(run.terminationStatus): \(LinkTool.failure(from: said)), \(said.count) characters of output")
            switch LinkTool.failure(from: said) {
            case .noNetwork: throw Problem.noNetwork
            case .notPublic: throw Problem.notPublic
            case .unsupported: throw Problem.unsupported
            case .unavailable: throw Problem.unavailable
            case .other: throw Problem.download
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let sound = files.first(where: { $0.lastPathComponent.hasPrefix("sound.") && $0.pathExtension != "part" }) else { throw Problem.download }
        try await transcribe(sound, title: title.isEmpty ? MediaLink.fileTitle(url) : title, link: url)
    }

    // MARK: Transcribing

    private func transcribe(_ file: URL, title: String, link: URL) async throws {
        try Task.checkCancellation()
        guard let dictation else { throw Problem.download }
        set(.transcribing)
        lastTitle = title
        PerchController.shared?.say("Transcribing \(title)", seconds: 5)
        guard await dictation.transcribe(file: file, title: title, source: link.absoluteString, job: place) else {
            if Task.isCancelled { throw CancellationError() }
            throw Problem.noSpeech
        }
        if let perch = PerchController.shared {
            perch.say("\(title) is transcribed", seconds: 8, action: ("Open", { perch.openLibrary() }))
        }
    }

    // MARK: The tool

    /// Where the tool is kept: Chirp's own folder, beside the models.
    static var toolsDirectory: URL {
        if LinkHandler.debugEnabled, let other = ProcessInfo.processInfo.environment["CHIRP_TOOLS_DIR"] { return URL(fileURLWithPath: other, isDirectory: true) }
        return ChirpStore.supportDirectory.appendingPathComponent("Tools", isDirectory: true)
    }

    private static var toolURL: URL { toolsDirectory.appendingPathComponent(LinkTool.asset) }
    /// The checksum of the tool that is installed, so a newer release can be told from it.
    private static var installedSumURL: URL { toolsDirectory.appendingPathComponent(LinkTool.asset + ".sha256") }

    /// yt-dlp's latest release. A test run can point this at a stand-in (`CHIRP_LINKTOOL_BASE`).
    private static var releaseBase: String {
        if LinkHandler.debugEnabled, let other = ProcessInfo.processInfo.environment["CHIRP_LINKTOOL_BASE"] { return other }
        return "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
    }

    /// A plain name for requests: nothing about this Mac or who uses it.
    private static let agent = "Mozilla/5.0 (Macintosh) transcription-app"

    /// The version of the tool that is installed ("2025.01.15"), nil when it is not; shown in Settings.
    private(set) var toolVersion: String? = LinkImporter.installedVersion()
    /// What the last Download, Update or Remove in Settings came to, in words.
    private(set) var toolNote = ""

    private static var versionURL: URL { toolsDirectory.appendingPathComponent(LinkTool.asset + ".version") }

    private static func installedVersion() -> String? {
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else { return nil }
        let kept = (try? String(contentsOf: versionURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return kept.isEmpty ? "installed" : kept
    }

    /// Asks the tool what version it is. It can take a few seconds the first time it is run.
    private nonisolated static func askVersion(_ tool: URL) -> String {
        let run = Process()
        run.executableURL = tool
        run.arguments = ["--version"]
        let out = Pipe()
        run.standardOutput = out
        run.standardError = FileHandle.nullDevice
        run.standardInput = FileHandle.nullDevice
        guard (try? run.run()) != nil else { return "" }
        let limit = DispatchWorkItem { if run.isRunning { run.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: limit)
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        run.waitUntilExit()
        limit.cancel()
        let said = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkTool.isReleaseTag(said) ? said : ""
    }

    /// From Settings: downloads the tool, or the latest one when it is already there.
    func downloadOrUpdateTool() {
        guard !isBusy else { return }
        let had = toolVersion != nil
        toolNote = ""
        dictation = nil
        phase = .gettingTool(0)
        work = Task {
            do {
                let changed = try await installTool(onlyIfNewer: had)
                toolNote = changed ? "" : "Already the latest."
            } catch let problem as Problem {
                toolNote = problem.words ?? ""
            } catch {
                toolNote = error is CancellationError ? "" : (Problem.tool.words ?? "")
            }
            phase = .idle
        }
    }

    /// From Settings: deletes the tool. It is downloaded again the next time a link needs it.
    func removeTool() {
        guard !isBusy else { return }
        for url in [Self.toolURL, Self.installedSumURL, Self.versionURL] { try? FileManager.default.removeItem(at: url) }
        toolVersion = nil
        toolNote = ""
        Log.write("links", "the link tool was removed")
    }

    /// The tool, downloaded first if it is not there.
    private func installedTool() async throws -> URL {
        if FileManager.default.isExecutableFile(atPath: Self.toolURL.path) { return Self.toolURL }
        guard try await installTool(onlyIfNewer: false) else { throw Problem.tool }
        return Self.toolURL
    }

    /// Fetches the latest tool when it is not the one installed. Returns whether a newer one was installed.
    private func updateTool() async throws -> Bool {
        (try? await installTool(onlyIfNewer: true)) ?? false
    }

    /// Downloads the latest release's file and its list of checksums, and installs the file only when the
    /// two agree. Returns false when `onlyIfNewer` and the installed one is already the latest.
    private func installTool(onlyIfNewer: Bool) async throws -> Bool {
        set(.gettingTool(0))
        do {
            guard let sumsURL = URL(string: Self.releaseBase + "/SHA2-256SUMS"), let fileURL = URL(string: Self.releaseBase + "/" + LinkTool.asset) else { throw Problem.tool }
            var request = URLRequest(url: sumsURL, timeoutInterval: 30)
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            let (sumsData, sumsResponse) = try await URLSession.shared.data(for: request)
            guard (sumsResponse as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                let wanted = LinkTool.checksum(in: String(decoding: sumsData, as: UTF8.self), for: LinkTool.asset)
            else { throw Problem.tool }
            let installed = (try? String(contentsOf: Self.installedSumURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if onlyIfNewer, installed == wanted { return false }
            try FileManager.default.createDirectory(at: Self.toolsDirectory, withIntermediateDirectories: true)
            let arriving = Self.toolsDirectory.appendingPathComponent(LinkTool.asset + ".download")
            try await download(fileURL, to: arriving) { [weak self] done in self?.set(.gettingTool(done ?? 0)) }
            let got = try await Task.detached { try Self.sha256(of: arriving) }.value
            guard got == wanted else {
                try? FileManager.default.removeItem(at: arriving)
                Log.write("links", "the link tool's checksum did not match: not installed")
                throw Problem.toolDamaged
            }
            try? FileManager.default.removeItem(at: Self.toolURL)
            try FileManager.default.moveItem(at: arriving, to: Self.toolURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.toolURL.path)
            try wanted.write(to: Self.installedSumURL, atomically: true, encoding: .utf8)
            let tool = Self.toolURL
            let version = await Task.detached { Self.askVersion(tool) }.value
            try? version.write(to: Self.versionURL, atomically: true, encoding: .utf8)
            toolVersion = Self.installedVersion()
            Log.write("links", "the link tool was installed (\(version.isEmpty ? "version not read" : version), \(wanted.prefix(12)))")
            return true
        } catch let problem as Problem {
            throw problem
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Problem.tool
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A file of its own in a folder of its own under the temporary folder.
    private static func temporaryFile(ending: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("sound.\(ending)")
    }

    // MARK: What can go wrong

    enum Problem: Error, Equatable {
        case noNetwork, notPublic, unsupported, unavailable, download, tool, toolDamaged, emptyFeed, noSpeech

        static func network(_ error: URLError) -> Problem {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                .noNetwork
            default: .download
            }
        }

        /// The words shown; nil when something else has already said it.
        var words: String? {
            switch self {
            case .noNetwork: "No connection. Check the network and try again."
            case .notPublic: "That link is private or needs a sign-in, so Chirp cannot fetch it."
            case .unsupported: "Chirp cannot get sound from that link."
            case .unavailable: "That video or episode is not available."
            case .download: "The download failed. Try again."
            case .tool: "Chirp could not download its link tool (yt-dlp). Check the network and try again."
            case .toolDamaged: "The link tool did not arrive intact, so it was not installed. Try again."
            case .emptyFeed: "That feed has no episodes with sound. Try a link to one episode."
            case .noSpeech: nil
            }
        }
    }
}

/// Reports how much of a download has arrived, when the server says how big it is.
private final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double?) -> Void
    private var watch: NSKeyValueObservation?

    init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        watch = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
        }
    }
}
