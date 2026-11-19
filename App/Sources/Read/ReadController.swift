import AVFoundation
import AppKit
import ChirpCore
import ChirpML
import KeyboardShortcuts
import Observation
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Reads the selected text (or the field or page in front) aloud from any app; pressed again, it stops.
    /// Right Option and L, for Listen (see `ShortcutLayout`).
    static let readSelection = Self("readSelection", default: .init(.l, modifiers: [.option]))
}

/// Reads documents aloud, sentence by sentence, and tracks which word is being spoken.
@MainActor
@Observable
final class ReadController {
    /// The document open in the reader. It has no id while it is text being read once and not kept.
    private(set) var item: SavedItem?
    /// The open document's text, split into sentences. Reading and the saved place both go by sentence.
    private(set) var sentences: [ReadingSentence] = []
    /// Sentence numbers grouped into paragraphs, worked out once when the document is opened.
    private(set) var paragraphs: [ClosedRange<Int>] = []
    /// The sentence being read (or about to be).
    private(set) var index = 0
    /// True while reading is under way and not paused, including while the next sentence is being prepared.
    private(set) var isPlaying = false
    /// True while the voice is preparing the next sentence.
    private(set) var isPreparing = false
    /// The word being spoken, as a range in the document text.
    private(set) var wordRange: NSRange?
    /// "Say it as", while it is open: the words offered, the one picked and how it should sound.
    private(set) var sayItAs: SayItAsOffer?
    /// Tells the perch when "Say it as" opens on it or closes, so it can take the keyboard and give it back.
    @ObservationIgnored var onSayItAs: ((Bool) -> Void)?
    /// Plays the preview of a pronunciation, apart from the reading.
    @ObservationIgnored private let previewer: SentencePlayer =
        ProcessInfo.processInfo.arguments.contains("--ui-testing") && !DevicePlayer.muted ? SilentPlayer() : DevicePlayer()
    /// For tests: previews made, and what the voice was last given to say for a sentence.
    @ObservationIgnored private var previews = 0
    @ObservationIgnored private var lastSaid = ""
    /// Goes up whenever a document is added, removed or changed, so lists of documents know to reload.
    private(set) var version = 0

