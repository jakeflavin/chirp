import AVFoundation
import AppKit
import ChirpCore
import ChirpML
import Observation
import SwiftUI

/// Test switches for recording, in a test copy only: `--debug-hooks` and
/// `CHIRP_RECORD_TEST="notes=0,headphones=1"` in the environment. Nothing sets them in normal use.
/// `notes=0` skips writing notes, `headphones=1` or `0` says whether headphones are on, `stall=<step>` makes
/// that step never end, `stepLimit=<seconds>` shortens every step's time limit, and `notesHold=<seconds>`
/// waits that long before notes are written.
enum RecordTestHooks {
    private static let values: [String: String] = {
        guard ProcessInfo.processInfo.arguments.contains("--debug-hooks"),
            let text = ProcessInfo.processInfo.environment["CHIRP_RECORD_TEST"]
        else { return [:] }
        var out: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }()

    /// Whether a step is in use: yes unless the test run switched it off.
    static func on(_ name: String) -> Bool { values[name] != "0" }
    /// What a test run set a switch to, if it did.
    static func value(_ name: String) -> String? { values[name] }
}

/// One side of a meeting: collects audio, cuts it at pauses and transcribes each piece as it arrives.
private actor Channel {
    let speaker: String
    private var segmenter = PauseSegmenter()
    /// Cuts by voice instead of by loudness: a meeting's sides are cut this way.
    private var voice: VoiceSegmenter?
    private var voiceState: VoiceStreamState?
    /// The loop scoring and transcribing what the voice cutter holds, while one is running.
    private var voiceLoop: Task<Void, Never>?
    /// The sound itself, only when there is no journal on disk to hold it.
    private var all: [Float] = []
    private var peak: Float = 0
    /// Pieces that had sound in them but could not be transcribed (the speech model failed or would not load).
    private(set) var failedPieces = 0
    /// The newest piece's transcription. Each waits for the one before, so lines arrive in order and
    /// `finish()` can wait for all of them.
    private var lastPiece: Task<Void, Never>?
    private let transcriber: Transcriber
    /// Told each new line, with its words and their times when the speech model gave them.
    private let onSegment: @Sendable (TranscriptSegment, [SaidWord]) -> Void
    /// Where the sound is written as it arrives.
    private let journal: RecordingJournal?
    private let track: RecordingJournal.Track
    /// Waits until the speech model is loaded.
    private let ready: @Sendable () async -> Void

    init(
        speaker: String, track: RecordingJournal.Track, journal: RecordingJournal?, transcriber: Transcriber,
        byVoice: Bool = false, ready: @escaping @Sendable () async -> Void,
        onSegment: @escaping @Sendable (TranscriptSegment, [SaidWord]) -> Void
    ) {
        self.speaker = speaker
        self.track = track
        self.journal = journal
        self.transcriber = transcriber
        self.ready = ready
        self.onSegment = onSegment
        // A meeting is cut by voice (voice detection); a voice note at pauses.
        if byVoice { voice = VoiceSegmenter() }
    }

    /// Takes the next chunk of sound: keeps it at once, and queues for transcription any piece that a pause
    /// has just completed. It never waits for the speech model, so sound reaches the disk as it arrives.
    func append(_ samples: [Float]) {
        if let journal { journal.append(samples, to: track) } else { all.append(contentsOf: samples) }
        for s in samples { peak = max(peak, abs(s)) }
        cut(samples)
    }

    /// Hands sound to whichever cutter is in use.
    private func cut(_ samples: [Float]) {
        if voice != nil {
            voice?.append(samples)
            if voiceLoop == nil { voiceLoop = Task { await self.scoreAndTranscribe() } }
        } else {
            for piece in segmenter.append(samples) { enqueue(piece) }
        }
    }

    /// Samples this side has taken so far, counting silence it was brought forward over.
    var receivedSamples: Int { voice?.receivedSamples ?? segmenter.receivedSamples }

    /// Brings this side up to `sample` with silence, when it is behind: it started after the recording did,
    /// or its capture was set up again. What it hears next is then written, timed and played back at the
    /// moment it was heard, beside the other side: both sides run on one clock.
    func align(to sample: Int) {
        let have = receivedSamples
        guard sample > have else { return }
        if let journal { journal.pad(track, to: sample) } else { all.append(contentsOf: [Float](repeating: 0, count: sample - have)) }
        if voice != nil {
            cut([Float](repeating: 0, count: sample - have))
        } else if let piece = segmenter.skip(to: sample) {
            enqueue(piece)
        }
    }

    /// Transcribes what is left and waits for every piece still being transcribed. Returns the sound only
    /// when it was held in memory (no journal).
    func finish() async -> [Float] {
        if voice != nil {
            while let loop = voiceLoop { await loop.value }
            if let piece = voice?.finish() { await transcribe(piece) }
        } else if let piece = segmenter.finish() {
            enqueue(piece)
        }
        await lastPiece?.value
        journal?.flush()
        return all
    }

    /// Loudest sample seen so far; zero means nothing but silence has arrived.
    var loudest: Float { peak }

    /// Sound that could not be written to the journal (the disk is full, or gone).
    var lostSamples: Int { journal?.lostSamples ?? 0 }

    /// Puts a piece at the end of the line of pieces being transcribed.
    private func enqueue(_ piece: PauseSegmenter.Piece) {
        let previous = lastPiece
        lastPiece = Task {
            await previous?.value
            await self.transcribe(piece)
        }
    }

    /// Scores each quarter second the voice cutter is holding and transcribes the pieces that end, in order.
    private func scoreAndTranscribe() async {
        await ready()
        while let frame = voice?.nextFrame {
            // Without voice detection every frame counts as speech: pieces are then cut at the longest length.
            let scored = await transcriber.voiceScore(frame, after: voiceState)
            voiceState = scored?.state
            if let piece = voice?.score(scored?.score ?? 1) { await transcribe(piece) }
        }
        voiceLoop = nil
    }

    private func transcribe(_ piece: PauseSegmenter.Piece) async {
        // Skip pieces that are silence all the way through.
        guard PauseSegmenter.rms(piece.samples[...]) > 0.002 else { return }
        // The first pieces can arrive before the speech model has finished loading; they wait for it.
        await ready()
        do {
            let transcript = try await transcriber.transcribe(piece.samples)
            guard !transcript.text.isEmpty else { return }
            // The words with their times, when put together they are the text: speakers are then given word by word.
            let letters = { (text: String) in text.filter { !$0.isWhitespace } }
            let words = !transcript.words.isEmpty && letters(transcript.words.map(\.text).joined()) == letters(transcript.text)
                ? transcript.words.map { SaidWord(text: $0.text, start: $0.start + piece.start, end: $0.end + piece.start) } : []
            onSegment(TranscriptSegment(itemID: 0, speaker: speaker, start: piece.start, end: piece.end, text: transcript.text), words)
        } catch {
            // Not silence: the recording must not be thrown away as if nothing had been said.
            failedPieces += 1
        }
    }
}

/// Carries sound from an audio thread to a channel in the order it was captured. (One task per chunk,
/// as before, could reach the channel out of order.)
private final class Inlet: Sendable {
    private enum Arrival: Sendable {
        case sound([Float])
        /// What follows was heard from where this other side is now.
        case catchUp(Channel)
    }

    private let continuation: AsyncStream<Arrival>.Continuation
    private let delivery: Task<Void, Never>

    init(to channel: Channel) {
        let (stream, continuation) = AsyncStream<Arrival>.makeStream()
        self.continuation = continuation
        delivery = Task.detached {
            for await arrival in stream {
                switch arrival {
                case .sound(let samples): await channel.append(samples)
                case .catchUp(let other): await channel.align(to: await other.receivedSamples)
                }
            }
        }
    }

    /// Called on an audio thread with each new chunk.
    func send(_ samples: [Float]) { continuation.yield(.sound(samples)) }

    /// Capture is about to start, or start again: the sound that follows is put where `other` has got to.
    func catchUp(with other: Channel) { continuation.yield(.catchUp(other)) }

    /// No more sound is coming: waits until everything sent has reached the channel.
    func close() async {
        continuation.finish()
        await delivery.value
    }
}

/// `MicLeveler` shared between the audio thread, which runs the sound through it, and the recorder,
/// which switches it on when a call app is found holding the microphone.
private final class MicLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var leveler = MicLeveler()
    private var active = false

    func set(active now: Bool) { lock.withLock { active = now } }
    var gain: Float { lock.withLock { leveler.gain } }
    func process(_ samples: [Float]) -> [Float] {
        lock.withLock { active ? leveler.process(samples) : samples }
    }
}

/// One side of a finished recording: in its file on disk, or (when no journal could be made) in memory.
private enum Sound {
    case onDisk(URL)
    case inMemory([Float])

    /// How many samples it holds, counted without loading them.
    var samples: Int {
        switch self {
        case .onDisk(let url): RecordingJournal.sampleCount(at: url)
        case .inMemory(let all): all.count
        }
    }

    /// The whole of it. Only speaker labelling needs this.
    func load() -> [Float] {
        switch self {
        case .onDisk(let url): RecordingJournal.samples(at: url)
        case .inMemory(let all): all
        }
    }
}

/// Records what is said. The user chooses what it is by how they start it:
/// a **voice note** is their own words from the microphone, saved as clean text with a title; a
/// **meeting** is the microphone ("Me") and, when somebody else is on the line, the other side of the
/// call ("Them") as separate channels, with a live transcript cut by voice, then speakers and a summary,
/// key points and decisions. Both take notes sent with their time and pictures of the front window.
/// No bot joins the call.
@MainActor
@Observable
final class MeetingRecorder {
    /// Where a recording is: not running, running, or being finished after Stop.
    enum Phase: Equatable {
        case idle
        case recording
        /// Finishing up; the string says which step.
        case finishing(String)
    }

    private(set) var phase: Phase = .idle
    /// Seconds since the recording began.
    private(set) var elapsed: Double = 0
    /// The transcript so far, in time order.
    private(set) var liveSegments: [TranscriptSegment] = []
    /// Recent microphone levels for the wire, oldest first.
    private(set) var levels: [Double] = Array(repeating: 0, count: 28)
    /// Set when something is wrong with capture, e.g. no call audio is arriving.
    private(set) var warning: String? {
        didSet {
            guard warning != oldValue, let warning else { return }
            Log.write("record", "warning: \(warning)")
            // Say it where it will be seen: the recording pill is small and the window may be hidden.
            if phase == .recording { Toast.show(warning, seconds: 8) }
        }
    }
    /// What was last said about room on the disk, so it is said once; and when it was last looked at.
    private(set) var diskRoom = RecordingDisk.Room.ample
    private var lastDiskCheck = Date.distantPast
    /// When capture of this Mac's sound was last set up again after delivering only silence.
    private var lastTapRetry = Date.distantPast
    /// What is being recorded, as the user chose when they started it.
    private(set) var kind: RecordingKind = .voiceNote
    /// What the user kept during this recording, each with its time: typed lines and pictures.
    var timedNotes: [TimedNote] { context.notes }
    /// True while a picture of the front window is being taken.
    private(set) var capturing = false
    /// The transcript so far as it is shown: on loudspeakers, without the user's lines that only repeat
    /// what the Mac played. `liveSegments` keeps every line as it was heard.
    private(set) var shownSegments: [TranscriptSegment] = []
    /// How many of the user's lines are left out of `shownSegments` as the Mac's own sound.
    var echoesDropped: Int { liveSegments.count - shownSegments.count }
    /// Each side's words with their times, for giving speakers word by word when the recording ends.
    private var micWords: [SaidWord] = []
    private var systemWords: [SaidWord] = []
    /// The recording's title: typed by the user, or taken from the calendar.
    var title = ""
    /// Bumped when the saved meetings change.
    private(set) var version = 0
    /// The meeting most recently saved, so the page can select it.
    private(set) var lastSavedID: Int64?
    /// What notes are being written for, while the language model runs.
    private(set) var writingNotesFor: Int64?
    /// Recordings whose notes have been asked for and are not written yet (being written, or waiting their turn).
    private var notesAsked: Set<Int64> = []
    /// The notes being written, so Stop can end them part-way.
    private var notesWork: Task<Void, Never>?
    /// True from Stop until the language model has let go (a few seconds at most).
    private(set) var stoppingNotes = false
    /// The recording whose notes were last stopped part-way, so nothing announces them as ready.
    private(set) var notesStoppedFor: Int64?

