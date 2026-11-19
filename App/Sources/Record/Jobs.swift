import ChirpCore
import Foundation
import Observation

/// The line of jobs that take turns: transcribing a link or a file, writing a meeting's notes, naming
/// a voice note. One runs; the rest wait in the order they were asked for, and each says what it waits
/// for ("Waiting for the link to finish…") on the perch, in the menu bar and on its Library row, with
/// Cancel. Nothing is refused. Dictation and a recording being made never wait here.
@MainActor
@Observable
final class Jobs {
    static let shared = Jobs()

    private(set) var line = JobLine()
    /// Jobs cancelled while they waited.
    private var cancelled: Set<Int> = []
    /// TESTING: a job that only stands at the head of the line (`job-hold`).
    private var held: Int?

    private init() {
        LinkHandler.stateProviders["jobs"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "running": self.line.running?.name ?? "",
                "waiting": self.line.waiting.map(\.name),
                "line": self.line.firstWaiting?.line ?? "",
            ]
        }
    }

    /// What a job that has no library item yet is called on its own row: the file's or the link's name.
    private(set) var titles: [Int: String] = [:]

    /// Files and links waiting their turn, for the Library's "Now" rows: each with what it waits for.
    var waitingImports: [(id: Int, title: String, line: String)] {
        line.waiting.compactMap { job in
            guard let title = titles[job.id], let waiting = line.waitingLine(for: job.id) else { return nil }
            return (job.id, title, waiting)
        }
    }

    /// Joins the line. Call `turn` to wait, and `done` when finished or given up.
    func add(_ name: String, title: String? = nil, itemID: Int64? = nil) -> Int {
        let id = line.add(name, itemID: itemID)
        titles[id] = title
        if let waiting = line.waitingLine(for: id) { Log.write("jobs", "\(line.jobs.count) in the line: the newest waits (\(waiting.count) characters of status shown)") }
        return id
    }

    /// Waits until the job is at the head of the line. False when it was cancelled while it waited.
    func turn(_ id: Int) async -> Bool {
        let began = Date()
        while !line.isRunning(id) {
            if cancelled.contains(id) || !line.jobs.contains(where: { $0.id == id }) { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let waited = Date().timeIntervalSince(began)
        if waited > 0.5 { Log.write("jobs", String(format: "a job had its turn after waiting %.1f s", waited)) }
        return !cancelled.contains(id)
    }

    /// The job is over, however it ended.
    func done(_ id: Int) {
        line.remove(id)
        cancelled.remove(id)
        titles[id] = nil
    }

    /// Cancel on a job that is waiting: it leaves the line. One that is running is stopped by its own Cancel.
    func cancel(_ id: Int) {
        guard line.isWaiting(id) else { return }
        cancelled.insert(id)
        line.remove(id)
        titles[id] = nil
        Log.write("jobs", "a waiting job was cancelled")
    }

    /// What is waiting first and what for, for the perch and the menu bar.
    var firstWaiting: (job: JobLine.Job, line: String)? { line.firstWaiting }

    /// Cancel on the perch or in the menu bar: the first job that is waiting.
    func cancelFirstWaiting() {
        if let first = line.firstWaiting { cancel(first.job.id) }
    }

    /// What the menu bar says under "Waiting": "For the link to finish · then Design sync".
    var waitingDetail: String? {
        guard let first = line.firstWaiting, let running = line.running else { return nil }
        return "For \(running.name) to finish · then \(first.job.name)"
    }

    func hold(_ name: String) {
        guard held == nil else { return }
        held = line.add(name)
    }

    func releaseHeld() {
        if let held { done(held) }
        held = nil
    }
}