    /// How fast to read, as a multiple of normal speed. Kept between launches.
    var speed: Double {
        didSet {
            try? app.engine.setSetting("readSpeed", speed)
            if Self.voiceSpeed(for: oldValue) != voiceSpeed {
                // The voice itself changes pace above 2×, so sentences made at the old pace are no use.
                dropPrepared()
                if isPlaying { return restart(at: index) }
                // Paused: stay paused. The next play makes the sentence again at the new pace.
                if playTask != nil { dropPausedSentence() }
            }
            player.rate = playbackRate
        }
    }
    /// Up to 2× is done by playing faster. Beyond that the voice speaks faster as well.
    private static func voiceSpeed(for speed: Double) -> Float { speed > 2 ? Float(speed / 2) : 1 }
    private var voiceSpeed: Float { Self.voiceSpeed(for: speed) }
    private var playbackRate: Double { min(speed, 2) }
    /// The speeds offered in the speed menu.
    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0]

    /// Leaves out text in round and square brackets when reading aloud.
    var skipBrackets: Bool {
        didSet {
            try? app.engine.setSetting("readSkipBrackets", skipBrackets)
            dropPrepared()
        }
    }

    /// Leaves out marks that point at a source ("[12]", "(Smith, 2020)", raised note numbers) when
    /// reading aloud. On unless it has been switched off.
    var skipCitations: Bool {
        didSet {
            try? app.engine.setSetting("readSkipCitations", skipCitations)
            dropPrepared()
        }
    }

    // Saving as audio
    /// How far saving the document as audio has got, from 0 to 1. Nil when nothing is being saved.
    private(set) var exportProgress: Double?
    private var exportTask: Task<Void, Never>?
    // Summary
    /// True while a summary of the open document is being written.
    private(set) var summarizing = false {
        didSet {
            if !summarizing {
                summaryProgress = nil
                summaryDraft = nil
            }
        }
    }
    /// The summary as it fills in: each finished section in reading order. Nil when none is being
    /// written. Only for showing: Copy and Keep take the finished summary.
    private(set) var summaryDraft: String?
    /// Which part of a long summary is being written, so the wait can be read ("Part 2 of 5"). Nil for
    /// a summary of one part, and when none is being written.
    private(set) var summaryProgress: (part: Int, of: Int)?
    /// True while the Library shows the open document's original and not its reading view.
    var showOriginal = false
    /// Counts requests (from a test link) to show the open document's summary.
    private(set) var showSummaryRequests = 0
    /// The voice that reads. Kept between launches; changing it mid-sentence starts the sentence again
    /// (at once while reading, on the next play while paused).
    var voiceID: String {
        didSet {
            try? app.engine.setSetting("readVoice", voiceID)
            dropPrepared()
            if isPlaying { restart(at: index) } else if playTask != nil { dropPausedSentence() }
        }
    }

    private let app: AppModel
    private let models: ModelCenter
    let library: Library
    private let voice = Voice()
    /// Marks the sentence and word being read in the app the text came from.
    private let highlighter = ReadHighlighter()
    /// The sentence last handed to the highlighter, so it is only looked for once. -1 when none has been.
    private var highlightedIndex = -1
    /// Automated runs keep time without the audio hardware, unless asked to use it with the volume at zero.
    private let player: SentencePlayer =
        ProcessInfo.processInfo.arguments.contains("--ui-testing") && !DevicePlayer.muted ? SilentPlayer() : DevicePlayer()
    /// Audio already made, by sentence number, so the next sentence starts without a wait.
    private var cache: [Int: SpokenSentence] = [:]
    /// Goes up whenever prepared audio stops being right (another document, voice, pace or what to
    /// skip), so audio still being made for the old state is not kept for the new one.
    private var generation = 0
    /// Listening time left from the start of each sentence to the end, in seconds at normal speed.
    /// Worked out once when a document is opened, so the time left is a look-up.
    private var secondsFrom: [Double] = []
    /// True while the text to read is being fetched from the app in front, so a second press of the
    /// shortcut does not fetch it twice.
    private var gathering = false
    /// The loop that reads sentence after sentence. It stays alive through a pause and is nil when stopped.
    private var playTask: Task<Void, Never>?
    /// Sentences whose audio is being made right now, so the same sentence is never made twice at once.
    private var pending: [Int: Task<SpokenSentence, Error>] = [:]
    /// Makes the audio for the next few sentences while the current one plays.
    private var prefetcher: Task<Void, Never>?
    /// Checks the playback position many times a second to move the word highlight.
    private var ticker: Task<Void, Never>?
    /// When each word of the sentence now playing is spoken.
    private var timings: [SpokenWord] = []
    /// How the voice should say the user's dictionary words, by term. Read when a document is opened.
    private var pronunciations: [String: String] = [:]
    /// The small floating player shown while reading, when the perch is not there to show the controls.
    /// Asks the Mac not to slow Chirp down while it reads or saves audio.
    private let fullSpeed = FullSpeed()
    // Diagnostics for tests.
    private var lastSynthSeconds = 0.0
    private var lastAudioSeconds = 0.0
    private var lastLevel: Float = 0
    private var roundTrip = ""
    /// What the reading loop is doing now. With debugging on, every change is added to a log file.
    private var stage = "" {
        didSet {
            guard LinkHandler.debugEnabled else { return }
            let line = "\(Date().timeIntervalSince1970) \(stage)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/chirp-read.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else { try? line.write(toFile: "/tmp/chirp-read.log", atomically: true, encoding: .utf8) }
        }
    }

    init(app: AppModel, models: ModelCenter) {
        self.app = app
        self.models = models
        library = Library(store: app.store)
        speed = (try? app.engine.setting("readSpeed", as: Double.self)) ?? 1.0
        voiceID = (try? app.engine.setting("readVoice", as: String.self)) ?? Voice.defaultID
        skipBrackets = (try? app.engine.setting("readSkipBrackets", as: Bool.self)) ?? false
        skipCitations = (try? app.engine.setting("readSkipCitations", as: Bool.self)) ?? true

        let voice = voice
        models.register(
            .voice, onDisk: { Voice.isDownloaded },
            load: { _ in
                try await voice.load()
                Log.write("read", "voice loaded in \(await voice.lastLoad)")
            },
            unload: { await voice.unload() })

        // On key down, so it starts the moment the shortcut is pressed, whether it is tapped or held.
        (player as? DevicePlayer)?.onOutputFailure = { [weak self] in
            guard let self else { return }
            self.dismiss()
            let message = "The Mac's sound output did not start. Check the output in System Settings › Sound."
            self.app.banner = message
            Toast.show(message, seconds: 6)
        }
        KeyboardShortcuts.onKeyDown(for: .readSelection) { [weak self] in
            Task { await self?.readSelection() }
        }
        Features.shared.whenChanged { [weak self] old, new in
            guard let self, old.isOn(.read), !new.isOn(.read) else { return }
            // Read aloud switched off while reading: it stops, and the marks come off the other app.
            // Text that was only open to be read once is put away, unless a summary still needs it.
            self.stop()
            self.highlighter.end()
            self.exportTask?.cancel()
            if self.isReadingSelection, !self.summarizing { self.close() }
        }
        Features.shared.probe("read.reading") { [weak self] in (self?.isPlaying ?? false) || self?.playTask != nil }
        registerDebug()
        registerSayItAsDebug()
        // "Say it as": what is offered and typed, previews made, and what the voice was last given to say.
        // `marks` is the marks in another app: sentences looked for and not found, words marked, left
        // unmarked and moved onto their word, and requests to the page to move.
        LinkHandler.stateProviders["sayItAs"] = { [weak self] in
            guard let self else { return [:] }
            var out: [String: Any] = ["open": self.sayItAs != nil, "previews": self.previews, "lastSaid": self.lastSaid, "pronunciations": self.pronunciations]
            if let offer = self.sayItAs {
                out["words"] = offer.words
                out["picked"] = offer.picked
                out["text"] = offer.text
                out["place"] = offer.place.rawValue
                out["problem"] = offer.problem ?? ""
                out["resume"] = offer.resume
            }
            let t = self.highlighter.tally
            out["marks"] = ["sentences": t.sentences, "notFound": t.notFound, "words": t.words, "unmarked": t.unmarked, "settled": t.settled, "requests": t.requests, "rejected": t.rejected]
            return out
        }
    }

    // MARK: Library

    /// The documents kept in the library, newest first.
    func documents() -> [SavedItem] { (try? library.items(kinds: [.document])) ?? [] }

    /// Keeps imported text in the library as a document. Returns nil (and reports why) if it cannot be saved.
    @discardableResult
    func add(_ imported: DocumentImporter.Imported) -> SavedItem? {
        do {
            let saved = try library.save(SavedItem(kind: .document, title: imported.title, body: imported.text, source: imported.source))
            // Its layout, its original and its pictures go into the library with it.
            DocumentImporter.keep(imported, as: saved, in: library)
            version += 1
            return saved
        } catch {
            if let made = imported.staging { try? FileManager.default.removeItem(at: made) }
            app.report(error, doing: "save the document")
            return nil
        }
    }

    /// Adds a file (PDF, EPUB, Word, text, web page) to the library and opens it in the reader.
    func importFile(_ url: URL) {
        do {
            if let saved = add(try DocumentImporter.importFile(url)) { open(saved) }
        } catch { app.report(error, doing: "open \(url.lastPathComponent)") }
    }

    /// Adds pasted text to the library and opens it in the reader.
    func importText(_ text: String) {
        do {
            if let saved = add(try DocumentImporter.importText(text)) { open(saved) }
        } catch { app.report(error, doing: "read that text") }
    }

    /// Loads the article at a web address the user typed, adds it to the library and opens it.
    func importWebPage(_ address: String) async {
        do {
            if let saved = add(try await DocumentImporter.importWebPage(address)) { open(saved) }
        } catch { app.report(error, doing: "read that page") }
    }

    /// Removes a document from the library, closing it first if it is the one open.
    func delete(_ doc: SavedItem) {
        if doc.id == item?.id { close() }
        try? library.delete(doc)
        version += 1
    }

    // MARK: Opening

    /// Opens a document in the reader at the place it was left. Does nothing if it is already open.
    func open(_ doc: SavedItem) {
        guard item == nil || doc.id != item?.id else { return }
        load(doc)
    }

    /// Stops whatever was being read and makes `doc` the open document: splits it into sentences, finds
    /// the saved place and reads the dictionary's pronunciations.
    private func load(_ doc: SavedItem) {
        stop()
        // Marks left in another app belong to the text that was being read until now.
        highlighter.end()
        highlightedIndex = -1
        // The caller's copy may be older than what is saved (its place, above all): read it afresh.
        var doc = doc
        if let id = doc.id, let saved = try? library.item(id) { doc = saved }
        // Each document opens on its reading view.
        if doc.id != item?.id { showOriginal = false }
        item = doc
        sentences = ReadingText.sentences(doc.body)
        dropPrepared()
        // Paragraphs, and the listening time left from each sentence on.
        var groups: [ClosedRange<Int>] = []
        var first = 0
        for s in sentences where s.startsParagraph && s.index > first {
            groups.append(first...(s.index - 1))
            first = s.index
        }
        if !sentences.isEmpty { groups.append(first...(sentences.count - 1)) }
        paragraphs = groups
        var left = [Double](repeating: 0, count: sentences.count)
        var total = 0.0
        for i in sentences.indices.reversed() {
            total += ReadingText.estimatedDuration(sentences[i].text)
            left[i] = total
        }
        secondsFrom = left
        // Resume where the reader left off.
        index = sentences.lastIndex { $0.offset <= doc.position } ?? 0
        wordRange = nil
        pronunciations = Dictionary(
            ((try? app.engine.dictionary()) ?? []).compactMap { e in e.pronunciation.map { (e.term, $0) } },
            uniquingKeysWith: { a, _ in a })
    }

    /// True while reading text selected in another app. That text is read once and not kept in the library.
    var isReadingSelection: Bool { item != nil && item?.id == nil }

    /// Stops, and puts away text that was only being read once.
    func dismiss() {
        stop()
        if isReadingSelection { close() }
    }

    /// Stops reading, takes the marks off the other app and leaves the reader with no document open.
    func close() {
        stop()
        if sayItAs != nil { closeSayItAs(resume: false) }
        highlighter.end()
        highlightedIndex = -1
        item = nil
        sentences = []
        paragraphs = []
        secondsFrom = []
        dropPrepared()
        index = 0
    }

    /// Lets go of audio already made or being made, because it no longer matches what should be read.
    private func dropPrepared() {
        generation += 1
        cache.removeAll()
        cancelPending { _ in true }
        pending.removeAll()
    }

    /// Stops the sentences being made that `unwanted` picks out, so the voice is free for the sentence
    /// that is wanted now. The voice checks between each of its seven stages whether it has been told to
    /// stop (FluidAudio's `KokoroAneSynthesizer`); without this a sentence nobody is waiting for was
    /// always made to the end first.
    private func cancelPending(_ unwanted: (Int) -> Bool) {
        for (i, task) in pending where unwanted(i) {
            task.cancel()
            pending[i] = nil
        }
    }

    /// While paused: lets go of the half-read sentence and the reading loop without touching the place,
    /// so the next play starts the sentence afresh. Reading stays paused.
    private func dropPausedSentence() {
        prefetcher?.cancel()
        playTask?.cancel()
        playTask = nil
        player.stop()
        isPreparing = false
        wordRange = nil
    }

    // MARK: Playback

    func toggle() { isPlaying ? pause() : play() }

    /// Starts reading from the current sentence, or carries on from a pause in the middle of one.
    func play() {
        guard Features.on(.read), item != nil, !sentences.isEmpty else { return }
        if index >= sentences.count { index = 0 }
        if playTask != nil {
            // Resume from a pause (which may have landed while the next sentence was being prepared).
            if player.hasSentence, !player.isPlaying { player.resume() }
            isPlaying = true
            app.mood = .speaking
            fullSpeed.begin("Reading aloud")
            startTicker()
            return
        }
        restart(at: index)
    }

    /// Holds the audio where it is and saves the place. The reading loop stays alive so play can carry on.
    func pause() {
        player.pause()
        isPlaying = false
        ticker?.cancel()
        app.mood = .idle
        savePosition()
    }

    /// Ends reading altogether: the audio, the reading loop and the floating player. The document stays
    /// open and its place is saved.
    func stop() {
        prefetcher?.cancel()
        playTask?.cancel()
        playTask = nil
        ticker?.cancel()
        // Stopping the sentence also releases the reading loop that is waiting for it to finish.
        player.stop()
        cancelPending { _ in true }
        isPlaying = false
        isPreparing = false
        wordRange = nil
        fullSpeed.end()
        if app.mood == .speaking { app.mood = .idle }
        savePosition()
    }

    /// Moves to another sentence. Reading carries on from there if it was under way; otherwise only the
    /// place changes.
    func jump(to newIndex: Int) {
        guard sentences.indices.contains(newIndex) else { return }
        if isPlaying || playTask != nil {
            restart(at: newIndex)
        } else {
            index = newIndex
            wordRange = nil
            savePosition()
        }
    }

    /// Moves forward or back by `delta` sentences, stopping at the first and last.
    func skip(_ delta: Int) { jump(to: max(0, min(sentences.count - 1, index + delta))) }

    /// Cuts off the sentence being read and starts a fresh reading loop at sentence `start`.
    private func restart(at start: Int) {
        playTask?.cancel()
        player.stop()
        // Keep only the audio that is about to be needed; jumping about must not pile sentences up.
        cache = cache.filter { (start...(start + 3)).contains($0.key) }
        // The sentences being got ready ahead belong to where reading was, not to where it is going.
        prefetcher?.cancel()
        cancelPending { !(start...(start + 3)).contains($0) }
        if LinkHandler.debugEnabled { Log.write("read", "start at sentence \(start)") }
        index = start
        isPlaying = true
        app.mood = .speaking
        fullSpeed.begin("Reading aloud")
        playTask = Task { [weak self] in
            await self?.run(from: start)
        }
    }

    /// The reading loop: loads the voice, then makes and plays one sentence after another until the end
    /// of the document, or until it is cancelled by a stop, a skip or a new document.
    private func run(from start: Int) async {
        do {
            isPreparing = true
            stage = "loading voice"
            try await models.ensure(.voice)
            var i = start
            while i < sentences.count, !Task.isCancelled {
                // Asked for before every sentence, not once: it tells the model keeper the voice is still
                // in use (so it is not put away during a long read) and loads it again if it was put
                // away to make room for another model. It returns at once when the voice is loaded.
                if models.state(.voice) != .loaded { isPreparing = true }
                try await models.ensure(.voice)
                guard !Task.isCancelled else { return }
                stage = "synthesizing \(i)"
                let spoken = try await synthesize(i)
                stage = "playing \(i)"
                guard !Task.isCancelled else { return }
                prefetch(after: i)
                // Paused while this sentence was being prepared: wait here until play is pressed.
                while !isPlaying, !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled else { return }
                index = i
                isPreparing = false
                timings = Self.wordTimings(sentence: sentences[i].text, spoken: spoken)
                await play(spoken, pause: ReadingText.pause(after: i, in: sentences))
                guard !Task.isCancelled else { return }
                cache[i - 1] = nil
                i += 1
            }
            if !Task.isCancelled {
                // Reached the end.
                index = 0
                isPlaying = false
                wordRange = nil
                playTask = nil
                ticker?.cancel()
                if exportProgress == nil { fullSpeed.end() }
                app.mood = .idle
                savePosition()
                Log.write("read", "reached the end")
                if isReadingSelection { close() }
            }
        } catch is CancellationError {
        } catch {
            // A loop that was already replaced (a skip, a new document) must not stop the one that took over.
            guard !Task.isCancelled else { return }
            isPlaying = false
            isPreparing = false
            playTask = nil
            ticker?.cancel()
            if exportProgress == nil { fullSpeed.end() }
            app.mood = .idle
            Log.write("read", "failed: \(error.localizedDescription)")
            app.report(error, doing: "read aloud")
            Toast.show("Could not read aloud: \(error.localizedDescription)")
        }
    }

    /// When each word of a sentence is spoken: from the voice's own times for its words where they can
    /// be lined up with the words shown, otherwise shared out over the length of the audio.
    static func wordTimings(sentence: String, spoken: SpokenSentence) -> [SpokenWord] {
        if let spans = spoken.wordSpans, let text = spoken.spokenText,
            let timed = WordTiming.wordTimings(sentence: sentence, spokenText: text, spans: spans)
        {
            return timed
        }
        return ReadingText.wordTimings(sentence: sentence, spokenWeights: spoken.wordWeights, duration: spoken.duration)
    }

    /// The audio for sentence `i`: from the cache, from a synthesis already under way, or freshly made.
    private func synthesize(_ i: Int) async throws -> SpokenSentence {
        if let cached = cache[i] { return cached }
        if let running = pending[i] { return try await running.value }
        // A sentence with nothing sayable (only a citation, say) becomes a short pause.
        guard let text = sayable(sentences[i].text) else {
            let silence = SpokenSentence(samples: [Float](repeating: 0, count: 4800), sampleRate: 24_000, wordWeights: [])
            cache[i] = silence
            return silence
        }
        lastSaid = text
        let made = generation
        let voiceID = voiceID
        let pace = voiceSpeed
        let task = Task { [voice] in try await voice.speak(text, voice: voiceID, speed: pace) }
        pending[i] = task
        // Only clear the entry if it is still this one (a new document, or a skip away and back, may
        // have put its own there).
        defer { if pending[i] == task { pending[i] = nil } }
        let spoken = try await task.value
        lastSynthSeconds = (spoken.timing?.wallMs ?? 0) / 1000
        lastAudioSeconds = spoken.duration
        // Where the time went (the text work, then each stage of the voice model), so a slow first
        // sentence can be told apart from a slow model.
        Log.write("read", String(format: "sentence %d: %.1f s of speech made in %.1f s", i, spoken.duration, lastSynthSeconds) + (spoken.timing.map { "; \($0.summary)" } ?? ""))
        lastLevel = PauseSegmenter.rms(spoken.samples[...])
        // The document, voice, pace or what to skip may have changed while this was being made.
        if generation == made { cache[i] = spoken }
        return spoken
    }

    /// What the voice is given to say for a sentence, or nil when nothing in it can be said (only a
    /// citation mark, say).
    private func sayable(_ sentence: String) -> String? {
        let text = ReadingText.spoken(sentence, pronunciations: pronunciations, skipBrackets: skipBrackets, skipCitations: skipCitations)
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : nil
    }

    /// Gets the next sentences ready while the current one plays, one after the other.
    private func prefetch(after i: Int) {
        prefetcher?.cancel()
        prefetcher = Task { [weak self] in
            for next in (i + 1)...(i + 3) {
                guard let self, !Task.isCancelled, next < self.sentences.count else { return }
                _ = try? await self.synthesize(next)
            }
        }
    }

    /// Plays one sentence and returns when it has finished (or was stopped).
    private func play(_ spoken: SpokenSentence, pause: Double) async {
        // A gap after each sentence, like a reader taking a breath: longer at the end of a paragraph.
        let samples = spoken.samples + [Float](repeating: 0, count: Int(pause * spoken.sampleRate))
        stage = "play: starting"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.play(samples, sampleRate: Int(spoken.sampleRate), rate: playbackRate) { continuation.resume() }
            startTicker()
        }
        stage = "play: finished"
    }

    /// Follows playback to highlight the word being spoken.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.isPlaying, self.player.hasSentence, self.sentences.indices.contains(self.index) else { continue }
                if self.highlighter.isActive, self.highlightedIndex != self.index {
                    self.highlightedIndex = self.index
                    self.highlighter.show(sentence: self.sentences[self.index].text, index: self.index)
                }
                if let w = ReadingText.wordIndex(at: self.player.currentTime, in: self.timings) {
                    let r = self.timings[w].range
                    let absolute = NSRange(location: self.sentences[self.index].offset + r.location, length: r.length)
                    if absolute != self.wordRange {
                        self.wordRange = absolute
                        // A sentence's text has no space at its start, so the word's place in it is its
                        // place in the sentence as found in the app.
                        if self.highlighter.isActive { self.highlighter.show(word: r) }
                    }
                }
            }
        }
    }

    /// Keeps the current sentence's place with the document, so it opens there next time. Text that is
    /// only being read once has no place to keep.
    private func savePosition() {
        guard var doc = item, doc.id != nil, sentences.indices.contains(index) else { return }
        doc.position = sentences[index].offset
        item = doc
        // Only the place is written: the copy held here may be older than what the Library has by now.
        if let id = doc.id { try? library.setPosition(id: id, position: doc.position) }
    }

    // MARK: Progress

    /// How far through the document the reading is, from 0 to 1, counted in sentences.
    var progress: Double { sentences.isEmpty ? 0 : Double(index) / Double(sentences.count) }

    /// A rough guess at the listening time left, in seconds, at the current speed.
    var timeLeft: Double {
        guard item != nil, secondsFrom.indices.contains(index) else { return 0 }
        return secondsFrom[index] / speed
    }

    // MARK: Save as audio

    /// Reads the whole document into an audio file, at normal speed in the current voice.
    func exportAudio(to url: URL) {
        guard let doc = item, exportProgress == nil else { return }
        pause()
        // Nil for a sentence with nothing to say, which is left out of the file.
        let lines: [String?] = sentences.map { sayable($0.text) }
        let voiceID = voiceID
        let pauses = sentences.indices.map { ReadingText.pause(after: $0, in: sentences) }
        exportProgress = 0
        fullSpeed.begin("Saving audio")
        Log.write("read", "saving audio: \(lines.count) sentences")
        exportTask = Task { [weak self, voice, models] in
            do {
                try await models.ensure(.voice)
                try? FileManager.default.removeItem(at: url)
                var writer: AudioFileWriter? = try AudioFileWriter(url: url, sampleRate: 24_000)
                for (i, line) in lines.enumerated() {
                    try Task.checkCancellation()
                    if let line {
                        // Before every sentence: keeps the voice from being put away during a long
                        // save, and loads it again if another model took its place.
                        try await models.ensure(.voice)
                        let spoken = try await voice.speak(line, voice: voiceID)
                        try writer?.append(spoken.samples + [Float](repeating: 0, count: Int(pauses[i] * 24_000)))
                    }
                    self?.exportProgress = Double(i + 1) / Double(lines.count)
                }
                writer = nil  // closes the file
                Log.write("read", "saved audio for a document")
                Toast.show("Saved the audio of “\(doc.title)”.")
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                // Half a file is no use: take it away (the writer has closed it by now).
                try? FileManager.default.removeItem(at: url)
                Log.write("read", "saving audio failed: \(error.localizedDescription)")
                self?.app.report(error, doing: "save the audio")
            }
            self?.exportProgress = nil
            // Reading may have been started again while the file was being saved.
            if self?.isPlaying != true { self?.fullSpeed.end() }
        }
    }

    /// Stops saving the audio. The half-written file is removed.
    func cancelExport() { exportTask?.cancel() }

    // MARK: Summary

    /// Writes a short summary of the open document and keeps it with the document.
    func summarize() async {
        guard Features.on(.summarize), let doc = item, !summarizing else { return }
        pause()
        summarizing = true
        // The language model is called once for every part; it must not be put away part-way to make
        // room for the voice (the summary then stopped with nothing written). Meeting notes do the same.
        models.beginUse(.language)
        defer {
            models.endUse(.language)
            summarizing = false
        }
        do {
            // The model is loaded before the first part it writes, not before the overview (the source's own sentences),
            // so the overview shows at once even when the model is not loaded yet.
            // All of the text, however long, from the screen or the Library: there is no cap.
            let summary = try await writeSummary(of: doc.body, prompts: try Prompts(engine: app.engine))
            // Writing it took a while, and the reader may have moved on meanwhile.
            if let id = doc.id {
                // A kept document: add the summary to what is saved now, so a newer place is not undone.
                var saved = (try? library.item(id)) ?? doc
                saved.summary = summary
                _ = try? library.save(saved)
                if item?.id == id { item?.summary = summary }
            } else if let open = item, open.body == doc.body {
                // Text that was only open for now, and still is. If it was kept in the library while
                // the summary was written, the summary is saved with it.
                item?.summary = summary
                if open.id != nil, let kept = item { _ = try? library.save(kept) }
            }
            version += 1
        } catch is FeatureSwitchedOff {
            // Summarize was switched off part-way: nothing is kept and nothing is reported.
        } catch is CancellationError {
            // Cancelled by the user: nothing is kept and nothing is reported.
        } catch {
            // The language model's helper was ended because it would not stop: to the user that is the cancel.
            if Task.isCancelled { return }
            app.report(error, doing: "summarize this document")
        }
    }

    /// What one step of a summary cost, for the log. Never the words themselves.
    private struct SummaryTally {
        var steps = 0
        var tokensIn = 0
        var tokensOut: [Int] = []
        var capped = 0
        var retried = 0
        var standIns = 0
        var peakMegabytes = 0
        /// Model points checked against the source, replaced by a source sentence, and left out.
        var points = 0
        var replaced = 0
        var dropped = 0
        /// The sentence checker, when it is on: points scored and replaced, its time with loading, its peak memory.
        var checkerScored = 0
        var checkerReplaced = 0
        var checkerSeconds = 0.0
        var checkerPeak = 0
        var checkerRounds = 0
        /// Where the time went: prefill and generation as the library times them, each step's wall time with the pipe,
        /// and waiting for the model to load.
        var prefillSeconds = 0.0
        var generateSeconds = 0.0
        var stepSeconds = 0.0
        var loadSeconds = 0.0
    }

    /// Writes the summary of `text` in a fixed shape: ads and boilerplate taken out by
    /// rule; an overview of two to four of the source's own sentences (its lead, or its most central ones); then a few
    /// points on each of the document's own sections in order (a short section is its own first sentences, with no
    /// model step), each point checked against the section's sentences (`SourceCheck`), then by the sentence checker.
    /// See `SummaryPlan`. No step can drop a section or stop the summary half way, and all of the text is covered.
    ///
    /// It fills in as it goes: the overview at once, then each section in reading order as soon as it and every
    /// section before it are ready (`summaryDraft`). The parts are written a batch at a time in one pass of the model
    /// (`LanguageModel.runBatch`), and checked a round at a time before they are shown, the first round being one part so
    /// the first section is there while the overview is read, each later round as big again as the ones before it.
    private func writeSummary(of text: String, prompts: Prompts) async throws -> String {
        let started = Date()
        let plan = SummaryPlan.make(for: text)
        // Said before the work, so a summary that is cancelled or never ends still shows what it was given.
        Log.write("summary", "starting: \(plan.characters) characters, \(plan.parts.count) part\(plan.parts.count == 1 ? "" : "s"), \(plan.removed) characters of ads and boilerplate left out")
        var tally = SummaryTally()
        // No overview at the top: the source sentences it would be picked from read badly in every kind of
        // document. Every text goes to the model, a short one too; the summary is its checked points.
        let parts = plan.parts
        // Each part's finished, checked sections, by its place; and the model points still to go past the sentence checker.
        var finished = [[SummarySection]?](repeating: nil, count: parts.count)
        var unchecked: [Int: (source: String, points: [String])] = [:]
        // A summary that was cancelled can leave its held-back sections behind; they belong to another document.
        pendingSections = [:]
        var shown = 0
        let checker = ModelCenter.summaryCheckerDirectory
        // Without the checker this summary uses the rule check alone, and the checker downloads for the next one.
        if checker == nil { SummaryCheckerDownload.startIfNeeded() }
        let batch = ModelCenter.summaryBatch
        var drafted = -1
        func show() {
            // The sections that are ready, in order, up to the first that is not: never a later one before an earlier one.
            while shown < finished.count, finished[shown] != nil { shown += 1 }
            guard plan.sectioned, shown != drafted else { return }
            drafted = shown
            summaryDraft = SummaryNotes.compose(sentence: "", sections: Self.assemble(parts, finished, upTo: shown))
            Log.write("summary", String(format: "shown: %d of %d parts at %.1f s", shown, parts.count, Date().timeIntervalSince(started)))
        }
        show()
        // The model's parts, in order, in rounds: 1 part, then a batch, then as many again as all the rounds before (in
        // whole batches), so each round is written while the sections before it are read.
        let modelParts = parts.indices.filter { !parts[$0].extractive }
        var rounds: [[Int]] = []
        var at = 0
        while at < modelParts.count {
            let size = rounds.isEmpty ? 1 : rounds.count == 1 ? batch : max(batch, (at + batch - 1) / batch * batch)
            rounds.append(Array(modelParts[at ..< min(modelParts.count, at + size)]))
            at += size
        }
        if checker == nil { rounds = modelParts.isEmpty ? [] : [modelParts] }
        // Short sections are their own first sentences, at once.
        for (i, part) in parts.enumerated() where part.extractive { finished[i] = [SummaryNotes.extract(part.text, points: part.points)] }
        show()
        for round in rounds {
            // In batches, in order.
            var start = 0
            while start < round.count {
                let group = Array(round[start ..< min(round.count, start + batch)])
                start += group.count
                // Summarize switched off since the last part: the summary stops here. Cancelled between batches.
                guard Features.on(.summarize) else { throw FeatureSwitchedOff() }
                try Task.checkCancellation()
                summaryProgress = parts.count > 1 ? (group.last! + 1, parts.count) : nil
                // Before every model step: keeps the model from being put away during a long document, and loads it again
                // if another model (the checker) took its place.
                let loadBegan = Date()
                try await models.ensureSummaryModel()
                tally.loadSeconds += Date().timeIntervalSince(loadBegan)
                let written = try await summarize(parts: group.map { parts[$0] }, prompts: prompts, tally: &tally)
                for (k, i) in group.enumerated() {
                    // Every point the model wrote is read against the part's own sentences; one that changes a number, a name
                    // or a "not", "less", "cooler"… is replaced by the source's closest sentence, since the source's own words are safer than a wrong point.
                    let checked = SourceCheck.checked(written[k], source: parts[i].text)
                    tally.replaced += checked.replaced
                    tally.dropped += checked.dropped
                    tally.points += checked.sections.reduce(0) { $0 + $1.points.count } + checked.dropped
                    if !checked.kept.isEmpty, checker != nil { unchecked[i] = (parts[i].text, checked.kept) }
                    finished[i] = checked.sections
                    if unchecked[i] != nil { finished[i] = nil; pendingSections[i] = checked.sections }
                }
                show()
            }
            if let checker, !unchecked.isEmpty {
                try await check(&unchecked, into: &finished, directory: checker, tally: &tally)
                show()
            }
        }
        // Anything the checker could not take (another job had the model) stands with the rule check.
        for (i, sections) in pendingSections where finished.indices.contains(i) && finished[i] == nil { finished[i] = sections }
        pendingSections = [:]
        var sections = Self.assemble(parts, finished, upTo: finished.count)
        var overview = ""
        if !plan.sectioned {
            // A short text: the model's checked points, as a paragraph.
            overview = sections.flatMap(\.points).map { SummaryNotes.sentenceForm($0) }.joined(separator: " ")
            sections = []
        }
        let summary = SummaryNotes.compose(sentence: overview, sections: sections)
        Log.write(
            "summary",
            "\(plan.characters) characters in, \(plan.parts.count) part\(plan.parts.count == 1 ? "" : "s"), \(sections.count) section\(sections.count == 1 ? "" : "s"), "
                + "\(tally.steps) steps, batch \(batch), tokens in \(tally.tokensIn), tokens out \(tally.tokensOut.map(String.init).joined(separator: "+")), "
                + "hit the limit \(tally.capped), asked again \(tally.retried), stand-ins \(tally.standIns), "
                + "points checked \(tally.points), replaced by the source \(tally.replaced), left out \(tally.dropped), "
                + (tally.checkerSeconds > 0 ? String(format: "checker: %d scored, %d replaced, %.1f s in %d rounds, peak %d MB, ", tally.checkerScored, tally.checkerReplaced, tally.checkerSeconds, tally.checkerRounds, tally.checkerPeak) : "")
                + String(format: "time: prefill %.1f s, generate %.1f s, steps %.1f s, load %.1f s, ", tally.prefillSeconds, tally.generateSeconds, tally.stepSeconds, tally.loadSeconds)
                + "peak \(tally.peakMegabytes) MB, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        return summary
    }

    /// The answers of one batch as they arrive from the helper, by request.
    private final class BatchAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [LanguageModel.Counted?]
        init(count: Int) { answers = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ c: LanguageModel.Counted) { lock.withLock { answers[i] = c } }
        func get(_ i: Int) -> LanguageModel.Counted? { lock.withLock { answers[i] } }
    }

    /// Sections written and rule-checked, held back until the sentence checker has been over them, so nothing unchecked is shown.
    private var pendingSections: [Int: [SummarySection]] = [:]

    /// The summary's sections from the parts finished so far, up to `upTo`: a part with the original's heading is that
    /// section; a part that carries on a long section adds its points under the same heading.
    private static func assemble(_ parts: [SummaryPlan.Part], _ finished: [[SummarySection]?], upTo: Int) -> [SummarySection] {
        var sections: [SummarySection] = []
        for i in 0 ..< min(upTo, parts.count) {
            let part = parts[i]
            var found = finished[i] ?? []
            if let heading = part.heading {
                // The original's own heading.
                found = [SummarySection(heading: heading, points: found.flatMap(\.points), list: found.first?.list ?? part.list, code: part.code ?? found.first?.code, depth: part.depth)]
            }
            if part.continues, let last = sections.indices.last {
                // The rest of a long section: its points go on under the same heading.
                sections[last].points += found.flatMap(\.points)
            } else {
                sections += found.isEmpty ? [SummarySection(heading: part.heading ?? "", points: [], code: part.code, depth: part.depth)] : found
            }
        }
        return sections
    }

    /// One round of the sentence checker over the parts in `unchecked`: the language model is put away (one model at a
    /// time on this Mac), MiniCheck scores each kept point against its part's text in chunks of about 400 tokens, and a
    /// point under the line is replaced by its closest source sentence, as the rules do. The parts go into `finished`.
    /// When another job is using the language model it is not put away under it: those parts keep the rule check alone.
    private func check(_ unchecked: inout [Int: (source: String, points: [String])], into finished: inout [[SummarySection]?], directory: URL, tally: inout SummaryTally) async throws {
        let order = unchecked.keys.sorted()
        defer { unchecked = [:] }
        if models.useCount(.language) > 1 {
            Log.write("summary", "sentence checker skipped: the language model is in use by another job")
            for i in order { finished[i] = pendingSections.removeValue(forKey: i) ?? finished[i] }
            return
        }
        let began = Date()
        do {
            await models.unload(.language)
            let items = order.map { unchecked[$0]! }
            let groups = items.map { FactChecker.Group(chunks: SourceCheck.checkerChunks($0.source), claims: $0.points) }
            let result = try await FactChecker().scores(groups, directory: directory)
            var replacedHere = 0
            for (g, i) in order.enumerated() {
                var replacements: [String: [String]] = [:]
                for (k, point) in items[g].points.enumerated() where result.scores[g][k] < ModelCenter.summaryCheckerThreshold {
                    let verdict = SourceCheck.check(point, source: items[g].source)
                    replacements[point] = ([verdict.closest, verdict.also].compactMap { $0 }).map { SummarySentence.trimmed($0) }
                }
                replacedHere += replacements.count
                let sections = pendingSections.removeValue(forKey: i) ?? finished[i] ?? []
                finished[i] = sections.map { section in
                    var s = section
                    var points: [String] = []
                    for p in section.points {
                        if let with = replacements[p] { points += with.filter { !points.contains($0) } } else { points.append(p) }
                    }
                    s.points = points
                    return s
                }
            }
            tally.checkerScored += items.reduce(0) { $0 + $1.points.count }
            tally.checkerReplaced += replacedHere
            tally.checkerPeak = max(tally.checkerPeak, result.peakMegabytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The checker failing never costs the summary: the rule-checked points stand.
            Log.write("summary", "sentence checker failed (\(error.localizedDescription)); the rule check stands")
            for i in order { finished[i] = pendingSections.removeValue(forKey: i) ?? finished[i] }
        }
        tally.checkerRounds += 1
        tally.checkerSeconds += Date().timeIntervalSince(began)
        Log.write("summary", String(format: "checker round %d: %d parts, %.1f s", tally.checkerRounds, order.count, Date().timeIntervalSince(began)))
    }

    /// The sections for several parts, written together in one batch when there are several, else one at a time.
    /// A part whose answer has nothing usable, or ran into its limit, is asked again as two halves (`summarize(part:)`).
    /// When the model cannot be batched, the parts are written one at a time.
    private func summarize(parts: [SummaryPlan.Part], prompts: Prompts, tally: inout SummaryTally) async throws -> [[SummarySection]] {
        if parts.count > 1 {
            let box = BatchAnswers(count: parts.count)
            let requests = parts.map { summaryRequest(for: $0, titled: $0.heading == nil, prompts: prompts) }
            let began = Date()
            do {
                try await models.language.runBatch(requests, sharePrefix: true) { index, counted in box.set(index, counted) }
                let wall = Date().timeIntervalSince(began)
                tally.stepSeconds += wall
                var out: [[SummarySection]] = []
                for (k, part) in parts.enumerated() {
                    guard let run = box.get(k) else { throw LanguageModelError.workerStopped }
                    tally.steps += 1
                    tally.tokensIn += run.promptTokens
                    tally.tokensOut.append(run.outputTokens)
                    tally.prefillSeconds += run.promptSeconds
                    if run.hitCap { tally.capped += 1 }
                    tally.peakMegabytes = max(tally.peakMegabytes, run.peakMegabytes)
                    out.append(try await summarize(part: part, titled: part.heading == nil, prompts: prompts, tally: &tally, halved: false, first: run))
                }
                let decode = parts.indices.compactMap { box.get($0)?.generateSeconds }.max() ?? 0
                tally.generateSeconds += decode
                Log.write("summary", String(format: "batch of %d: in %d tokens %.2f s, out %d tokens %.2f s, wall %.2f s", parts.count,
                                            parts.indices.reduce(0) { $0 + (box.get($1)?.promptTokens ?? 0) }, parts.indices.reduce(0.0) { $0 + (box.get($1)?.promptSeconds ?? 0) },
                                            parts.indices.reduce(0) { $0 + (box.get($1)?.outputTokens ?? 0) }, decode, wall))
                return out
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelError {
                guard case .refused(let why) = error, why.hasPrefix("batch:") else { throw error }
                // The model cannot be batched: one at a time.
                Log.write("summary", "batched writing not available (\(why)); one part at a time")
            }
        }
        var out: [[SummarySection]] = []
        for part in parts { out.append(try await summarize(part: part, titled: part.heading == nil, prompts: prompts, tally: &tally, halved: false)) }
        return out
    }

    /// The section (or sections) for one part. When the model's answer has nothing usable in it, or ran
    /// into its limit (it was copying the part out), the part is asked about again as two halves; a half
    /// that still gives nothing is stood in for by its own first sentences, so no part goes missing.
    /// `first` is the answer already written for it in a batch, if there is one.
    private func summarize(part: SummaryPlan.Part, titled: Bool, prompts: Prompts, tally: inout SummaryTally, halved: Bool, first: LanguageModel.Counted? = nil) async throws -> [SummarySection] {
        // Room for what was asked for and half as much again; an answer that needs more has gone wrong.
        let run: LanguageModel.Counted
        if let first {
            run = first
        } else {
            let request = summaryRequest(for: part, titled: titled, prompts: prompts)
            run = try await summaryStep(request.text, instructions: request.instructions, maxTokens: request.maxTokens, tally: &tally)
        }
        let found = SummaryNotes.sections(from: summaryAnswer(run.text), cut: run.hitCap)
        func fit(_ sections: [SummarySection]) -> [SummarySection] {
            SummaryNotes.fitted(sections, points: part.points, headed: titled, list: part.list, code: part.code)
        }
        // The TLDR prompt's answers are cut at its 80 tokens by design: the unfinished sentence goes, the rest stands.
        if !found.isEmpty, !run.hitCap || models.summaryUsesTLDRPrompt { return fit(found) }
        let halves = SummaryPlan.halves(of: part.text)
        if !halved, halves.count == 2 {
            tally.retried += 1
            var both: [SummarySection] = []
            for half in halves {
                both += try await summarize(
                    part: SummaryPlan.Part(text: half, points: max(2, (part.points + 1) / 2), list: part.list), titled: titled, prompts: prompts,
                    tally: &tally, halved: true)
            }
            if !both.isEmpty { return fit(both) }
        }
        if !found.isEmpty { return fit(found) }
        tally.standIns += 1
        let standIn = SummaryNotes.fallback(for: part.text, points: part.points)
        return standIn.points.isEmpty ? [] : fit([standIn])
    }

    /// The request for one part's points. With the summary model (`ModelCenter.tldrSummaryModel`) it is the prompt its
    /// TLDR LoRA was trained on (phh/Qwen3-0.6B-TLDR-Lora), which gives its best summaries that way: the user's
    /// message alone, no system turn, at most 80 tokens. Its answer is a paragraph, read a sentence a point.
    private func summaryRequest(for part: SummaryPlan.Part, titled: Bool, prompts: Prompts) -> (instructions: String, text: String, maxTokens: Int) {
        if models.summaryUsesTLDRPrompt { return ("", "Your role is to make a summary of the following post.\n" + part.text, 80) }
        return (prompts.summarySystem(), prompts.summaryPartRequest(part: part.text, points: part.points, titled: titled, list: part.list), 80 + part.points * 60)
    }

    /// The model's answer as lines to read points from: with the TLDR prompt, each sentence of its paragraph on a line.
    private func summaryAnswer(_ text: String) -> String {
        guard models.summaryUsesTLDRPrompt else { return text }
        return text.components(separatedBy: .newlines).flatMap { line -> [String] in
            let found = ReadingText.sentences(line).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return found.count > 1 ? found.map { "- " + $0 } : [line]
        }.joined(separator: "\n")
    }

    /// One request to the language model for a summary, counted.
    private func summaryStep(_ request: String, instructions: String, maxTokens: Int, tally: inout SummaryTally) async throws -> LanguageModel.Counted {
        let began = Date()
        let run = try await models.language.runCounted(instructions: instructions, text: request, maxTokens: maxTokens, temperature: 0)
        let wall = Date().timeIntervalSince(began)
        tally.steps += 1
        tally.prefillSeconds += run.promptSeconds
        tally.generateSeconds += run.generateSeconds
        tally.stepSeconds += wall
        Log.write("summary", String(format: "step %d: in %d tokens %.2f s, out %d tokens %.2f s, wall %.2f s", tally.steps, run.promptTokens, run.promptSeconds, run.outputTokens, run.generateSeconds, wall))
        tally.tokensIn += run.promptTokens
        tally.tokensOut.append(run.outputTokens)
        if run.hitCap { tally.capped += 1 }
        tally.peakMegabytes = max(tally.peakMegabytes, run.peakMegabytes)
        return run
    }

    // MARK: From other apps

    /// Reads the text selected in the frontmost app.
    func readSelection() async {
        guard Features.on(.read) else { return }
        // Pressing the shortcut again while a selection is being read stops it.
        if isReadingSelection, isPlaying || playTask != nil {
            Log.write("read", "selection: stopped by the shortcut")
            dismiss()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard AXIsProcessTrusted() else {
            Log.write("read", "selection: no Accessibility permission")
            Toast.show("To read what you select in other apps, allow Accessibility for Chirp in System Settings.", seconds: 6)
            return
        }
        await read(from: front) { await self.gatherText(fromCursor: ReadingChoices.fromCursor) }
    }

    /// Fetches the text with `gather` and reads it.
    private func read(from front: String, gather: () async -> Gathered?) async {
        guard Features.on(.read) else { return }
        // Fetching the text can take half a second. A second press in that time is left alone, so the
        // text is not fetched (and copied) twice.
        guard !gathering else { return }
        gathering = true
        let pressed = Date()
        let found = await gather()
        gathering = false
        guard let found, var imported = try? DocumentImporter.importText(found.text, title: found.how == "page" ? found.pageTitle ?? "Selected text" : "Selected text") else {
            Log.write("read", "selection: nothing to read in \(front)")
            Toast.show("Select some text, or click into what you want read, then press the shortcut.")
            return
        }
        if let link = found.link { imported.source = link }
        Log.write("read", "selection: \(imported.text.count) characters from \(front) (\(found.how)), found in \(Int(Date().timeIntervalSince(pressed) * 1000)) ms")
        readOnce(imported)
        highlightedIndex = -1
        if let field = found.field {
            highlighter.begin(field: field.0, at: field.1)
        } else if let page = found.page {
            highlighter.begin(pieces: page.0, text: page.1)
        }
    }

    /// What the user is looking at, for reading aloud or summarizing: the selection; else the text field
    /// from the cursor on; else what the app copies; else the page in the window in front.
    struct Gathered {
        var text: String
        var how: String
        /// The address and title of the page the text is on, when the app in front is showing one.
        var link: String?
        var pageTitle: String?
        /// An email's subject, when the text is a message read from Mail (Mail shows it outside the message's body).
        var subject: String?
        var field: (AXUIElement, Int)?
        var page: ([UnderlineController.TextRun], String)?
    }

    /// Finds the text to read in the app in front, trying each source in turn (see `Gathered`). Password
    /// fields are never read. Returns nil when there is nothing to read. With `fromCursor` false the text
    /// field step is left out: with nothing selected it goes straight on to what the app copies, then the page.
    func gatherText(fromCursor: Bool = true) async -> Gathered? {
        let focused = TextInserter.focusedElement()
        let secure = focused.map { TextInserter.stringValue($0, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) } ?? false
        var text = secure ? nil : TextInserter.selectedText()
        var how = "selection"
        var subject: String?
        // Where the text sits in the app, so the sentence being read can be marked there.
        var field: (AXUIElement, Int)?
        var page: ([UnderlineController.TextRun], String)?
        if text != nil, let focused, let range = UnderlineController.selection(in: focused), range.length > 0 {
            field = (focused, range.location)
        }
        if text == nil, !secure, fromCursor, let focused, let value = TextInserter.text(of: focused),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf16.count < 400_000
        {
            // Nothing selected: read on from the sentence the cursor is in, or everything when the cursor
            // is at the very end (where it sits after typing).
            let ns = value as NSString
            // Kept inside the text: an app can report a cursor place that is not in it.
            var start = min(max(UnderlineController.selection(in: focused)?.location ?? 0, 0), ns.length)
            let rest = start < ns.length ? ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if rest.isEmpty {
                start = 0
            } else {
                while start > 0 {
                    let before = ns.character(at: start - 1)
                    if before == 10 || before == 13 { break }
                    if start >= 2, before == 32, let mark = Unicode.Scalar(ns.character(at: start - 2)), ".!?".unicodeScalars.contains(mark) { break }
                    start -= 1
                }
            }
            text = ns.substring(from: start)
            field = (focused, start)
            how = start == 0 ? "whole field" : "from the cursor"
        }
        if text == nil, !secure, Self.frontIsMail, let message = Self.pageText() {
            // Apple Mail with the keyboard in the message list (where it usually is) or on the message's
            // frame: the message that is open, read straight from where Mail shows it. Copying comes after
            // this: with the list in front it would take whole threads, headers and all.
            text = message.1
            page = message
            how = "page"
            subject = Self.mailSubject()
        }
        if text == nil, !secure, let copied = await TextInserter.copySelection() {
            text = copied
            how = "copy"
            // The words came by copying, so where they sit is not known; the page's own text is looked
            // through for them, and the marks go wherever a sentence is found there.
            page = Self.pageText()
        }
        if text == nil, !secure, let gathered = Self.pageText() {
            // Nothing selected and no text field: the page in the window in front (an article, a PDF, a note
            // in reading view).
            text = gathered.1
            page = gathered
            how = "page"
        }
        guard let text else { return nil }
        // Where it came from, when it is a web page: kept with the document if it is saved.
        let from = Self.frontPage()
        return Gathered(text: text, how: how, link: from?.link, pageTitle: from?.title, subject: subject, field: field, page: page)
    }

    /// The address and title of the web page in the frontmost window, when there is one. Read through
    /// Accessibility: the window's web content says its address.
    static func frontPage() -> (link: String, title: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef,
            CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
            return ref as? [AXUIElement] ?? []
        }
        var found: String?
        func look(_ e: AXUIElement, _ depth: Int) {
            guard found == nil, depth < 12 else { return }
            if TextInserter.stringValue(e, kAXRoleAttribute) == "AXWebArea" {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &ref) == .success, let url = ref as? URL ?? (ref as? String).flatMap(URL.init(string:)),
                    url.scheme == "http" || url.scheme == "https"
                { found = url.absoluteString }
                return
            }
            for child in children(e).prefix(40) { look(child, depth + 1) }
        }
        look(window, 0)
        guard let found else { return nil }
        let title = TextInserter.stringValue(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (found, title?.isEmpty == false ? title : nil)
    }

    /// The subject of the message open in Mail, which Mail shows above the message's body, outside the web content the
    /// body is read from, so a summary is not named after the body's first line. A message in its own
    /// window is titled by its subject. In the main window, the subject is looked for among the header's lines that come
    /// before the body: the line after a "Subject:" label, or else the first line that is not the sender, a date, an
    /// address or a "To:" line. Not tried on Mail itself (a test copy cannot read another app); the log says what was
    /// found, never the words.
    static func mailSubject() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == mailBundleID else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef,
            CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement
        let found = PageFinder.pages(under: ScreenElement(element: window), all: false)
        // A message in a window of its own (no message list beside it): the window's title is its subject.
        if found.skippedLists == 0, let title = TextInserter.stringValue(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            Log.write("summary", "mail subject: from the message window's title, \(title.count) characters")
            return title
        }
        guard let body = found.pages.first?.element else { return nil }
        // The header's lines: static text before the body, under the body's nearest ancestors.
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
            return ref as? [AXUIElement] ?? []
        }
        func parent(_ e: AXUIElement) -> AXUIElement? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &ref) == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
        var lines: [String] = []
        var visited = 0
        func texts(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 400, depth < 8, lines.count < 40 else { return }
            let role = TextInserter.stringValue(e, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || PageFinder.listRoles.contains(role) { return }
            if role == (kAXStaticTextRole as String) || role == "AXTextField" || role == "AXTextArea" {
                if let v = TextInserter.stringValue(e, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { lines.append(v) }
                return
            }
            for c in children(e).prefix(60) { texts(c, depth + 1) }
        }
        var child = body
        for _ in 0..<4 {
            guard let up = parent(child) else { break }
            let kids = children(up)
            guard let at = kids.firstIndex(where: { CFEqual($0, child) }) else { break }
            for k in kids[..<at] { texts(k, 0) }
            if !lines.isEmpty { break }
            child = up
        }
        let subject = MailHeader.subject(fromHeaderLines: lines)
        Log.write("summary", "mail subject: \(lines.count) header lines before the message, \(subject.map { "\($0.count) characters taken" } ?? "none taken")")
        return subject
    }

    static let mailBundleID = "com.apple.mail"
    /// Whether Apple Mail is the app in front.
    static var frontIsMail: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mailBundleID }

    /// An element of another app's window, for `PageFinder`.
    nonisolated struct ScreenElement: ScreenNode {
        let element: AXUIElement
        var role: String {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success ? (value as? String) ?? "" : ""
        }
        var children: [ScreenElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
            return ((value as? [AXUIElement]) ?? []).map(ScreenElement.init)
        }
    }

    /// The text of the page in the frontmost window, with each piece of it and where it sits in the whole.
    /// Looks inside the web content when there is some, so toolbars and sidebars are left out.
    static func pageText() -> ([UnderlineController.TextRun], String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Set on the system-wide element the limit holds for every question Chirp asks, not this one object.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef,
            CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var out: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &out)
            return (out as? [AXUIElement]) ?? []
        }
        // The web content in the window, if any. Long lists are passed over on the way (`PageFinder`): in
        // Mail the message list comes first and would use up the whole search. Mail shows each message
        // of a thread in web content of its own, so there all of them are read, in the order shown.
        let mail = app.bundleIdentifier == mailBundleID
        let found = PageFinder.pages(under: ScreenElement(element: window), all: mail)
        // In Mail only a message is a page: with none open, the rest of the window (the mailbox list) is not read in its place.
        if mail, found.pages.isEmpty { return nil }
        let roots = found.pages.isEmpty ? [window] : (mail ? found.pages.map(\.element) : [found.pages[0].element])
        let web: AXUIElement? = found.pages.first?.element
        var visited = 0
        var runs: [UnderlineController.TextRun] = []
        var joined = ""
        func gather(_ e: AXUIElement, _ depth: Int, _ block: Int, _ row: Int) {
            visited += 1
            guard visited < 6000, depth < 30, joined.utf16.count < 200_000 else { return }
            let role = TextInserter.stringValue(e, kAXRoleAttribute) ?? ""
            if role == (kAXStaticTextRole as String), let value = TextInserter.stringValue(e, kAXValueAttribute),
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Pieces of one block run on; a new block starts a new line, which ends a heading. The cells
                // of one table row stay on one line with a tab between them, so the row is read a cell at
                // a time with a longer pause at its end (`ReadingText.tableCells`).
                if !joined.isEmpty { joined += block == lastBlock ? " " : row != 0 && row == lastRow ? "\t" : "\n" }
                lastBlock = block
                lastRow = row
                let start = joined.utf16.count
                joined += value
                runs.append(UnderlineController.TextRun(range: NSRange(location: start, length: value.utf16.count), element: e))
                return
            }
            // Buttons, menus and fields are controls, not reading matter.
            if ["AXButton", "AXMenuBar", "AXMenu", "AXToolbar", "AXTextField", "AXPopUpButton", "AXTabGroup", "AXScrollBar"].contains(role) { return }
            let kids = children(e)
            let isBlock = ["AXGroup", "AXHeading", "AXList", "AXRow", "AXCell", "AXWebArea"].contains(role) && kids.count > 0
            if isBlock { blockCount += 1 }
            let mine = isBlock ? blockCount : block
            // A row is known by its block's number; what is inside it belongs to that row.
            let inRow = role == "AXRow" ? mine : row
            for c in kids { gather(c, depth + 1, mine, inRow) }
        }
        var lastBlock = -1
        var lastRow = 0
        var blockCount = 0
        for root in roots { gather(root, 0, 0, 0) }
        // A window with only a few labels is not a page to read.
        guard joined.utf16.count >= (web == nil ? 400 : 80) else { return nil }
        return (runs, joined)
    }

    /// Opens text in the reader without adding it to the library and without starting to read.
    func openOnce(_ imported: DocumentImporter.Imported) {
        load(SavedItem(kind: .document, title: imported.title, body: imported.text, source: imported.source))
        // What goes with it if it is kept: its layout, its original, its pictures.
        opened = imported
    }

    /// Adds the text that was only open for now to the library, with its summary if it has one.
    @discardableResult
    func keepCurrent() -> SavedItem? {
        guard let doc = item, doc.id == nil, let saved = try? library.save(doc) else { return item }
        item = saved
        if let opened, opened.text == saved.body {
            DocumentImporter.keep(opened, as: saved, in: library)
        }
        opened = nil
        version += 1
        // A page kept from a browser has its address: the page is fetched once for its layout, its
        // pictures and a saved copy.
        if let id = saved.id, DocumentRows.host(saved.source) != nil, (try? library.documentExtra(itemID: id)) == nil {
            Task { await self.fillInKeptPage(id) }
        }
        return saved
    }

    /// What was opened without being kept, with what goes with it if it is.
    private var opened: DocumentImporter.Imported?

    /// A page kept from a browser was saved as the words read off the screen. Its address is known, so
    /// the page is fetched once: when what comes back is the same article, the document takes its layout
    /// and pictures; either way a saved copy of the page is kept as its original. A page that needs
    /// signing in comes back as something else, and the document stays as it was read.
    private func fillInKeptPage(_ id: Int64) async {
        guard let kept = try? library.item(id), let address = kept.source,
            let fetched = try? await DocumentImporter.importWebPage(address)
        else { return }
        // Still there, and not changed meanwhile.
        guard var now = try? library.item(id), now.body == kept.body else {
            if let made = fetched.staging { try? FileManager.default.removeItem(at: made) }
            return
        }
        var keep = fetched
        let same = PageMatch.sameArticle(now.body, fetched.text)
        // Not while it is being read aloud: the words under the voice must not change.
        let busy = item?.id == id && (isPlaying || playTask != nil || summarizing)
        if same, !busy {
            // The place is found again by the sentence it was at.
            let old = ReadingText.sentences(now.body)
            if now.position > 0, let at = old.last(where: { $0.offset <= now.position }) {
                let found = (fetched.text as NSString).range(of: at.text)
                now.position = found.location == NSNotFound ? 0 : found.location
            }
            now.body = fetched.text
            if now.title.isEmpty || now.title == Library.title(from: kept.body) { now.title = fetched.title }
            _ = try? library.save(now)
        } else {
            // The words stay as they were read; the saved copy and the site's name are still kept.
            keep.layout = nil
        }
        DocumentImporter.keep(keep, as: now, in: library)
        Log.write("read", "a kept page was fetched: \(same ? "the same article" : "a different page"), \(keep.original ?? "no copy")")
        if item?.id == id, same, !busy { load(now) }
        version += 1
    }

    /// Reads text aloud without adding it to the library.
    func readOnce(_ imported: DocumentImporter.Imported) {
        guard Features.on(.read) else { return }
        openOnce(imported)
        play()
    }

    // MARK: Test hooks

    /// Lets automated runs drive the reader and read back its state through `chirp://` links.
    private func registerDebug() {
        LinkHandler.commands["read-file"] = { [weak self] q in if let p = q["path"] { self?.importFile(URL(fileURLWithPath: p)) } }
        LinkHandler.commands["read-text"] = { [weak self] q in self?.importText(q["text"] ?? "") }
        LinkHandler.commands["read-web"] = { [weak self] q in Task { await self?.importWebPage(q["url"] ?? "") } }
        LinkHandler.commands["read-play"] = { [weak self] _ in self?.play() }
        LinkHandler.commands["read-pause"] = { [weak self] _ in self?.pause() }
        LinkHandler.commands["read-stop"] = { [weak self] _ in self?.stop() }
        LinkHandler.commands["read-dismiss"] = { [weak self] _ in self?.dismiss() }
        LinkHandler.commands["read-skip"] = { [weak self] q in self?.skip(Int(q["by"] ?? "1") ?? 1) }
        LinkHandler.commands["read-selection"] = { [weak self] _ in Task { await self?.readSelection() } }
        LinkHandler.commands["read-once"] = { [weak self] q in
            if let imported = try? DocumentImporter.importText(q["text"] ?? "", title: "Selected text") { self?.readOnce(imported) }
        }
        LinkHandler.commands["read-jump"] = { [weak self] q in self?.jump(to: Int(q["index"] ?? "0") ?? 0) }
        LinkHandler.commands["read-speed"] = { [weak self] q in self?.speed = Double(q["x"] ?? "1") ?? 1 }
        LinkHandler.commands["read-export"] = { [weak self] q in if let p = q["path"] { self?.exportAudio(to: URL(fileURLWithPath: p)) } }
        LinkHandler.commands["read-summarize"] = { [weak self] _ in Task { await self?.summarize() } }
        // Opens the summary above the open document's text, as its Summary button does.
        LinkHandler.commands["read-show-summary"] = { [weak self] _ in
            guard let self, let id = self.item?.id else { return }
            try? self.library.setSummaryCollapsed(itemID: id, false)
            self.version += 1
        }
        LinkHandler.commands["read-brackets"] = { [weak self] q in self?.skipBrackets = q["skip"] == "1" }
        LinkHandler.commands["read-citations"] = { [weak self] q in self?.skipCitations = q["skip"] == "1" }
        // Puts the voice away, as happens after it sits unused or when the language model needs the room.
        LinkHandler.commands["read-unload"] = { [weak self] _ in Task { await self?.models.unload(.voice) } }
        // Speak a sentence, then transcribe the audio, to prove the voice says what was written.
        LinkHandler.commands["read-roundtrip"] = { [weak self] q in
            guard let self else { return }
            self.roundTrip = ""
            Task {
                do {
                    try await self.models.ensure(.voice)
                    let spoken = try await self.voice.speak(q["text"] ?? "", voice: self.voiceID)
                    self.lastSynthSeconds = await self.voice.lastSynthesisSeconds
                    self.lastAudioSeconds = spoken.duration
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-roundtrip.wav")
                    try AudioFile.write(spoken.samples, sampleRate: 24_000, to: url)
                    try await self.models.ensure(.transcription)
                    self.roundTrip = try await self.models.transcriber.transcribe(file: url).text
                    if self.roundTrip.isEmpty { self.roundTrip = "(nothing recognised)" }
                } catch { self.roundTrip = "error: \(error.localizedDescription)" }
            }
        }
        LinkHandler.stateProviders["read"] = { [weak self] in
            guard let self else { return [:] }
            let word = self.wordRange.flatMap { r in self.item.map { ($0.body as NSString).substring(with: r) } } ?? ""
            return [
                "documents": self.documents().map(\.title), "title": self.item?.title ?? "", "sentences": self.sentences.count,
                "index": self.index, "playing": self.isPlaying, "preparing": self.isPreparing, "word": word,
                "first": self.sentences.first?.text ?? "", "current": self.sentences.indices.contains(self.index) ? self.sentences[self.index].text : "",
                "synthSeconds": self.lastSynthSeconds, "audioSeconds": self.lastAudioSeconds, "level": Double(self.lastLevel),
                "position": self.item?.position ?? 0, "roundTrip": self.roundTrip, "speed": self.speed,
                "characters": self.item?.body.count ?? 0, "stage": self.stage,
                "audioPlaying": self.player.isPlaying, "time": self.player.currentTime,
                "selection": self.isReadingSelection, "deviceAudio": self.player is DevicePlayer,
                "exporting": self.exportProgress ?? -1, "summary": self.item?.summary ?? "", "summarizing": self.summarizing,
                "skipCitations": self.skipCitations, "voiceLoaded": self.models.state(.voice) == .loaded, "voice": self.voiceID,

            ]
        }
    }
}

