import Foundation

/// A recording as it is being made, on disk. Sound is appended as it arrives, with the transcript lines
/// and the user's notes beside it, so quitting or crashing mid-recording loses nothing: the next launch
/// finds the folder and finishes the recording.
public final class RecordingJournal: @unchecked Sendable {
    /// The two sides of a recording: the user's microphone, and what the Mac itself is playing (the call).
    public enum Track: String, Sendable { case mic, system }

    /// What is known about the recording besides its sound and words. Rewritten whole each time it changes.
    public struct Meta: Codable, Sendable, Equatable {
        public var startedAt: Date
        public var title: String
        /// The user's own notes, as typed so far.
        public var notes: String
        public var context: RecordingContext
        /// The app the call ran in, by bundle identifier.
        public var sourceApp: String?

        public init(startedAt: Date, title: String = "", notes: String = "", context: RecordingContext = RecordingContext(), sourceApp: String? = nil) {
            self.startedAt = startedAt
            self.title = title
            self.notes = notes
            self.context = context
            self.sourceApp = sourceApp
        }
    }

    /// A recording found on disk after a quit or a crash.
    public struct Recovered: Sendable {
        public var meta: Meta
        public var segments: [TranscriptSegment]
        /// How many samples each side holds. The sound itself stays on disk: an hour of it is hundreds of megabytes.
        public var micSamples: Int
        public var systemSamples: Int
    }

    /// The folder the journal's files are in.
    public let directory: URL
    /// Guards the file handles: sound arrives on audio threads while lines arrive from the transcriber.
    private let lock = NSLock()
    private var handles: [Track: FileHandle] = [:]
    private var lines: FileHandle?
    private var lost = 0

    /// Starts a new journal in `directory`, replacing whatever was there.
    public init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for track in [Track.mic, .system] {
            let url = Self.url(track, in: directory)
            fm.createFile(atPath: url.path, contents: nil)
            handles[track] = try FileHandle(forWritingTo: url)
        }
        let url = directory.appendingPathComponent("segments.jsonl")
        fm.createFile(atPath: url.path, contents: nil)
        lines = try FileHandle(forWritingTo: url)
    }

    /// The file one side of the recording is written to: 16 kHz mono, 32-bit floats, no header.
    public static func url(_ track: Track, in directory: URL) -> URL { directory.appendingPathComponent("\(track.rawValue).pcm") }

    /// Makes sure everything appended so far is in the files.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        for handle in handles.values { try? handle.synchronize() }
        try? lines?.synchronize()
    }

    /// How many samples a sound file holds, from its size; zero when it is not there.
    public static func sampleCount(at url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / MemoryLayout<Float>.size
    }

    /// Appends 16 kHz mono samples to one side of the recording.
    public func append(_ samples: [Float], to track: Track) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        defer { lock.unlock() }
        do { try handles[track]?.write(contentsOf: data) } catch { lost += samples.count }
    }

    /// Samples that could not be written (the disk is full, or the folder has gone).
    public var lostSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    /// Brings one side up to `samples` long with silence, so that the sound that follows sits at its real
    /// time beside the other side. The file is grown, not written: an hour of silence costs no disk.
    public func pad(_ track: Track, to samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handles[track], let end = try? handle.seekToEnd() else { return }
        let wanted = UInt64(max(samples, 0) * MemoryLayout<Float>.size)
        guard end < wanted else { return }
        try? handle.truncate(atOffset: wanted)
        _ = try? handle.seekToEnd()
    }

    /// Writes the title, notes and context beside the sound, replacing the last copy in one step.
    public func save(_ meta: Meta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Appends one transcript line, as a line of JSON.
    public func add(_ segment: TranscriptSegment) {
        guard var data = try? JSONEncoder().encode(segment) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? lines?.write(contentsOf: data)
    }

    /// Everything recorded so far on one side.
    public func samples(_ track: Track) -> [Float] {
        lock.lock()
        try? handles[track]?.synchronize()
        lock.unlock()
        return Self.samples(at: Self.url(track, in: directory))
    }

    /// Stops writing and lets go of the files, which stay on disk. Anything appended afterwards is ignored.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        for handle in handles.values { try? handle.close() }
        try? lines?.close()
        handles = [:]
        lines = nil
    }

    /// Closes the journal and removes it: the recording has been saved.
    public func discard() {
        close()
        Self.remove(directory)
    }

    /// Deletes a journal folder and everything in it.
    public static func remove(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }

    /// The samples in a sound file; none when it is missing or empty.
    public static func samples(at url: URL) -> [Float] {
        (try? Data(contentsOf: url, options: .mappedIfSafe))?.floats ?? []
    }

    /// Part of a sound file: `count` samples from sample `from`, or as many as there are. Only that part is read.
    public static func samples(at url: URL, from: Int, count: Int) -> [Float] {
        guard from >= 0, count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = MemoryLayout<Float>.size
        guard (try? handle.seek(toOffset: UInt64(from * size))) != nil, let data = try? handle.read(upToCount: count * size) else { return [] }
        return data.prefix(data.count / size * size).floats
    }

    /// What a journal left behind by an earlier run holds; nil when there is none or it has no sound in it.
    public static func recover(from directory: URL) -> Recovered? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return nil }
        let mic = sampleCount(at: url(.mic, in: directory))
        let system = sampleCount(at: url(.system, in: directory))
        guard mic > 0 || system > 0 else { return nil }
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            ?? Meta(startedAt: (try? fm.attributesOfItem(atPath: directory.path)[.creationDate] as? Date) ?? Date())
        // Read as bytes and split into lines before any of it is read as text: a line cut short in the
        // middle of a letter is not valid text, and read as one string it would take every line with it.
        let written = (try? Data(contentsOf: directory.appendingPathComponent("segments.jsonl"))) ?? Data()
        let decoder = JSONDecoder()
        // A line cut short by the crash is skipped.
        let segments = written.split(separator: 0x0A).compactMap { try? decoder.decode(TranscriptSegment.self, from: Data($0)) }
        return Recovered(meta: meta, segments: segments.sorted { $0.start < $1.start }, micSamples: mic, systemSamples: system)
    }
}