    /// Whether the sound is kept after the transcript is made, so it can be played back.
    /// Settings › Notes: a voice note's title is its opening words (off: the date and time).
    static var noteTitleFromWords: Bool {
        get { UserDefaults.standard.object(forKey: "notes.titleFromWords") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notes.titleFromWords") }
    }
    /// Settings › Notes: a voice note's audio is kept. Off, only its words are.
    var keepNoteAudio: Bool {
        didSet { try? app.engine.setSetting("keepNoteAudio", keepNoteAudio) }
    }
    /// Settings › Meetings: each voice on the other side is labelled ("Speaker 1"). Off, it is all "Them".
    var tellSpeakersApart: Bool {
        didSet { try? app.engine.setSetting("tellSpeakersApart", tellSpeakersApart) }
    }
    /// Settings › Meetings: a meeting's audio is kept.
    var keepAudio: Bool {
        didSet { try? app.engine.setSetting("keepMeetingAudio", keepAudio) }
    }

    private let app: AppModel
    private let models: ModelCenter
    let library: Library
    private let speakers = SpeakerLabeler()
    private let mic = AudioRecorder()
    private let system = SystemAudioTap()
    private var micChannel: Channel?
    private var systemChannel: Channel?
    /// How live sound reaches each channel, in the order it was captured.
    private var micInlet: Inlet?
    private var systemInlet: Inlet?
    /// True once this run has made macOS ask about the microphone, so it is only asked once.
    private var askedMicrophone = false
    /// Tasks feeding test audio files into the channels, in place of live sound.
    private var feeders: [Task<Void, Never>] = []
    /// Runs twice a second while recording: the clock, the journal, the screen and the capture check.
    private var ticker: Task<Void, Never>?
    private(set) var startedAt = Date()
    /// The call app this recording is of, when known ("Zoom").
    private var sourceApp: String?
    /// The people invited to the meeting being recorded, from the calendar.
    private var attendees: [String] = []
    /// Whether the title was taken from the calendar rather than typed. A voice note gives it back.
    private var titleFromCalendar = false
    /// What is known about this recording besides its sound.
    private var context = RecordingContext()
    /// The recording on disk while it is being made.
    private var journal: RecordingJournal?
    /// What was last written to the journal, so it is only rewritten when something changed.
    private var journalled: RecordingJournal.Meta?
    /// True while this recording is keeping the speech model loaded.
    private var holdingSpeech = false
    /// True once this Mac's sound (the other side of a call, or a video) is being captured.
    private(set) var capturingSystem = false
    /// True once an app was seen holding the microphone: there really is a call to hear.
    private var callSeen = false
    /// What the user chose for this recording, when they chose: it then stays that way.
    private var soundChoice: Bool?
    /// Whether everything playing went to headphones each time it was looked at while both sides were
    /// being captured; nil when it was never looked at. Then the microphone cannot have heard the other side.
    private var onHeadphones: Bool?
    private var lastHeadphoneCheck = Date.distantPast

    /// Whether this Mac's own sound is part of the recording. Chirp turns it on by itself for a call;
    /// the user turns it on to take notes on a video or a recorded meeting.
    var includesComputerSound: Bool {
        get { capturingSystem }
        set {
            guard phase == .recording, Self.micFeed == nil || Self.systemFeed != nil else { return }
            soundChoice = newValue
            if newValue {
                captureSystem()
                Log.write("record", "this Mac's sound was added to the recording by hand")
            } else if capturingSystem {
                system.stop()
                capturingSystem = false
                Log.write("record", "this Mac's sound was taken out of the recording by hand")
            }
        }
    }
    /// When it was last checked whether a call has started.
    private var lastCallCheck = Date.distantPast
    /// When the screen was last looked at.
    private var lastLook = Date.distantPast
    /// The text of the last screen kept, to tell when the screen says something new.
    private var lastScreenText: String?
    /// True while a look at the screen is under way, so two never overlap.
    private var looking = false
    private var lookTask: Task<Void, Never>?
    /// How often the screen is looked at, and how many pictures one recording keeps.
    private static let maxScreens = 20
    /// Often at first, when the subject is being set out; then once a minute, so a long recording still has
    /// room for what is shown near its end.
    private var lookEvery: TimeInterval { elapsed < 300 ? 20 : 60 }
    /// The folder the recording under way is written to. There is only ever one.
    private static var journalDirectory: URL {
        ChirpStore.audioDirectory.deletingLastPathComponent().appendingPathComponent("Recording in progress", isDirectory: true)
    }
    /// Where a journal that still holds unsaved sound waits when a new recording needs the folder above.
    /// Each one is finished at a later launch.
    private static var parkedDirectory: URL {
        ChirpStore.audioDirectory.deletingLastPathComponent().appendingPathComponent("Recordings to finish", isDirectory: true)
    }
    /// Where the sound of a saved recording is kept when its audio file could not be written.
    private static var keptSoundDirectory: URL {
        ChirpStore.audioDirectory.deletingLastPathComponent().appendingPathComponent("Recording audio not saved", isDirectory: true)
    }
    /// The audio files standing in for the microphone and for this Mac's sound in automated runs.
    private static let micFeed = AudioRecorder.feedFile
    private static let systemFeed = AudioRecorder.launchFile(after: "--feed-system-audio")
    /// The floating "Recording" pill, used when there is no perch to show it.
    private let fullSpeed = FullSpeed()
    /// When each live segment arrived, in seconds after the start (diagnostics).
    private var arrivals: [Double] = []

    init(app: AppModel, models: ModelCenter) {
        self.app = app
        self.models = models
        library = Library(store: app.store)
        let meetingAudio = (try? app.engine.setting("keepMeetingAudio", as: Bool.self)) ?? true
        keepAudio = meetingAudio
        // Meetings and notes were one setting until the split (Rec13): a note starts from what it said.
        keepNoteAudio = (try? app.engine.setting("keepNoteAudio", as: Bool.self)) ?? meetingAudio
        tellSpeakersApart = (try? app.engine.setting("tellSpeakersApart", as: Bool.self)) ?? true

        let speakers = speakers
        models.register(
            .speakers, onDisk: { SpeakerLabeler.isDownloaded },
            load: { _ in try await speakers.load() }, unload: { speakers.unload() })

        // A recording's sound goes to disk through its channel; the recorder need not hold a second copy.
        mic.keepsSamples = false
        // Once only: run again, it would mistake a new recording with typed notes and no speech for an old one.
        if !((try? app.engine.setting("adoptedOldVoiceNotes", as: Bool.self)) ?? false) {
            adoptOldVoiceNotes()
            try? app.engine.setSetting("adoptedOldVoiceNotes", true)
        }
        // The calendar is read as soon as recording is possible, not at the first recording.
        _ = CalendarReader.shared
        // A recording that was under way when Chirp last quit or crashed is finished now.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.recover()
        }

        // `kind=note` or `kind=meeting`; left out, it is a meeting when the run feeds in the other side of a call.
        LinkHandler.commands["meeting-start"] = { [weak self] q in
            let kind: RecordingKind = q["kind"].map { $0 == "meeting" ? .meeting : .voiceNote } ?? (Self.systemFeed != nil || q["app"] != nil ? .meeting : .voiceNote)
            self?.start(kind, title: q["title"] ?? "", sourceApp: q["app"])
        }
        // A note sent as Enter sends it (`meeting-note?text=…`, `at=12.5` to set its time in a fed run), and the capture button.
        LinkHandler.commands["meeting-note"] = { [weak self] q in self?.sendNote(q["text"] ?? "", at: q["at"].flatMap(Double.init)) }
        LinkHandler.commands["meeting-capture"] = { [weak self] q in
            guard let self else { return }
            let at = q["at"].flatMap(Double.init)
            Task { await self.capture(at: at) }
        }
        LinkHandler.commands["meeting-stop"] = { [weak self] _ in self?.stop() }
        // TESTING: `mic-trial?channels=3` puts a tone through a microphone format of that many channels, the
        // way it was converted before and the way it is now; `state` then has `micTrial` (`before`, `after`: the loudest sample).
        LinkHandler.commands["mic-trial"] = { [weak self] q in
            let channels = UInt32(q["channels"] ?? "") ?? 3
            let trial = AudioRecorder.channelTrial(channels: channels)
            self?.micTrial = ["channels": Int(channels), "before": Double(trial.before), "after": Double(trial.after)]
        }
        LinkHandler.stateProviders["micTrial"] = { [weak self] in self?.micTrial ?? [:] }
        // What Chirp would call whatever holds the microphone, by bundle identifier (`call-name?id=com.apple.avconferenced`).
        LinkHandler.commands["call-name"] = { [weak self] q in
            let parent = MeetingDetector.helperParent(q["id"] ?? "")
            self?.micTrial = ["parent": parent ?? "", "name": parent.flatMap(MeetingDetector.callName) ?? "", "systemAudio": SystemAudioPermission.status.rawValue]
        }
        // To the recording being made; with `saved=1`, to the newest saved one. `meeting-detach?n=0` takes one away.
        LinkHandler.commands["meeting-attach"] = { [weak self] q in
            guard let self, let path = q["path"] else { return }
            if q["saved"] == "1", let id = (try? self.library.items(kinds: [.meeting, .voiceNote]))?.first?.id {
                self.attach(URL(fileURLWithPath: path), to: id)
            } else {
                self.attach(URL(fileURLWithPath: path))
            }
        }
        LinkHandler.commands["meeting-detach"] = { [weak self] q in
            guard let self, let id = (try? self.library.items(kinds: [.meeting, .voiceNote]))?.first?.id else { return }
            self.removeAttachment(at: Int(q["n"] ?? "0") ?? 0, from: id)
        }
        // Stop on the notes being written (or Cancel on the newest recording's waiting notes).
        LinkHandler.commands["meeting-notes-stop"] = { [weak self] _ in
            guard let self else { return }
            if self.writingNotesFor != nil { self.stopNotes() } else if let id = (try? self.library.items(kinds: [.meeting]))?.first?.id { self.stopNotes(for: id) }
        }
        LinkHandler.commands["meeting-redo"] = { [weak self] _ in
            guard let self, let id = (try? self.library.items(kinds: [.meeting, .voiceNote]))?.first?.id else { return }
            Task { await self.writeNotes(for: id) }
        }
        // Saves a transcript from a text file ("Name: what they said" on each line) as a recording, without
        // audio and without writing its notes: `meeting-redo` writes them. `kind=voiceNote` for one voice.
        LinkHandler.commands["meeting-import"] = { [weak self] q in
            guard let self, let text = q["path"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) else { return }
            var segments: [TranscriptSegment] = []
            var clock = 0.0
            for line in text.components(separatedBy: .newlines) {
                guard let colon = line.range(of: ": "), line.distance(from: line.startIndex, to: colon.lowerBound) <= 40 else { continue }
                let words = String(line[colon.upperBound...])
                // About 150 words a minute.
                let seconds = Double(words.split(separator: " ").count) * 0.4
                segments.append(TranscriptSegment(itemID: 0, speaker: String(line[..<colon.lowerBound]), start: clock, end: clock + seconds, text: words))
                clock += seconds
            }
            let kind: ItemKind = q["kind"] == "voiceNote" ? .voiceNote : .meeting
            guard !segments.isEmpty, let saved = try? self.library.save(SavedItem(kind: kind, title: q["title"] ?? "Imported", duration: clock)),
                let id = saved.id
            else { return }
            try? self.library.replaceSegments(itemID: id, with: segments)
            self.version += 1
        }
        followFeatures()
        // TESTING: `job-hold?name=the%20link` puts a job at the head of the line that does nothing until `job-hold?done=1`.
        LinkHandler.commands["job-hold"] = { q in
            if q["done"] == "1" { Jobs.shared.releaseHeld() } else { Jobs.shared.hold(q["name"] ?? "the link") }
        }
        LinkHandler.commands["job-cancel"] = { _ in Jobs.shared.cancelFirstWaiting() }
        LinkHandler.stateProviders["meeting"] = { [weak self] in
            guard let self else { return [:] }
            let items = (try? self.library.items(kinds: [.meeting, .voiceNote])) ?? []
            let last = items.first
            var out: [String: Any] = [:]
            out["phase"] = "\(self.phase)"
            out["files"] = RecordingContext(json: last?.context ?? "").attachments.map { "\($0.name) | \($0.kindLine) | \($0.file ?? "")" }
            out["disk"] = "\(self.diskRoom)"
            out["warning"] = self.warning ?? ""
            out["live"] = self.liveSegments.map { "\($0.speaker): \($0.text)" }
            out["shown"] = self.shownSegments.map { "\($0.speaker): \($0.text)" }
            out["echoesDropped"] = self.echoesDropped
            // What a transcribed file or link was filed as: a document, with its lines and its sound.
            if let doc = (try? self.library.items(kinds: [.document]))?.first(where: { $0.audioFile != nil }) {
                let lines: [TranscriptSegment] = doc.id.flatMap { try? self.library.segments(itemID: $0) } ?? []
                out["imported"] = ["kind": doc.kind.rawValue, "title": doc.title, "body": doc.body, "summary": doc.summary, "lines": lines.count,
                                   "speakers": Array(Set(lines.map(\.speaker))).sorted(), "audio": doc.audioFile ?? ""] as [String: Any]
            }
            out["recordingKind"] = self.kind.rawValue
            out["liveNotes"] = self.timedNotes.map { "\($0.clock) \($0.line)" }
            out["notes"] = RecordingContext(json: last?.context ?? "").notes.map { ["at": $0.at, "line": $0.line, "image": $0.image ?? ""] as [String: Any] }
            out["body"] = last?.body ?? ""
            out["notesLine"] = last?.id.flatMap { self.notesLine(for: $0) } ?? ""
            out["rows"] = self.progressRow.map { ["\($0.title) | \($0.line)"] } ?? []
            out["count"] = items.count
            out["title"] = last?.title ?? ""
            out["summary"] = last?.summary ?? ""
            let lastSegments: [TranscriptSegment] = last?.id.flatMap { try? self.library.segments(itemID: $0) } ?? []
            out["transcript"] = MeetingText.script(lastSegments)
            out["audio"] = last?.audioFile ?? ""
            out["writing"] = self.writingNotesFor != nil || !self.notesAsked.isEmpty
            out["notesState"] = last?.id.flatMap { self.notesState(for: $0) }.map { "\($0)" } ?? ""
            out["notesStopped"] = self.notesStoppedFor != nil
            out["arrivals"] = self.arrivals
            out["headphones"] = self.onHeadphones.map { "\($0)" } ?? ""
            out["headphonesNow"] = AudioDevices.outputsAreHeadphones()
            out["playingThrough"] = AudioDevices.devicesOtherAppsPlayThrough().map { AudioDevices.name(of: $0) }
            out["attendees"] = last?.source ?? ""
            out["liveTitle"] = self.title
            out["context"] = last?.context ?? ""
            out["journal"] = FileManager.default.fileExists(atPath: Self.journalDirectory.path)
            out["gaveUpOn"] = self.gaveUpOn
            out["kind"] = last?.kind.rawValue ?? ""
            out["kinds"] = items.map(\.kind.rawValue)
            out["lines"] = lastSegments.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }
            out["duration"] = last?.duration ?? 0
            return out
        }
    }

    /// Meetings (or Notes) switched off in the middle of a meeting (or a voice note): it is stopped and
    /// saved, as Stop does.
    private func followFeatures() {
        Features.shared.whenChanged { [weak self] old, new in
            guard let self, self.phase == .recording else { return }
            let feature: Feature = self.kind == .meeting ? .meetings : .notes
            if old.isOn(feature), !new.isOn(feature) { self.stop() }
        }
        // While a recording is being saved or its notes written, its models are not unloaded.
        Features.shared.probe("record.finishing") { [weak self] in
            guard let self else { return false }
            if case .finishing = self.phase { return true }
            return self.writingNotesFor != nil
        }
        Features.shared.probe("record.recording") { [weak self] in self?.phase == .recording }
    }

    /// The file given after a launch flag such as `--feed-audio`, which stands in for live sound in automated runs.
    static func feedFile(_ flag: String) -> URL? { AudioRecorder.launchFile(after: flag) }

    // MARK: Start

    /// Starts a recording of the kind the user chose: the microphone always, and for a meeting this
    /// Mac's sound too when somebody else is on the line. `sourceApp` is the call app it was started for, if any.
    func start(_ kind: RecordingKind = .voiceNote, title: String = "", sourceApp: String? = nil) {
        guard phase == .idle, Features.on(kind == .meeting ? .meetings : .notes) else { return }
        // The first time, macOS has to ask about the microphone. Ask now rather than record silence, then start.
        if Self.micFeed == nil, !askedMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            askedMicrophone = true
            Task { [weak self] in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self?.start(kind, title: title, sourceApp: sourceApp)
            }
            return
        }
        self.kind = kind
        let meeting = kind == .meeting
        self.sourceApp = sourceApp
        self.title = title
        attendees = []
        // Somebody else is on the line when a call app has the microphone, or the calendar says so.
        // A voice note is the user's own words: it looks for neither.
        let call = Self.micFeed == nil && meeting ? MeetingDetector.call() : (on: false, name: nil)
        // If the calendar has a meeting starting about now (one with other people or a call link; never a
        // game, a reminder or an all-day event), take its name, who is in it and what it says it is about.
        let event = meeting ? CalendarReader.shared.current(onCall: sourceApp != nil || call.on) : nil
        titleFromCalendar = false
        if let event {
            if title.isEmpty {
                self.title = event.title
                titleFromCalendar = true
            }
            attendees = event.attendees
            Log.write("record", "calendar: matched a meeting with \(event.attendees.count) other people")
        }
        if self.sourceApp == nil { self.sourceApp = call.name }
        let withOthers = meeting && (sourceApp != nil || call.on || (event?.isWithOthers ?? false))
        context = RecordingContext(event: event, app: self.sourceApp)
        context.kind = kind
        micWords = []
        systemWords = []
        shownSegments = []
        capturingSystem = false
        callSeen = sourceApp != nil || call.on
        soundChoice = nil
        onHeadphones = nil
        lastCallCheck = Date()
        lastScreenText = nil
        // The first look is a couple of seconds in, once whatever is being discussed is in front.
        lastLook = Date().addingTimeInterval(-18)
        warning = nil
        diskRoom = .ample
        lastDiskCheck = .distantPast
        liveSegments = []
        arrivals = []
        elapsed = 0
        startedAt = Date()

        // A line that arrives after its recording was saved (a step of finishing was given up on, and the
        // transcription it was waiting for came back later) belongs to no recording and is dropped.
        runID += 1
        let run = runID
        let add: @Sendable (TranscriptSegment, [SaidWord]) -> Void = { [weak self] segment, words in
            Task { @MainActor in
                guard let self, self.runID == run, self.phase != .idle else { return }
                self.add(segment, words: words)
            }
        }
        // A recording that could not be saved, or has not been recovered yet, is still in the folder: it is
        // moved aside, because a new journal starts by emptying that folder.
        journal?.close()
        journal = nil
        Self.parkUnsavedJournal()
        // The sound goes to disk as it arrives, so nothing is lost if Chirp quits before Stop.
        journal = try? RecordingJournal(directory: Self.journalDirectory)
        if journal == nil { Log.write("record", "could not start the on-disk journal; this recording is held in memory") }
        journalled = nil
        saveJournal()
        let models = models
        let ready: @Sendable () async -> Void = { try? await models.ensure(.transcription) }
        let micChannel = Channel(speaker: "Me", track: .mic, journal: journal, transcriber: models.transcriber, byVoice: meeting, ready: ready, onSegment: add)
        let systemChannel = Channel(speaker: "Them", track: .system, journal: journal, transcriber: models.transcriber, byVoice: meeting, ready: ready, onSegment: add)
        self.micChannel = micChannel
        self.systemChannel = systemChannel
        micInlet = nil
        systemInlet = nil

        // Microphone
        if let feed = Self.micFeed {
            feeders.append(Self.feed(feed, into: micChannel))
        } else {
            let inlet = Inlet(to: micChannel)
            micInlet = inlet
            // While a call app holds the microphone, macOS can hand it over far too quiet: it is brought
            // up to an ordinary level then, and left exactly as it is otherwise (`MicLeveler`).
            let level = MicLevel()
            micLevel = level
            saidMicGain = false
            level.set(active: sourceApp != nil || call.on)
            mic.onSamples = { samples in inlet.send(level.process(samples)) }
            mic.onLevel = { [weak self] level in Task { @MainActor in self?.push(level) } }
            do { try mic.start() } catch {
                warning = error.localizedDescription
            }
        }
        // System audio
        if let feed = Self.systemFeed, meeting {
            feeders.append(Self.feed(feed, into: systemChannel))
        } else if Self.micFeed == nil, withOthers, RecordingSound.include {
            // A note to yourself records only the microphone, so music or a video playing is not written down.
            captureSystem()
        }

        phase = .recording
        app.mood = .listening
        fullSpeed.begin("Recording")
        Log.write("record", "started a \(meeting ? "meeting" : "voice note") (\(self.sourceApp ?? "by hand"), \(capturingSystem ? "both sides" : "microphone only"))\(warning.map { ", warning: " + $0 } ?? "")")
        // The speech model stays loaded for the whole recording, however long nobody speaks.
        holdingSpeech = true
        Task {
            await models.transcriber.hold()
            try? await models.ensure(.transcription)
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.saveJournal()
                self.lookAtScreen()
                await self.checkCapture()
                await self.checkDisk()
            }
        }
    }

    /// Feeds a file into a channel in half-second chunks, much faster than real time (for tests).
    private static func feed(_ url: URL, into channel: Channel) -> Task<Void, Never> {
        Task.detached {
            guard let samples = try? AudioFile.samples(from: url) else { return }
            var i = 0
            while i < samples.count, !Task.isCancelled {
                await channel.append(Array(samples[i..<min(i + 8000, samples.count)]))
                i += 8000
            }
        }
    }

    /// Starts capturing this Mac's sound into the "Them" channel. If that fails, the recording carries on
    /// with the microphone alone and says so.
    private func captureSystem() {
        guard !capturingSystem, let systemChannel else { return }
        let inlet = systemInlet ?? Inlet(to: systemChannel)
        systemInlet = inlet
        system.onSamples = { samples in inlet.send(samples) }
        do {
            // The other side may be starting long after the microphone did: its sound goes where the
            // microphone has got to, not at the start.
            if let micChannel { inlet.catchUp(with: micChannel) }
            try system.start()
            capturingSystem = true
        } catch {
            warning = "Only your microphone is being recorded. " + error.localizedDescription
        }
    }

    /// Catches the silent-failure case: recording appears to run but no call audio arrives.
    private func checkCapture() async {
        guard Self.micFeed == nil, let systemChannel, let micChannel else { return }
        // A call that starts after the recording did is picked up too.
        if kind == .meeting, !callSeen, Date().timeIntervalSince(lastCallCheck) > 3 {
            lastCallCheck = Date()
            let call = MeetingDetector.call()
            if call.on {
                callSeen = true
                micLevel.set(active: true)
            }
            if call.on, !capturingSystem, soundChoice == nil, RecordingSound.include {
                Log.write("record", "another app took the microphone: recording both sides from here")
                if sourceApp == nil, let name = call.name {
                    sourceApp = name
                    context.app = name
                }
                captureSystem()
            }
        }
        // Headphones keep the other side out of the microphone. One look that finds a loudspeaker playing
        // is enough to say the microphone may have heard it.
        if capturingSystem, Date().timeIntervalSince(lastHeadphoneCheck) > 5 {
            lastHeadphoneCheck = Date()
            let before = liveHeadphones
            onHeadphones = (onHeadphones ?? true) && AudioDevices.outputsAreHeadphones()
            if liveHeadphones != before { refreshShown() }
        }
        guard elapsed > 12 else { return }
        // Silence from this Mac only means something is wrong when a call is known to be on: a meeting in a
        // room, or a video not started yet, is silent too.
        let systemSilent = capturingSystem && callSeen ? await systemChannel.loudest == 0 : false
        let micSilent = await micChannel.loudest == 0
        // Stop may have been pressed while the channels were being asked: capture must not be set up again after it.
        guard phase == .recording else { return }
        // Whether macOS lets Chirp record this Mac's sound is asked of macOS, not guessed from silence.
        let access = systemSilent ? SystemAudioPermission.status : .allowed
        if CaptureNotice.shouldRetryCapture(otherSideSilent: systemSilent, access: access), Self.systemFeed == nil, Date().timeIntervalSince(lastTapRetry) > 10 {
            // If System Audio Recording was allowed after the recording began, capture has to be set up again to hear it.
            lastTapRetry = Date()
            system.stop()
            systemInlet?.catchUp(with: micChannel)
            try? system.start()
        }
        if let notice = CaptureNotice.text(micSilent: micSilent, otherSideSilent: systemSilent, access: access) {
            if warning != notice { Log.write("record", "notice: \(notice) (System Audio Recording: \(access.rawValue))") }
            warning = notice
        } else if CaptureNotice.isOne(warning) {
            warning = nil
        }
        // Said once: how far a quiet microphone was turned up while another app held it.
        let gain = micLevel.gain
        if gain > 2, !saidMicGain {
            saidMicGain = true
            Log.write("record", String(format: "the microphone is quiet while another app holds it: turned up %.0f times", gain))
        }
    }

    /// Every few seconds while recording: whether there is still room on the disk. The recording is written
    /// to disk as it is made; with the disk full that stops, and without this check nothing would say so.
    private func checkDisk() async {
        guard Date().timeIntervalSince(lastDiskCheck) > 5 else { return }
        lastDiskCheck = Date()
        let lost = await (micChannel?.lostSamples ?? 0) + (systemChannel?.lostSamples ?? 0)
        guard phase == .recording else { return }
        // The folder the journal is in; the audio folder beside it may not have been made yet.
        let free = RecordingDisk.freeBytes(at: Self.journalDirectory.deletingLastPathComponent())
        let room: RecordingDisk.Room = lost > 0 ? .full : free.map(RecordingDisk.room(freeBytes:)) ?? .ample
        guard room != diskRoom else { return }
        diskRoom = room
        Log.write("record", "disk: \(room), \(free.map { "\($0 / 1_048_576) MB free" } ?? "free space unknown")\(lost > 0 ? ", \(lost) samples could not be written" : "")")
        switch room {
        case .full: Toast.show("The disk is full. This recording is no longer being saved.", seconds: 12)
        case .low: Toast.show("The disk is nearly full. Free some space to keep this recording safe.", seconds: 10)
        case .ample: break
        }
    }

    /// Keeps the title and the user's notes on disk beside the sound.
    private func saveJournal() {
        let meta = RecordingJournal.Meta(startedAt: startedAt, title: title, notes: "", context: context, sourceApp: sourceApp)
        guard meta != journalled else { return }
        journalled = meta
        journal?.save(meta)
    }

    /// Every so often, reads the window in front and keeps it when it says something new.
    private func lookAtScreen() {
        // Switched off completely: nothing reads the screen by itself (see `ScreenReader.automatic`).
        guard ScreenReader.automatic else { return }
        guard !looking, phase == .recording, context.screens.count < Self.maxScreens,
            Date().timeIntervalSince(lastLook) >= lookEvery
        else { return }
        lastLook = Date()
        looking = true
        let at = elapsed
        let began = startedAt
        // Stop waits for a look that is under way, so the last screen is not lost.
        lookTask = Task {
            defer { looking = false }
            guard let shot = await ScreenReader.look(), began == startedAt, phase != .idle,
                RecordingContext.isNewScreen(shot.text, after: lastScreenText)
            else { return }
            lastScreenText = shot.text
            let name = "screen-\(Int(startedAt.timeIntervalSince1970))-\(context.screens.count + 1).jpg"
            let kept = ScreenReader.save(shot.image, as: name)
            context.screens.append(.init(at: at, app: shot.app, window: shot.window, text: String(shot.text.prefix(1500)), image: kept ? name : nil))
            Log.write("record", "screen: kept what \(shot.app) was showing (\(TextStats.words(shot.text)) words)")
        }
    }

    /// Gives a document to the recording being made: its text helps the notes get names, numbers and terms right.
    @discardableResult
    func attach(_ url: URL) -> Bool {
        guard phase == .recording, let attachment = Self.attachment(from: url) else { return false }
        context.attachments.append(attachment)
        saveJournal()
        Log.write("record", "a file was attached to the recording (\(attachment.isSearchable ? "text read" : "not searchable"))")
        return true
    }

    /// Gives a document to a saved recording. "Redo notes" then takes it into account.
    @discardableResult
    func attach(_ url: URL, to id: Int64) -> Bool {
        guard var item = try? library.item(id), let attachment = Self.attachment(from: url) else { return false }
        var context = RecordingContext(json: item.context)
        context.attachments.append(attachment)
        item.context = context.json
        _ = try? library.save(item)
        try? library.setAttachmentText(itemID: id, text: context.searchText)
        version += 1
        Log.write("record", "a file was attached to a saved recording (\(attachment.isSearchable ? "text read" : "not searchable"))")
        return true
    }

    /// Takes one attached file away from a saved recording: its copy is deleted and it is no longer searched.
    func removeAttachment(at index: Int, from id: Int64) {
        guard var item = try? library.item(id) else { return }
        var context = RecordingContext(json: item.context)
        guard context.attachments.indices.contains(index) else { return }
        let gone = context.attachments.remove(at: index)
        if let file = Self.attachmentURL(gone) { try? FileManager.default.removeItem(at: file) }
        item.context = context.json
        _ = try? library.save(item)
        try? library.setAttachmentText(itemID: id, text: context.searchText)
        version += 1
    }

    /// How attached files reach the notes: "names" (their names and terms, as spellings to get right) or
    /// "excerpt" (those and a short excerpt of their text).
    static let attachDefault = "names"

    /// Where the files attached to recordings are kept: beside the audio, in Chirp's own data folder.
    static var attachmentsDirectory: URL {
        ChirpStore.audioDirectory.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    /// The kept copy of an attached file, when there is one.
    static func attachmentURL(_ attachment: RecordingContext.Attachment) -> URL? {
        attachment.file.map { attachmentsDirectory.appendingPathComponent($0) }
    }

    /// Copies a file into Chirp's folder and reads what text it can from it. Nil only when it cannot be copied.
    private static func attachment(from url: URL) -> RecordingContext.Attachment? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
        let kept = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: attachmentsDirectory.appendingPathComponent(kept))
        } catch {
            Log.write("record", "a file could not be attached: \(error.localizedDescription)")
            return nil
        }
        let text = DocumentImporter.attachmentText(url).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(name: url.lastPathComponent, text: String(text.prefix(RecordingContext.attachmentCharacters)), file: kept)
    }

    /// Deletes the kept copies of a recording's attached files.
    private static func removeAttachments(of context: RecordingContext) {
        for attachment in context.attachments {
            if let file = attachmentURL(attachment) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The short excerpt of the attached files handed to the notes model, while notes are being written.
    private var notesReference: String?

    /// Lets the speech model be unloaded again once this recording no longer needs it.
    private func releaseSpeech() {
        guard holdingSpeech else { return }
        holdingSpeech = false
        Task { [models] in await models.transcriber.release() }
    }

    /// Moves a journal that still holds unsaved sound out of the folder a new recording is about to empty.
    private static func parkUnsavedJournal() {
        guard RecordingJournal.recover(from: journalDirectory) != nil else { return }
        if moveJournal(to: parkedDirectory) != nil {
            Log.write("record", "an unsaved recording was moved aside; it is finished the next time Chirp opens")
        }
    }

    /// Moves the journal folder into a folder of its own under `parent`. Returns where it went, or nil if it could not be moved.
    private static func moveJournal(to parent: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalDirectory.path) else { return nil }
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var target = parent.appendingPathComponent("\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        if fm.fileExists(atPath: target.path) { target = parent.appendingPathComponent(UUID().uuidString, isDirectory: true) }
        do {
            try fm.moveItem(at: journalDirectory, to: target)
            return target
        } catch {
            Log.write("record", "a journal could not be moved aside: \(error.localizedDescription)")
            return nil
        }
    }

    /// Brings the oldest journal that was moved aside back to where recovery looks. Returns whether there was one.
    private static func takeParkedJournal() -> Bool {
        let fm = FileManager.default
        let parked = ((try? fm.contentsOfDirectory(at: parkedDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let oldest = parked.first else { return false }
        try? fm.removeItem(at: journalDirectory)
        return (try? fm.moveItem(at: oldest, to: journalDirectory)) != nil
    }

    /// Closes the journal and removes its folder: the recording is saved, or was not worth saving.
    private func dropJournal() {
        journal?.discard()
        journal = nil
        RecordingJournal.remove(Self.journalDirectory)
    }

    /// Removes the pictures kept for a recording: the ones the user took, and those older recordings took by themselves.
    private static func removeScreenPictures(of context: RecordingContext) {
        for image in context.screens.compactMap(\.image) + context.notes.compactMap(\.image) {
            try? FileManager.default.removeItem(at: ChirpStore.audioDirectory.appendingPathComponent(image))
        }
    }

    // MARK: Timed notes and pictures

    /// Keeps a typed line with the time it was sent, as Enter does. Returns whether anything was kept.
    @discardableResult
    func sendNote(_ text: String, at time: Double? = nil) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .recording, !line.isEmpty else { return false }
        context.notes.append(TimedNote(at: time ?? elapsed, text: line))
        saveJournal()
        Log.write("record", "a note was kept at \((time ?? elapsed).clock)")
        return true
    }

    /// Keeps a picture of the window in front, with the time. Its words are read for search only.
    /// Says why when it cannot: the permission is missing, or there is no window to take.
    @discardableResult
    func capture(at time: Double? = nil) async -> Bool {
        guard phase == .recording, !capturing else { return false }
        capturing = true
        defer { capturing = false }
        let at = time ?? elapsed
        let began = startedAt
        if MeetingRecorder.feedFile("--feed-screen") == nil, !ScreenReader.allowed {
            // macOS asks once; after that it has to be allowed in System Settings.
            ScreenReader.ask()
            say("Allow Screen Recording for Chirp in System Settings to keep pictures.")
            Log.write("record", "a picture was asked for without the Screen Recording permission")
            return false
        }
        guard let shot = await ScreenReader.look(byHand: true, readText: false), began == startedAt, phase == .recording else {
            Log.write("record", "a picture was asked for and there was nothing to take")
            if began == startedAt, phase == .recording { say("There is no window in front to take a picture of.") }
            return false
        }
        let name = "capture-\(Int(startedAt.timeIntervalSince1970))-\(context.notes.count + 1).jpg"
        guard ScreenReader.save(shot.image, as: name) else {
            say("The picture could not be saved.")
            return false
        }
        context.notes.append(TimedNote(at: at, image: name, app: shot.app, window: shot.window))
        saveJournal()
        Log.write("record", "a picture of \(shot.app) was kept at \(at.clock)")
        // Its words are read afterwards, for search only: the picture is kept at once however long that takes.
        let image = SendablePicture(image: shot.image)
        Task { [weak self] in
            let text = await ScreenReader.read(image.image)
            self?.fillWords(String(text.prefix(1500)), forPicture: name)
        }
        return true
    }

    private struct SendablePicture: @unchecked Sendable { let image: CGImage }

    /// Puts the words read off a kept picture with it: in the recording being made, or in the saved one
    /// if it was saved meanwhile.
    private func fillWords(_ text: String, forPicture name: String) {
        guard !text.isEmpty else { return Log.write("record", "no words were read off a picture") }
        let words = TextStats.words(text)
        if let at = context.notes.firstIndex(where: { $0.image == name }) {
            context.notes[at].seen = text
            saveJournal()
            Log.write("record", "\(words) words were read off a picture, for search")
            return
        }
        for var item in (try? library.items(kinds: [.meeting, .voiceNote], limit: 5)) ?? [] {
            var given = RecordingContext(json: item.context)
            guard let at = given.notes.firstIndex(where: { $0.image == name }), let id = item.id else { continue }
            given.notes[at].seen = text
            item.context = given.json
            _ = try? library.save(item)
            try? library.setAttachmentText(itemID: id, text: given.searchText)
            Log.write("record", "\(words) words were read off a picture of a saved recording, for search")
            return
        }
    }

    /// Says a line where it will be seen: the bird's bubble, or a toast when there is no perch.
    private func say(_ text: String) {
        if let perch = PerchController.shared { perch.say(text, seconds: 6, error: true) } else { Toast.show(text, seconds: 6) }
    }

    /// Where a kept picture is on disk.
    static func pictureURL(_ note: TimedNote) -> URL? {
        note.image.map { ChirpStore.audioDirectory.appendingPathComponent($0) }
    }

    /// Whether everything the Mac plays is going to headphones, as far as is known while recording: then
    /// the microphone cannot be hearing it, and none of the user's lines is an echo.
    private var liveHeadphones: Bool {
        if let forced = RecordTestHooks.value("headphones") { return forced == "1" }
        // In a fed run the two sides are files: treated as loudspeakers, as when it is saved.
        if Self.micFeed != nil { return false }
        guard capturingSystem else { return true }
        return onHeadphones ?? AudioDevices.outputsAreHeadphones()
    }

    /// Works out again which lines are shown.
    private func refreshShown() {
        let headphones = liveHeadphones
        shownSegments = kind == .meeting ? MeetingText.shown(liveSegments, headphones: headphones) : liveSegments
    }

    // MARK: What the Library shows before a recording is saved

    /// True while the Library's detail column is showing the recording being made (the window says so).
    var liveOpen = false
    /// Bumped when the recording's own row in the Library is pressed, so the window opens it.
    private(set) var openLiveAsked = 0
    func openLive() { openLiveAsked += 1 }

    /// The row a recording has in the Library from the moment it starts until it is saved.
    struct ProgressRow: Equatable {
        var kind: RecordingKind
        var title: String
        var line: String
        var live: Bool
    }

    var progressRow: ProgressRow? {
        let name = title.isEmpty ? kind.untitled : title
        switch phase {
        case .idle: return nil
        case .recording: return ProgressRow(kind: kind, title: name, line: ProgressLine.recording(kind, elapsed: elapsed), live: true)
        case .finishing: return ProgressRow(kind: kind, title: name, line: ProgressLine.finishing, live: false)
        }
    }

    /// What a saved recording's row says while its notes are not written yet: "Writing notes…", or what it waits for.
    func notesLine(for id: Int64) -> String? {
        if writingNotesFor == id { return stoppingNotes ? ProgressLine.stoppingNotes : ProgressLine.writingNotes }
        if let job = notesJobs[id], let waiting = Jobs.shared.line.waitingLine(for: job) { return waiting }
        return notesAsked.contains(id) ? ProgressLine.writingNotes : nil
    }

    /// Cancel on a recording whose notes are waiting their turn: it stays saved with its transcript, and
    /// the notes can be written later.
    func cancelWaitingNotes(for id: Int64) {
        if let job = notesJobs[id] { Jobs.shared.cancel(job) }
    }

    /// Where a recording's notes are: being written (Stop ends them), waiting their turn (Cancel takes
    /// them out of the line), or being stopped.
    enum NotesState { case writing, waiting, stopping }

    func notesState(for id: Int64) -> NotesState? {
        guard let line = notesLine(for: id) else { return nil }
        if writingNotesFor == id { return stoppingNotes ? .stopping : .writing }
        return line == ProgressLine.writingNotes ? nil : .waiting
    }

    /// Stop (or Cancel) on a recording's notes, wherever it is pressed: the menu bar, the perch, its row.
    /// Notes being written end within a few seconds; notes waiting their turn leave the line. Either way
    /// the meeting stays saved with its transcript (and any notes it already had), and "Write notes"
    /// writes them later.
    func stopNotes(for id: Int64) {
        if writingNotesFor == id {
            guard !stoppingNotes, let notesWork else { return }
            stoppingNotes = true
            notesStoppedFor = id
            notesWork.cancel()
            Log.write("record", "notes for a meeting were stopped while they were being written")
        } else {
            cancelWaitingNotes(for: id)
        }
    }

    /// Stop on the notes being written now, if any.
    func stopNotes() {
        if let id = writingNotesFor { stopNotes(for: id) }
    }

    /// The place in the line of each recording whose notes were asked for.
    private var notesJobs: [Int64: Int] = [:]

    /// Finishes a recording left on disk by a run that ended before Stop, or moved aside by a later recording.
    /// One at a time: the folder in use first, then each one that was moved aside, oldest first.
    private func recover() async {
        guard phase == .idle, journal == nil else { return }
        if RecordingJournal.recover(from: Self.journalDirectory) == nil { _ = Self.takeParkedJournal() }
        guard let found = RecordingJournal.recover(from: Self.journalDirectory) else {
            RecordingJournal.remove(Self.journalDirectory)
            return
        }
        let seconds = Double(max(found.micSamples, found.systemSamples)) / 16_000
        Log.write("record", String(format: "recovering a recording of %.0f s with %d transcript lines", seconds, found.segments.count))
        startedAt = found.meta.startedAt
        title = found.meta.title
        context = found.meta.context
        // A journal from before notes had times held them as one text: it is kept as a note at the start.
        if !found.meta.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, context.notes.isEmpty {
            context.notes = [TimedNote(at: 0, text: found.meta.notes)]
        }
        // One from before the kind was chosen is what it sounds like: other people in it, a meeting.
        kind = context.kind ?? (found.segments.contains { $0.speaker != "Me" } || !context.attendees.isEmpty ? .meeting : .voiceNote)
        micWords = []
        systemWords = []
        attendees = found.meta.context.attendees
        sourceApp = found.meta.sourceApp
        liveSegments = found.segments
        refreshShown()
        phase = .finishing("Recovering your recording")
        app.mood = .thinking
        fullSpeed.begin("Recovering a recording")
        // The sound is all there, but the run that made it ended before all of it had been transcribed.
        stoppedAt = Date()
        gaveUpOn = []
        await step("missed", "transcribing what was missed", limit: max(300, seconds)) { await self.transcribeMissed() }
        await finish(
            mic: .onDisk(RecordingJournal.url(.mic, in: Self.journalDirectory)),
            system: .onDisk(RecordingJournal.url(.system, in: Self.journalDirectory)), wallDuration: seconds)
        Toast.show("Recovered the recording Chirp was making when it quit", seconds: 8)
        // That one is done with (its folder is gone): go on to the next that was moved aside, if any.
        if !FileManager.default.fileExists(atPath: Self.journalDirectory.path), Self.takeParkedJournal() { await recover() }
    }

    /// Transcribes the stretches of the journal's sound that no line covers: what was said after the last
    /// line before a crash, and pieces the speech model failed on. The sound is read from disk a little at
    /// a time. Returns how many lines were added.
    @discardableResult
    private func transcribeMissed() async -> Int {
        guard (try? await models.ensure(.transcription)) != nil else { return 0 }
        var added = 0
        for (track, speaker) in [(RecordingJournal.Track.mic, "Me"), (.system, "Them")] {
            let url = RecordingJournal.url(track, in: Self.journalDirectory)
            let gaps = MeetingText.uncovered(
                samples: RecordingJournal.sampleCount(at: url), lines: liveSegments.filter { $0.speaker == speaker }, shortest: 2)
            for gap in gaps {
                // Given up on (its limit passed): nothing more is added to a recording that has moved on.
                if Task.isCancelled { return added }
                var cutter = PauseSegmenter()
                _ = cutter.skip(to: gap.lowerBound)
                var at = gap.lowerBound
                var pieces: [PauseSegmenter.Piece] = []
                while at < gap.upperBound {
                    // Ten seconds at a time: a long stretch is never held whole.
                    let chunk = RecordingJournal.samples(at: url, from: at, count: min(160_000, gap.upperBound - at))
                    guard !chunk.isEmpty else { break }
                    at += chunk.count
                    pieces = cutter.append(chunk)
                    if at >= gap.upperBound, let last = cutter.finish() { pieces.append(last) }
                    for piece in pieces where PauseSegmenter.rms(piece.samples[...]) > 0.002 {
                        guard let transcript = try? await models.transcriber.transcribe(piece.samples), !transcript.text.isEmpty, !Task.isCancelled else { continue }
                        let line = TranscriptSegment(itemID: 0, speaker: speaker, start: piece.start, end: piece.end, text: transcript.text)
                        journal?.add(line)
                        liveSegments.append(line)
                        added += 1
                    }
                }
            }
        }
        liveSegments.sort { $0.start < $1.start }
        refreshShown()
        if added > 0 { Log.write("record", "\(added) lines were transcribed from sound that had none") }
        return added
    }

    /// Takes a newly transcribed line into the live transcript and the journal.
    private func add(_ segment: TranscriptSegment, words: [SaidWord] = []) {
        journal?.add(segment)
        arrivals.append(Date().timeIntervalSince(startedAt))
        liveSegments.append(segment)
        liveSegments.sort { $0.start < $1.start }
        if segment.speaker == "Me" { micWords += words } else { systemWords += words }
        let before = echoesDropped
        refreshShown()
        // Said once for each line left out, so the log shows the rule working while the recording runs.
        if echoesDropped > before {
            Log.write("record", String(format: "live: a microphone line at %@ repeats this Mac's sound and is not shown (%d so far)", segment.start.clock, echoesDropped))
        }
    }

    /// Adds the newest microphone level to the wire and drops the oldest.
    private func push(_ level: Double) {
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: Stop and finish

    /// Stops capturing, lets the last pieces be transcribed, then saves the recording.
    func stop() {
        guard phase == .recording, let micChannel, let systemChannel else { return }
        ticker?.cancel()
        let duration = Self.micFeed == nil ? Date().timeIntervalSince(startedAt) : 0
        if Self.micFeed == nil {
            mic.stop()
            if capturingSystem { system.stop() }
            capturingSystem = false
        }
        phase = .finishing("Finishing the transcript")
        app.mood = .thinking
        Log.write("record", String(format: "stopped after %.0f s with %d transcript lines so far", duration, liveSegments.count))
        let pending = feeders
        feeders = []
        let inlets = [micInlet, systemInlet].compactMap { $0 }
        micInlet = nil
        systemInlet = nil
        let look = lookTask
        stoppedAt = Date()
        gaveUpOn = []
        Task {
            // Every wait from here to "saved" has a limit and a line in the log: a wait that never
            // came back would leave the recording in "Finishing" until Chirp was restarted.
            if !pending.isEmpty { await self.step("feed", "the sound fed in", limit: 300) { for f in pending { await f.value } } }
            if look != nil { await self.step("look", "the last look at the screen", limit: 10) { await look?.value } }
            // Everything captured reaches its channel before the channel is asked to finish.
            await self.step("inlets", "the last sound reaching the transcript", limit: 20) { for inlet in inlets { await inlet.close() } }
            // Each waits for all of its pieces to be transcribed, in order. Live, that is the last few
            // seconds; the limit allows for a backlog and grows with the length of the recording.
            let heard = await self.step("length", "measuring the recording", limit: 5) { await max(micChannel.receivedSamples, systemChannel.receivedSamples) } ?? 0
            let limit = max(120, Double(heard) / 16_000 / 2)
            let micAudio = await self.step("mic", "transcribing the rest of the microphone", limit: limit) { await micChannel.finish() }
            let systemAudio = await self.step("system", "transcribing the rest of the other side", limit: limit) { await systemChannel.finish() }
            var failed = await self.step("count", "counting what could not be transcribed", limit: 5) { await micChannel.failedPieces + systemChannel.failedPieces } ?? 0
            // A side that never finished has sound nobody transcribed: it counts as failed, so the sound
            // is tried once more below, the audio is kept, and the user is told.
            if micAudio == nil || systemAudio == nil { failed += 1 }
            // The loudest moment of either side: a recording with sound in it is kept even when no words were found.
            let peak = await self.step("peak", "measuring the sound", limit: 5) { await max(micChannel.loudest, systemChannel.loudest) } ?? 0
            // Let the last segment callbacks land on the main actor.
            try? await Task.sleep(for: .milliseconds(200))
            let onDisk = self.journal != nil
            // Pieces the speech model failed on are still on disk: they are tried once more.
            var stillFailed = failed
            if failed > 0, onDisk {
                self.journal?.flush()
                if await self.step("missed", "transcribing what was missed", limit: limit, { await self.transcribeMissed() }) ?? 0 > 0, micAudio != nil, systemAudio != nil {
                    stillFailed = 0
                }
            }
            await self.finish(
                mic: onDisk ? .onDisk(RecordingJournal.url(.mic, in: Self.journalDirectory)) : .inMemory(micAudio ?? []),
                system: onDisk ? .onDisk(RecordingJournal.url(.system, in: Self.journalDirectory)) : .inMemory(systemAudio ?? []),
                wallDuration: duration, failedPieces: stillFailed, heardSound: peak > Self.soundPeak)
        }
    }

    /// A side whose loudest moment is above this had real sound in it, not the hiss of a quiet room.
    static let soundPeak: Float = 0.02

    /// TESTING: what the last `mic-trial` or `call-name` link found.
    private var micTrial: [String: Any] = [:]
    /// Brings the microphone up to level while a call app holds it.
    private var micLevel = MicLevel()
    private var saidMicGain = false
    /// When Stop was pressed, for the log's timings.
    private var stoppedAt = Date()
    /// The steps of finishing that did not end within their limit, by short name (`state` shows them).
    private(set) var gaveUpOn: [String] = []
    /// Counts recordings, so a transcribed line that arrives late is not put in the next one.
    private var runID = 0

    /// One step of finishing a recording, with a limit: says in the log how long it took, or that it was
    /// given up on. The step is then left behind and the recording is finished with what there is.
    /// TESTING (`CHIRP_RECORD_TEST`): `stall=<id>` makes that step never end, and `stepLimit=<seconds>`
    /// is every step's limit.
    @discardableResult
    private func step<T: Sendable>(_ id: String, _ name: String, limit: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        let began = Date()
        let seconds = RecordTestHooks.value("stepLimit").flatMap(Double.init) ?? limit
        let stalled = RecordTestHooks.value("stall") == id
        let value = await Deadline.run(seconds: seconds) { () -> T in
            if stalled { try? await Task.sleep(for: .seconds(86_400)) }
            return await work()
        }
        let took = Date().timeIntervalSince(began)
        if value == nil {
            gaveUpOn.append(id)
            Log.write("record", String(format: "finishing: %@ did not end in %.0f s; carrying on without it", name, seconds))
        } else if took >= 0.05 || LinkHandler.debugEnabled {
            Log.write("record", String(format: "finishing: %@ took %.1f s", name, took))
        }
        return value
    }

    /// Turns the captured sound and live transcript into a saved recording: speaker labels, the user's
    /// dictionary, the audio file, then notes and a title. Also finishes a recording recovered after a crash.
    /// `failedPieces` is how many stretches of sound could not be transcribed.
    /// `heardSound` is true when there was real sound in it, whatever was made of it.
    private func finish(mic: Sound, system: Sound, wallDuration: Double, failedPieces: Int = 0, heardSound: Bool = false) async {
        defer {
            phase = .idle
            app.mood = .idle
            fullSpeed.end()
            micChannel = nil
            systemChannel = nil
        }
        releaseSpeech()
        // On headphones the microphone never hears the other side, so a line of the user's that repeats
        // their words is the user's own.
        let headphones = RecordTestHooks.value("headphones").map { $0 == "1" } ?? (onHeadphones ?? false)
        let meeting = kind == .meeting
        // A voice note has no other side: every line is the user's.
        var segments = !meeting ? liveSegments : MeetingText.shown(liveSegments, headphones: headphones)
        if meeting, headphones { Log.write("record", "on headphones throughout: no microphone line was dropped as an echo") }
        if segments.count < liveSegments.count {
            Log.write("record", "\(liveSegments.count - segments.count) of \(liveSegments.filter { $0.speaker == "Me" }.count) microphone lines repeated this Mac's sound and were dropped")
        }
        let duration = max(wallDuration, Double(max(mic.samples, system.samples)) / 16_000)

        // Who spoke when, on the other side of the call. With one other person invited there is nobody to
        // tell apart.
        let oneToOne = attendees.count == 1
        if oneToOne, segments.contains(where: { $0.speaker == "Them" }) {
            Log.write("record", "one other person was invited: the other side is not separated into speakers")
        }
        if meeting, tellSpeakersApart, Double(system.samples) / 16_000 > 15, segments.contains(where: { $0.speaker == "Them" }), !oneToOne {
            phase = .finishing("Working out who spoke")
            let began = Date()
            do {
                try await Deadline.attempt(seconds: stepLimit(180)) { [models] in try await models.ensure(.speakers) }
                // The other side is the only sound loaded whole, and only for this. (The helper has its own
                // limit: five minutes, or four times the length of the sound.)
                let turns = try await speakers.turns(in: system.load())
                // Word by word: a line that holds two people's turns is split where the voice changes.
                let lines = segments.count
                segments = MeetingText.speakersByWord(segments, words: systemWords, turns: turns, replacing: "Them")
                if segments.count != lines { Log.write("record", "speakers by word: \(lines) lines became \(segments.count)") }
                Log.write(
                    "record",
                    String(
                        format: "speakers: %d voices in %.0f s of the other side, in %.1f s", Set(turns.map(\.speaker)).count,
                        Double(system.samples) / 16_000, Date().timeIntervalSince(began)))
            } catch {
                // Speaker labels are a nicety; the transcript stands without them. Said in the log, so a
                // recording saved without them (the helper died, or took too long) can be told from one
                // with a single voice.
                let why = error is Deadline.Passed ? "the speaker model did not load in time" : error.localizedDescription
                Log.write("record", String(format: "speakers were not told apart after %.1f s: %@", Date().timeIntervalSince(began), why))
                if error is Deadline.Passed { gaveUpOn.append("speakers") }
            }
        }

        // People in the same room share the microphone. When nobody was heard through the Mac, the microphone
        // is listened to for more than one voice, so a meeting round a table or a lecture is not written up
        // as one person talking to themselves. Which voice is the user's cannot be known; they rename it.
        if meeting, !segments.contains(where: { $0.speaker != "Me" }), Double(mic.samples) / 16_000 > 15, !segments.isEmpty {
            phase = .finishing("Working out who spoke")
            let began = Date()
            let ready = (try? await Deadline.attempt(seconds: stepLimit(180)) { [models] in try await models.ensure(.speakers) }) != nil
            if !ready { Log.write("record", String(format: "voices on the microphone were not told apart: the speaker model was not ready after %.1f s", Date().timeIntervalSince(began))) }
            if ready, let turns = try? await speakers.turns(in: mic.load()) {
                segments = MeetingText.speakersByWord(segments, words: micWords, turns: MeetingText.significant(turns), replacing: "Me")
                if segments.contains(where: { $0.speaker != "Me" }) {
                    Log.write("record", "more than one voice on the microphone: \(Set(segments.map(\.speaker)).count) speakers")
                }
            }
        }

        // The speaker model is only needed here, once per recording: it does not stay in memory.
        if meeting { await step("unload", "putting the speaker model away", limit: 20) { [models] in await models.unload(.speakers) } }

        // The user's dictionary applies to meetings too.
        if let entries = try? app.engine.dictionary(), !entries.isEmpty {
            let corrector = DictionaryCorrector(entries: entries)
            for i in segments.indices { segments[i].text = corrector.correct(segments[i].text) }
        }

        if failedPieces > 0 { Log.write("record", "\(failedPieces) pieces with sound in them could not be transcribed") }
        // A short recording in which nothing was said, with nothing typed, is not worth keeping. One whose
        // transcription failed is kept: something may well have been said.
        // One with sound in it but no words is kept too, with its audio: it was started and stopped by the
        // user, and what Chirp could not make out may still matter.
        let wordless = segments.isEmpty && failedPieces == 0 && heardSound
        if segments.isEmpty, failedPieces == 0, !heardSound, context.notes.isEmpty,
            context.attachments.isEmpty, duration < 120
        {
            Log.write("record", String(format: "nothing was said in %.0f s: not saved", duration))
            Self.removeScreenPictures(of: context)
            Self.removeAttachments(of: context)
            dropJournal()
            liveSegments = []
            shownSegments = []
            Toast.show("Nothing was said, so nothing was saved", seconds: 5)
            return
        }

        var audioFile: String?
        // True when the audio file was wanted but could not be written.
        var audioLost = false
        // When part of it could not be transcribed the sound is the only record of what was said, so it is kept.
        // Meetings and notes each have their own setting (Settings › Meetings, Settings › Notes).
        if (meeting ? keepAudio : keepNoteAudio) || failedPieces > 0 || wordless {
            let name = "meeting-\(Int(Date().timeIntervalSince1970)).m4a"
            let target = ChirpStore.audioDirectory.appendingPathComponent(name)
            var written = false
            if case .onDisk(let a) = mic, case .onDisk(let b) = system {
                // Mixed a few seconds at a time, straight from the files, and off the main thread: an hour
                // of sound takes seconds to encode.
                written = await step("audio", "writing the audio file", limit: max(120, duration)) {
                    await Task.detached { (try? AudioFile.writeMix(of: [a, b], to: target)) != nil }.value
                } ?? false
            } else {
                written = (try? AudioFile.write(Self.mix(mic.load(), system.load()), to: target)) != nil
            }
            if written {
                audioFile = name
            } else {
                audioLost = true
                Log.write("record", "the audio file could not be written")
            }
        }

        // What it is was chosen when it was started; nothing here guesses it.
        let itemKind = kind.itemKind
        // A voice note is dictation that is kept: it gets dictation's tidying (filler words, changes of
        // mind, spoken punctuation) and is saved as clean text. What people said in a meeting is left as they said it.
        var spoken = ""
        var clean = ""
        if !meeting, let pipeline = try? DictationPipeline(engine: app.engine) {
            spoken = segments.map(\.text).joined(separator: " ")
            for i in segments.indices {
                segments[i].speaker = "Me"
                let tidy = pipeline.process(segments[i].text)
                if !tidy.isEmpty { segments[i].text = tidy }
            }
            clean = MeetingText.cleanText(segments)
        }
        let stamp = startedAt.formatted(date: .abbreviated, time: .shortened)
        var fallbackTitle = meeting ? (sourceApp.map { "\($0) call" } ?? "Meeting") + ", " + stamp : stamp
        // A voice note is named from its own opening words, at once and by rule (Settings › Notes › Title
        // from the first words; off, the title is the date and time).
        if !meeting, Self.noteTitleFromWords, case let opening = MeetingText.openingTitle(segments), !opening.isEmpty { fallbackTitle = opening }
        let untitled = title.isEmpty
        do {
            let item = try library.save(
                SavedItem(
                    kind: itemKind, title: untitled ? fallbackTitle : title, body: clean, rawText: spoken, audioFile: audioFile,
                    duration: duration, source: attendees.isEmpty ? nil : attendees.joined(separator: ", "), createdAt: startedAt,
                    context: context.json))
            guard let id = item.id else { return }
            try library.replaceSegments(itemID: id, with: segments)
            try? library.setAttachmentText(itemID: id, text: context.searchText)
            if audioLost, FileManager.default.fileExists(atPath: Self.journalDirectory.path) {
                // The words are saved but the audio file is not: the sound itself is kept, out of recovery's way.
                journal?.close()
                journal = nil
                if let kept = Self.moveJournal(to: Self.keptSoundDirectory) {
                    Log.write("record", "the sound was kept in \(kept.lastPathComponent) under \(Self.keptSoundDirectory.lastPathComponent)")
                } else {
                    RecordingJournal.remove(Self.journalDirectory)
                }
            } else {
                // Saved: the copy on disk is no longer needed.
                dropJournal()
            }
            lastSavedID = id
            version += 1
            liveSegments = []
            shownSegments = []
            let kept = context.notes
            context = RecordingContext()
            Log.write(
                "record",
                "saved as a \(meeting ? "meeting" : "voice note"): \(segments.count) lines, \(segments.filter { $0.speaker == "Me" }.count) from the microphone, "
                    + "\(kept.filter { !$0.isPicture }.count) notes and \(kept.filter(\.isPicture).count) pictures kept")
            Log.write("record", String(format: "finishing: saved %.1f s after Stop%@", Date().timeIntervalSince(stoppedAt), gaveUpOn.isEmpty ? "" : "; given up on: " + gaveUpOn.joined(separator: ", ")))
            if audioLost {
                Toast.show("The recording was saved, but its audio file could not be written", seconds: 8)
            } else if failedPieces > 0 {
                Toast.show("Part of this recording could not be transcribed. Its audio was kept.", seconds: 8)
            } else if wordless {
                Log.write("record", "no words were found in a recording with sound in it: saved with its audio")
                Toast.show("No words were found. The recording was saved with its audio.", seconds: 8)
            } else if !meeting {
                // A voice note is done the moment it is saved: nothing is written about it.
                // A voice note is a note (Rec13): it is saved to Notes, where it opens as an editable note.
                if let perch = PerchController.shared {
                    perch.say("Saved to Notes", seconds: 4, action: ("Open", { [weak self] in
                        self?.app.open(item)
                        AppDelegate.showMain()
                    }))
                } else {
                    Toast.show("Saved to Notes", seconds: 4)
                }
            }
            guard !segments.isEmpty, RecordTestHooks.on("notes") else { return }
            // The recording is saved and the recorder is free for the next one. What is written about it
            // takes its turn behind any other job, and its row in the Library says so meanwhile.
            if meeting {
                notesAsked.insert(id)
                Task {
                    await self.writeNotes(for: id, reserved: true)
                    if untitled { await self.nameMeeting(id) }
                }
            }
            // A voice note is a note: Chirp never writes into it, so it keeps the title from its own opening
            // words.
        } catch {
            app.report(error, doing: "save the recording")
            // The journal folder stays: it holds the only copy. It is finished the next time Chirp opens,
            // and a new recording moves it aside, not over it.
            journal?.close()
            journal = nil
        }
    }

    /// A limit in seconds, or the one a test run set for every step (`stepLimit`).
    private func stepLimit(_ seconds: Double) -> Double { RecordTestHooks.value("stepLimit").flatMap(Double.init) ?? seconds }

    /// Both sides as one track, each turned down a little so the sum does not clip.
    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: max(a.count, b.count))
        for i in a.indices { out[i] += a[i] * 0.6 }
        for i in b.indices { out[i] += b[i] * 0.6 }
        return out
    }

    // MARK: Notes

    /// Writes (or rewrites) a saved meeting's notes from its transcript: a summary, key points and
    /// decisions. A voice note has none. It takes its turn in the line of jobs: when a link or a file is
    /// being transcribed, or other notes written, it waits and its row says what for; Cancel while it
    /// waits leaves the meeting saved with its transcript.
    /// `reserved` is true when the caller has already marked these notes as asked for (so the recording's
    /// row says so from the moment it is saved).
    func writeNotes(for id: Int64, reserved: Bool = false) async {
        guard let item = try? library.item(id), item.kind == .meeting, reserved || !notesAsked.contains(id) else {
            if reserved { notesAsked.remove(id) }
            return
        }
        let segments = (try? library.segments(itemID: id)) ?? []
        guard !segments.isEmpty else {
            notesAsked.remove(id)
            return
        }
        notesAsked.insert(id)
        let job = Jobs.shared.add(item.title.isEmpty ? "the meeting" : item.title, itemID: id)
        notesJobs[id] = job
        defer {
            notesAsked.remove(id)
            notesJobs[id] = nil
            Jobs.shared.done(job)
        }
        guard await Jobs.shared.turn(job) else {
            Log.write("record", "notes for a meeting were cancelled while they waited their turn")
            return
        }
        writingNotesFor = id
        if notesStoppedFor == id { notesStoppedFor = nil }
        // The language model is called many times below; it must not be unloaded part-way.
        models.beginUse(.language)
        defer {
            models.endUse(.language)
            writingNotesFor = nil
            stoppingNotes = false
            notesWork = nil
        }
        // In a task of its own, so Stop can end it wherever it has got to.
        let work = Task { [weak self] in
            guard let self else { return }
            await self.composeNotes(for: id, item: item, segments: segments)
        }
        notesWork = work
        await work.value
    }

    /// The writing itself: every request to the language model for one meeting's notes, then the save.
    /// Stopped part-way (`stopNotes`), nothing is saved and nothing is reported as an error.
    private func composeNotes(for id: Int64, item: SavedItem, segments: [TranscriptSegment]) async {
        var item = item
        do {
            // TESTING (`notesHold=20`): stands still first, so a test can press Stop without the model.
            if let hold = RecordTestHooks.value("notesHold").flatMap(Double.init) { try await Task.sleep(for: .seconds(hold)) }
            try await models.ensure(.language)
            var prompts = try Prompts(engine: app.engine)
            // What the recording was given (calendar, documents, screens) tells the notes how names are spelled.
            // The documents themselves stay out of the notes.
            // `attach=excerpt` in a test copy also hands the model a
            // short excerpt of the attached files; `attach=off` keeps even their names from it.
            let attachMode = Self.attachDefault
            let known = Set(prompts.terms.map { $0.lowercased() })
            prompts.terms += RecordingContext(json: item.context).names(fromAttachments: attachMode != "off").filter { !known.contains($0.lowercased()) }
            notesReference = attachMode == "excerpt" ? RecordingContext(json: item.context).attachmentExcerpt() : nil
            defer { notesReference = nil }
            // Always the same three sections: a summary, the key points and the decisions. Templates are
            // gone, and there is no list of action items: what people said they would do goes among the
            // key points (below).
            let solo = false
            let sections = Prompts.usualSections

            // One part of the transcript at a time: each part's notes are written under the template's own
            // headings, and the parts' notes are put together in code, in order. (The model is not asked to
            // combine them: it copied the first part's points until it ran out of room, so the end of a long
            // recording never reached the notes.)
            let started = Date()
            var tally = NotesTally()
            let script = MeetingText.script(segments)
            let parts = MeetingText.transcriptParts(script)
            // Who took on what comes from who said it, by rule (below): the model is never asked.
            let commitments = solo ? [] : MeetingText.commitments(in: segments)
            // In a long recording the decisions are worked out on their own, part by part (below), so they are not asked for here either.
            let decisionsApart = !solo && parts.count > 1 && sections.contains(where: Prompts.isDecisionSection)
            let asked = sections.filter { !(decisionsApart && Prompts.isDecisionSection($0)) }
            var partNotes: [[(title: String, bullets: [String])]] = []
            for part in parts {
                // The notes the user sent during it are theirs: they are shown beside the notes, never given to the model.
                partNotes += try await notes(
                    for: part, ofSeveral: parts.count > 1, userNotes: "", sections: asked.isEmpty ? sections : asked, solo: solo, prompts: prompts,
                    tally: &tally, depth: 0)
            }
            // A long recording gives each section a point or two from every part; a short one keeps what the model wrote.
            let pieces = partNotes.count
            func perPart(_ section: String) -> Int {
                if pieces <= 1 { return .max }
                let key = section.lowercased()
                // A voice note's to-dos are never thinned.
                if solo && section == "To do" { return .max }
                if key.contains("summary") || key.contains("context") || key.contains("background") { return pieces >= 4 ? 1 : 2 }
                return pieces >= 4 ? 2 : 4
            }
            let draft = MeetingText.mergedDraft(parts: partNotes, wanted: sections, perPart: perPart)
            // No part's points are dropped to fit: a long recording's sections may run past the usual twelve.
            let limit = max(12, pieces * 2)
            defer {
                Log.write(
                    "summary",
                    "\(solo ? "voice note" : "meeting") notes: \(script.count) characters in, \(parts.count) part\(parts.count == 1 ? "" : "s"), "
                        + "\(tally.steps) steps, tokens in \(tally.tokensIn), tokens out \(tally.tokensOut.map(String.init).joined(separator: "+")), "
                        + "hit the limit \(tally.capped), asked again \(tally.retried), \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
            var replacements: [String: [String]] = [:]
            if decisionsApart {
                // What each part settled or left open, asked two ways (one cautious, one that catches the
                // chair summing up); which of those are the meeting's decisions is chosen by rule, not by the model.
                // (Parts are not overlapped: measured on two meetings, a part that began with the
                // end of the one before brought in more wrong decisions than it saved.)
                var noted: [[MeetingText.DecisionNote]] = []
                for (i, part) in parts.enumerated() {
                    var found: [MeetingText.DecisionNote] = []
                    for request in [prompts.decisionNotesRequest(part: part), prompts.agreementRequest(part: part)] {
                        let run = try await notesStep(prompts.decisionSystem(), request, maxTokens: 300, tally: &tally)
                        found += MeetingText.decisionNotes(of: run.text, cut: run.hitCap)
                    }
                    noted.append(found)
                }
                let decided = MeetingText.decisions(parts: noted, tasks: commitments.map(\.task))
                for section in sections where Prompts.isDecisionSection(section) { replacements[section] = decided }
            }
            // What people said they would do, as ordinary points. Who took each on comes from who said it,
            // by rule. The model only tidies the wording.
            var tasks: [String] = []
            // Every task that was said is listed, however long the recording.
            for commitment in commitments {
                // Tasks that stand on their own are kept word for word; the model is only asked to say what "it" was.
                // A wording that ran into its limit is not used: the task stays as it was said.
                let run = !MeetingText.needsContext(commitment.task) ? nil : try? await notesStep(
                    prompts.taskWordingInstructions(), "CONTEXT: \(commitment.context)\nTASK: \(commitment.task)", maxTokens: 40, tally: &tally)
                let worded = run?.hitCap == false ? run?.text : nil
                let line = (worded?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -•*\"'."))
                let usable = line.count >= 4 && line.count <= 140 && !line.contains(":")
                tasks.append(commitment.point(task: usable ? line.prefix(1).lowercased() + line.dropFirst() : nil))
            }
            // They go at the end of the key points (or the nearest thing the template has to them).
            var additions: [String: [String]] = [:]
            if !tasks.isEmpty, let home = Prompts.sectionForCommitments(sections), replacements[home] == nil { additions[home] = tasks }
            let speakers = Array(Set(segments.map(\.speaker)))
            // The model's own lines about who will do what are dropped: it names the wrong person too often.
            let checked = MeetingText.withoutOwnershipClaims(draft, speakers: speakers, taskSection: { _ in false })
            let summary = MeetingText.assembleNotes(wanted: sections, draft: checked, replacements: replacements, additions: additions, limit: limit)
            // Re-read in case the user edited the meeting while notes were being written. If they deleted
            // it, saving would bring it back: stop here.
            guard let fresh = try? library.item(id) else { return }
            // Stopped while the last words were being put together: nothing is saved.
            try Task.checkCancellation()
            item = fresh
            item.summary = summary
            try library.save(item)
            version += 1
        } catch is CancellationError {
            // Stopped by the user. The meeting keeps its transcript, and the notes it had, if any.
            version += 1
        } catch {
            if Task.isCancelled {
                version += 1
            } else {
                app.report(error, doing: "write the notes")
            }
        }
    }

    /// What writing one recording's notes cost, for the log. Never the words themselves.
    private struct NotesTally {
        var steps = 0
        var tokensIn = 0
        var tokensOut: [Int] = []
        var capped = 0
        var retried = 0
    }

    /// One request to the language model while writing notes, counted.
    private func notesStep(_ instructions: String, _ text: String, maxTokens: Int, tally: inout NotesTally) async throws -> LanguageModel.Counted {
        let run = try await models.language.runCounted(instructions: instructions, text: text, maxTokens: maxTokens, temperature: 0)
        tally.steps += 1
        tally.tokensIn += run.promptTokens
        tally.tokensOut.append(run.outputTokens)
        if run.hitCap { tally.capped += 1 }
        return run
    }

    /// The notes for one part of a transcript, under the template's headings. An answer that ran into its
    /// limit has lost its later sections, so the part is written again as two halves (twice at most); what
    /// is still cut then keeps its finished lines.
    private func notes(
        for part: String, ofSeveral: Bool, userNotes: String, sections: [String], solo: Bool, prompts: Prompts, tally: inout NotesTally, depth: Int
    ) async throws -> [[(title: String, bullets: [String])]] {
        let instructions = solo
            ? prompts.voiceNoteInstructions(part: ofSeveral)
            : prompts.meetingNotesInstructions(sections: sections, partLimit: ofSeveral ? 3 : nil, reference: notesReference != nil)
        let run = try await notesStep(
            instructions, MeetingText.notesMaterial(userNotes: userNotes, points: [part], transcript: true, reference: solo ? nil : notesReference),
            maxTokens: 900, tally: &tally)
        if run.hitCap, depth < 2 {
            let halves = TextChunker.chunks(part, maxCharacters: part.count / 2 + 200)
            if halves.count > 1 {
                tally.retried += 1
                var out: [[(title: String, bullets: [String])]] = []
                for half in halves {
                    out += try await notes(for: half, ofSeveral: true, userNotes: userNotes, sections: sections, solo: solo, prompts: prompts, tally: &tally, depth: depth + 1)
                }
                return out
            }
        }
        return [MeetingText.partSections(of: run.text, cut: run.hitCap)]
    }

    /// Replaces the date-only title with a few words on what the meeting was about.
    private func nameMeeting(_ id: Int64) async {
        guard var item = try? library.item(id), !item.summary.isEmpty, let prompts = try? Prompts(engine: app.engine),
            (try? await models.ensure(.language)) != nil,
            let run = try? await models.language.runCounted(
                instructions: prompts.meetingTitleInstructions(), text: item.summary, maxTokens: 20, temperature: 0),
            // A title that ran into its limit is half a title: the date stays instead.
            !run.hitCap
        else { return }
        let out = run.text
        let name = (out.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.#*"))
        guard name.count >= 6, name.count <= 60, name.contains(" ") else { return }
        item.title = name
        _ = try? library.save(item)
        version += 1
    }

    /// Gives a longer voice note a few words on what it is about, in place of its opening words. It takes
    /// its turn like any other job; if it cannot be done the opening words stay.
    private func nameNote(_ id: Int64) async {
        let job = Jobs.shared.add("a note’s title", itemID: nil)
        defer { Jobs.shared.done(job) }
        guard await Jobs.shared.turn(job), var item = try? library.item(id), let prompts = try? Prompts(engine: app.engine) else { return }
        let was = item.title
        models.beginUse(.language)
        defer { models.endUse(.language) }
        guard (try? await models.ensure(.language)) != nil,
            let run = try? await models.language.runCounted(
                instructions: prompts.meetingTitleInstructions(), text: String(item.body.prefix(2400)), maxTokens: 20, temperature: 0),
            !run.hitCap
        else { return }
        let name = (run.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.#*"))
        // Renamed by hand meanwhile, or deleted: left alone.
        guard name.count >= 6, name.count <= 60, name.contains(" "), let fresh = try? library.item(id), fresh.title == was else { return }
        item = fresh
        item.title = name
        _ = try? library.save(item)
        version += 1
        Log.write("record", "a voice note was given a title")
    }

    // MARK: Library helpers used by the page

    /// Writes notes and a title for a recording that came from somewhere else (an audio file), the same as one made here.
    func describe(_ id: Int64) async {
        guard let item = try? library.item(id) else { return }
        let segments = (try? library.segments(itemID: id)) ?? []
        // Only a meeting has notes. A transcribed link or file is a document, and a voice note is its own words.
        guard !segments.isEmpty, item.kind == .meeting else { return }
        await writeNotes(for: id)
        // An import keeps the name it came with (the file's, or the page's or episode's): only a recording
        // with no title is given one.
        if item.title.isEmpty { await nameMeeting(id) }
    }

    /// What importing an audio file made of it.
    struct Imported {
        var id: Int64
        var kind: ItemKind
        var lines: Int
    }

    /// Turns an audio file into a recording like one made here: transcribed in pieces, each line with its
    /// time, and the people in it told apart when there is more than one voice. Returns nil when nothing
    /// was said in it. `step` is told what is being done, for whoever shows progress.
    ///
    /// The file is cut where dictation cuts a long recording (`LongForm`: at pauses, pieces of about 25
    /// seconds), short enough for the speech model to stay accurate. Speakers are given word by word.
    /// `title` and `source` are given for sound fetched from a link: the page's or episode's title, and
    /// the link, which is kept as where the recording came from in place of the temporary file.
    ///
    /// The sound is kept as a recording's is (one compressed file, about 15 MB an hour) when recordings
    /// keep theirs, so a line can be played. `stopped` is asked between steps: when it says yes the import
    /// ends with `CancellationError` and leaves nothing behind.
    func importAudio(
        _ url: URL, title: String? = nil, source: String? = nil, stopped: @MainActor () -> Bool = { false },
        step: @MainActor (String) -> Void = { _ in }
    ) async throws -> Imported? {
        let began = Date()
        try await models.ensure(.transcription)
        await models.transcriber.hold()
        var held = true
        defer { if held { Task { [models] in await models.transcriber.release() } } }
        let said: (words: [SaidWord], lines: [TranscriptSegment], duration: Double, pieces: Int, audio: String?)
        do {
            said = try await transcribeInPieces(url, stopped: stopped, step: step)
        } catch {
            // Stopped part way: the piece with the model was cut short, which reads as a failure of the engine.
            throw stopped() ? CancellationError() : error
        }
        held = false
        await models.transcriber.release()
        // The kept sound goes if the import does not end in a saved recording.
        var saved = false
        defer { if !saved, let audio = said.audio { try? FileManager.default.removeItem(at: ChirpStore.audioDirectory.appendingPathComponent(audio)) } }
        guard !said.words.isEmpty || !said.lines.isEmpty else { return nil }
        let transcribed = Date()

        // Who spoke when. The speaker step reads the file itself, a part at a time, so the sound is not
        // held in memory for it. Not while a recording is being finished: that is using the speaker model.
        var turns: [SpeakerTurn] = []
        if said.duration > 15, phase != .finishing("Working out who spoke") {
            step("Working out who spoke")
            if (try? await models.ensure(.speakers)) != nil {
                if let found = try? await speakers.turns(inFile: url) {
                    turns = found
                } else if let samples = try? AudioFile.samples(from: url), let found = try? await speakers.turns(in: samples) {
                    turns = found
                }
                turns = MeetingText.significant(turns)
            }
            await models.unload(.speakers)
        }
        if stopped() { throw CancellationError() }
        // Someone else's words, transcribed from a link or a file, are a document: nobody in it is "Me", the voices are numbered in the order they are heard, the
        // transcript is its text, and no notes are written about it.
        var segments = MeetingText.lines(from: said.words, turns: turns, label: "Speaker 1")
        // Pieces that came back without a time for each word are lines of their own.
        segments += MeetingText.assignSpeakers(said.lines, turns: turns, replacing: "Speaker 1")
        segments.sort { $0.start < $1.start }
        if let entries = try? app.engine.dictionary(), !entries.isEmpty {
            let corrector = DictionaryCorrector(entries: entries)
            for i in segments.indices { segments[i].text = corrector.correct(segments[i].text) }
        }
        let kind = ItemKind.document
        let voices = Set(segments.map(\.speaker)).count
        let read = MeetingText.merged(segments)
        let body = voices > 1 ? read.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n") : read.map(\.text).joined(separator: "\n\n")
        let item = try library.save(
            SavedItem(
                kind: kind, title: title ?? url.deletingPathExtension().lastPathComponent, body: body, audioFile: said.audio,
                duration: said.duration, source: source ?? url.path))
        guard let id = item.id else { return nil }
        saved = true
        try library.replaceSegments(itemID: id, with: segments)
        lastSavedID = id
        version += 1
        app.libraryVersion += 1
        Log.write(
            "record",
            String(
                format: "imported %.0f s of audio as a document: %d lines, %d speakers, %d pieces, transcribed in %.1f s, speakers in %.1f s",
                said.duration, segments.count, voices, said.pieces,
                transcribed.timeIntervalSince(began), Date().timeIntervalSince(transcribed)))
        return Imported(id: id, kind: kind, lines: segments.count)
    }

    /// The words of an audio file with their times, transcribed a piece at a time. The sound is let go of
    /// when this returns.
    private func transcribeInPieces(_ url: URL, stopped: @MainActor () -> Bool, step: @MainActor (String) -> Void) async throws
        -> (words: [SaidWord], lines: [TranscriptSegment], duration: Double, pieces: Int, audio: String?)
    {
        let samples = try await Task.detached { try AudioFile.samples(from: url) }.value
        let rate = Double(Transcriber.sampleRate)
        let plan = LongForm(targetSeconds: 25)
        let speech = await models.transcriber.speechSegments(samples)
        let cuts = samples.count > plan.maxSamples ? plan.cuts(LongForm.candidates(speech: speech ?? [], samples: samples.count), samples: samples.count) : []
        var words: [SaidWord] = []
        var lines: [TranscriptSegment] = []
        var from = 0
        var done = 0
        let ends = cuts + [samples.count]
        for to in ends where to > from {
            defer { from = to }
            if stopped() { throw CancellationError() }
            done += 1
            if ends.count > 1 { step("Transcribing · part \(done) of \(ends.count)") }
            // A piece with no speech in it is not sent to the model.
            if let speech, !speech.contains(where: { $0.lowerBound < to && $0.upperBound > from }) { continue }
            let transcript = try await models.transcriber.transcribe(Array(samples[from..<to]))
            guard !transcript.text.isEmpty else { continue }
            let offset = Double(from) / rate
            // The words are used when, put together, they are the text; otherwise the piece is one line.
            let letters = { (text: String) in text.filter { !$0.isWhitespace } }
            if !transcript.words.isEmpty, letters(transcript.words.map(\.text).joined()) == letters(transcript.text) {
                words += transcript.words.map { SaidWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            } else {
                lines.append(TranscriptSegment(itemID: 0, speaker: "Speaker 1", start: offset, end: Double(to) / rate, text: transcript.text))
            }
        }
        if stopped() { throw CancellationError() }
        // The sound itself, compressed as a recording's is, so its lines can be played. The times of the
        // lines are times in this file: it is written from the same samples they were worked out on.
        var audio: String?
        if keepAudio, !(words.isEmpty && lines.isEmpty) {
            let name = "import-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).m4a"
            let target = ChirpStore.audioDirectory.appendingPathComponent(name)
            if await Task.detached(operation: { (try? AudioFile.write(samples, to: target)) != nil }).value { audio = name }
        }
        return (words, lines, Double(samples.count) / rate, ends.count, audio)
    }

    /// Voice notes saved before recordings were one kind of thing held their words in the body. They get a
    /// transcript line and a title like any other recording; the words are not changed.
    private func adoptOldVoiceNotes() {
        for var item in (try? library.items(kinds: [.voiceNote])) ?? [] {
            guard let id = item.id, !item.body.isEmpty, ((try? library.segments(itemID: id)) ?? []).isEmpty else { continue }
            let line = TranscriptSegment(itemID: id, speaker: "Me", start: 0, end: max(item.duration, 1), text: item.body)
            guard (try? library.replaceSegments(itemID: id, with: [line])) != nil else { continue }
            if item.rawText.isEmpty { item.rawText = item.body }
            if item.title.isEmpty { item.title = MeetingText.openingTitle([line]) }
            item.body = ""
            _ = try? library.save(item)
        }
    }

    /// Saves a change the user made to a recording and tells the pages to reload.
    func update(_ item: SavedItem) {
        _ = try? library.save(item)
        version += 1
    }

    /// Removes a recording with its audio and the pictures of the screen kept for it.
    func delete(_ item: SavedItem) {
        // The pictures of the screen and the attached files go with it.
        Self.removeScreenPictures(of: RecordingContext(json: item.context))
        Self.removeAttachments(of: RecordingContext(json: item.context))
        try? library.delete(item)
        version += 1
    }

    /// Gives a speaker a real name on every line of one recording.
    func renameSpeaker(itemID: Int64, from old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        try? library.renameSpeaker(itemID: itemID, from: old, to: name)
        version += 1
    }
}