/// Thrown inside a piece of work when its feature is switched off part-way (Settings › General), so the
/// work stops between steps.
struct FeatureSwitchedOff: Error {}

/// "Say it as" while it is open: the words just spoken, the one picked, and how it should sound.
struct SayItAsOffer: Equatable {
    /// Where it was opened: on the perch (reading another app's page; reading carries on underneath) or in
    /// the Library's reader (reading pauses, and the question sits on the word).
    enum Place: String { case perch, reader }
    var place: Place
    var words: [String]
    var picked: String
    /// The picked word's place in the document's text, for the reader to put the question on it.
    var range: NSRange?
    /// How it should sound, as typed.
    var text: String
    /// Reading was paused for this and carries on when it closes.
    var resume: Bool
    var problem: String?
}

// MARK: - Say it as

extension ReadController {
    /// Opens "Say it as" on the word the mark is on: that word first and picked
    /// (a two-word name as one), the few words before it as the other chips. `word` is a word that was
    /// clicked in the reader (with its place in the document). Reading pauses while it is open, on the
    /// perch and in the reader alike, so the mark stays on the word being put right; it carries on when
    /// the question closes.
    func openSayItAs(place: SayItAsOffer.Place, word: NSRange? = nil) {
        guard Features.on(.read), let item, sentences.indices.contains(index) else { return }
        let body = item.body as NSString
        let current = sentences[index]
        let ranges = ReadingText.wordRanges(current.text)
        // Which word the mark is on: a clicked word in this sentence, else the mark as drawn, else the
        // word the voice is at, else (nothing played yet) the sentence's last word.
        func indexOf(_ absolute: NSRange) -> Int? {
            let local = absolute.location - current.offset
            return ranges.firstIndex { NSLocationInRange(local, $0) || $0.location == local }
        }
        var marked: Int?
        if let word { marked = indexOf(word) }
        if marked == nil, word == nil, let mark = wordRange { marked = indexOf(mark) }
        if marked == nil, word == nil, player.hasSentence { marked = ReadingText.wordIndex(at: player.currentTime, in: timings) }
        let offer = SayItAs.offer(sentence: current.text, marked: marked ?? max(0, ranges.count - 1),
            before: index > 0 ? sentences[index - 1].text : nil)
        var words = offer.words
        var picked = offer.picked
        var range = offer.range.map { NSRange(location: current.offset + $0.location, length: $0.length) }
        if let word, marked == nil, NSMaxRange(word) <= body.length {
            // A clicked word outside the sentence being read: that word, on its own.
            picked = SayItAs.bare(body.substring(with: word))
            range = word
            if !words.contains(where: { $0.caseInsensitiveCompare(picked) == .orderedSame }) { words.append(picked) }
        }
        guard !picked.isEmpty else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        sayItAs = SayItAsOffer(place: place, words: words, picked: picked, range: range, text: saidAs(picked) ?? "", resume: wasPlaying)
        Log.write("read", "say it as: opened on the \(place.rawValue) (\(words.count) words offered, marked word \(marked.map(String.init) ?? "none"))")
        if place == .perch { onSayItAs?(true) }
    }

    /// How the dictionary says a word should sound, whatever its capitals.
    private func saidAs(_ word: String) -> String? {
        pronunciations.first { $0.key.caseInsensitiveCompare(word) == .orderedSame }?.value
    }

    /// Another of the words offered.
    func pickSayItAs(_ word: String) {
        guard sayItAs != nil else { return }
        sayItAs?.picked = word
        sayItAs?.text = saidAs(word) ?? ""
        sayItAs?.problem = nil
    }

    /// What is typed in the field.
    func typeSayItAs(_ text: String) {
        guard sayItAs != nil, sayItAs?.text != text else { return }
        sayItAs?.text = text
        sayItAs?.problem = nil
    }

    /// Speaks what is typed, in the reading voice. Reading on the perch holds its breath meanwhile.
    func previewSayItAs() {
        guard let offer = sayItAs else { return }
        let text = offer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sayItAs?.problem = "Type how it should sound first."
            return
        }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.models.ensure(.voice)
                let spoken = try await self.voice.speak(text, voice: self.voiceID, speed: self.voiceSpeed)
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    self.previewer.play(spoken.samples, sampleRate: Int(spoken.sampleRate), rate: self.playbackRate) { done.resume() }
                }
                self.previews += 1
            } catch {
                self.sayItAs?.problem = "Could not preview it."
                Log.write("read", "say it as: preview failed: \(error.localizedDescription)")
            }
            // Reading that was only held for the preview carries on; reading paused for the question stays paused.
            if wasPlaying, self.sayItAs?.resume != true { self.play() }
        }
    }

    /// Saves the pronunciation to the Dictionary. It is used from the next sentence on: what was already
    /// made for the sentences ahead is dropped and made again.
    func saveSayItAs() {
        guard let offer = sayItAs else { return }
        let said = offer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else {
            sayItAs?.problem = "Type how it should sound first."
            return
        }
        do {
            try app.engine.addWord(offer.picked, pronunciation: said)
        } catch {
            sayItAs?.problem = "Could not save it."
            return
        }
        for key in pronunciations.keys where key.caseInsensitiveCompare(offer.picked) == .orderedSame { pronunciations[key] = nil }
        pronunciations[offer.picked] = said
        // Audio made ahead was made with the old pronunciation. The sentence playing now is left to finish
        // (the player holds it), but its kept copy goes too: reading pauses for the question now, and
        // going back to this sentence must say the word the new way.
        generation += 1
        cache = [:]
        cancelPending { $0 != self.index }
        if playTask != nil { prefetch(after: index) }
        Log.write("read", "say it as: saved to the dictionary")
        closeSayItAs(resume: true)
    }

    /// Puts the question away. Reading paused for it carries on when `resume` is true.
    func closeSayItAs(resume: Bool = true) {
        guard let offer = sayItAs else { return }
        previewer.stop()
        sayItAs = nil
        if offer.place == .perch { onSayItAs?(false) }
        if resume, offer.resume { play() }
    }

    /// `chirp://debug/say-it-as?open=perch` (or `reader`), `&pick=Word`, `&text=…`, `&preview=1`, `&save=1`, `&close=1`.
    func registerSayItAsDebug() {
        LinkHandler.commands["say-it-as"] = { [weak self] q in
            guard let self else { return }
            if let place = q["open"].flatMap(SayItAsOffer.Place.init(rawValue:)) { self.openSayItAs(place: place) }
            if let word = q["pick"] { self.pickSayItAs(word) }
            if let text = q["text"] { self.typeSayItAs(text) }
            if q["preview"] == "1" { self.previewSayItAs() }
            if q["save"] == "1" { self.saveSayItAs() }
            if q["close"] == "1" { self.closeSayItAs() }
        }
    }
}
