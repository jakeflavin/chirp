import AVFoundation
import ChirpCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// One past dictation: its words, and under them the app it was typed into and when. Copy and More
/// show on the row pointed at; an opened row shows all of its words.
struct DictationRow: View {
    @Environment(DictationController.self) private var dictation
    let item: SavedItem
    /// True while the row is opened to its full text.
    var open = false
    /// True while the arrow keys are on this row.
    var onCursor = false
    var copied = false
    let copy: () -> Void
    let edit: () -> Void
    /// Opens the snippet sheet on this dictation's words.
    var saveAsSnippet: (() -> Void)?
    @State private var hovering = false
    /// True while Delete… asks before the dictation goes.
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: open ? .top : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                // A dictation kept with its sound and no words says so; the line was blank before.
                let said = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = Text(said.isEmpty ? "No words yet. The sound was kept." : said)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(said.isEmpty ? Color.quiet : Color.ink)
                // The words can be selected once the row is opened; before that a click opens it.
                if open {
                    words.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    words.lineLimit(1)
                }
                Text(meta).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1)
            }
            Spacer(minLength: 8)
            // With no words, what can be done about it is in view, not only in the menu.
            if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let file = item.audioFile {
                ActButton(title: "Play") { AudioPlayback.shared.toggle(ChirpStore.audioDirectory.appendingPathComponent(file)) }
                ActButton(title: "Transcribe again") { Task { await dictation.retranscribe(item) } }
                    .disabled(dictation.phase != .idle)
            }
            HStack(spacing: 2) {
                IconButton(symbol: copied ? "chirp.check" : "chirp.copy", label: "Copy", action: copy)
                Menu {
                    Button("Edit…", action: edit)
                    if item.rawText != item.body, !item.rawText.isEmpty { Button("Copy Original Words") { TextInserter.copy(item.rawText) } }
                    if let file = item.audioFile {
                        Button("Play") { AudioPlayback.shared.toggle(ChirpStore.audioDirectory.appendingPathComponent(file)) }
                        Button("Transcribe Again") { Task { await dictation.retranscribe(item) } }.disabled(dictation.phase != .idle)
                    }
                    if let saveAsSnippet, !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Save as a Snippet…", action: saveAsSnippet)
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image("chirp.more").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink.opacity(0.8))
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More")
                .accessibilityLabel("More for \(item.title.isEmpty ? "this dictation" : item.title)")
            }
            // Hidden by opacity only, so VoiceOver can still reach Copy and More without a pointer.
            .opacity(hovering || onCursor ? 1 : 0)
        }
        .padding(.vertical, open ? 9 : 0)
        .frame(minHeight: PageLayout.rowHeight)
        .padding(.horizontal, 10)
        .background(hovering || onCursor ? PageLayout.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PageLayout.line).frame(height: 1).padding(.horizontal, 10).opacity(hovering || onCursor ? 0 : 1)
        }
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Edit…", action: edit)
            if item.rawText != item.body, !item.rawText.isEmpty { Button("Copy Original Words") { TextInserter.copy(item.rawText) } }
            if let saveAsSnippet, !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Save as a Snippet…", action: saveAsSnippet)
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { dictation.delete(item) }
        } message: {
            Text(item.deleteWarning)
        }
        .accessibilityElement(children: .contain)
    }

    /// The grey line: the app it was typed into, the time, and how long it took to say.
    private var meta: String {
        var parts: [String] = []
        if let id = item.appBundleID, let name = Self.appName(id) { parts.append(name) }
        parts.append(item.createdAt.formatted(date: .omitted, time: .shortened))
        if item.duration >= 1 { parts.append(item.duration.clock) }
        return parts.joined(separator: " · ")
    }

    /// The name of the app a dictation was typed into, if it is still installed.
    static func appName(_ bundleID: String) -> String? {
        if let known = appNames[bundleID] { return known }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
        appNames.updateValue(name, forKey: bundleID)
        return name
    }

    /// Names already looked up (nil for an app that is not installed), so a row does not ask the disk each time it is drawn.
    private static var appNames: [String: String?] = [:]
}

/// Fix a past dictation. Words the user changes are offered to the dictionary automatically.
struct DictationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: SavedItem
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit dictation").font(.sectionTitle)
            TextEditor(text: $text)
                // Chirp never offers Apple's Writing Tools: its own models do that work.
                .writingToolsBehavior(.disabled)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.15)))
                .accessibilityIdentifier("dictation.editor")
            Text("If you fix a word Chirp misheard, it is added to your dictionary so it is right next time. You can see and remove learned words in the Library, under Dictionary.")
                .font(.rowMeta).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("dictation.editor.save")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { text = item.body }
    }
}

/// Settings › Dictation: what happens to what is said, and how the speech model runs. The keys are on the Shortcuts tab.
struct SpeakOptions: View {
    @Environment(DictationController.self) private var dictation
    @Environment(ModelCenter.self) private var models
    @State private var unloadMinutes = ModelCenter.speechUnloadMinutes
    @State private var speechBackend = ModelCenter.speechBackend
    @State private var gpuUnavailable = false
    @State private var sounds = Sounds.enabled

    var body: some View {
        @Bindable var dictation = dictation
        Form {
            SettingsSection("How you dictate") {
                HoldKeyPicker(title: "Hold to talk", help: "Hold the key, talk, release to finish")
                ShortcutRow(title: "Hands-free", help: "Press once to start a long dictation, again to stop", name: .dictate)
                Toggle(isOn: $dictation.keepMicReady) {
                    Text("Keep the microphone ready")
                    Text("The first word is never cut off. macOS shows its orange dot; nothing is kept until you dictate")
                }
                Toggle("Play a sound when dictation starts and stops", isOn: $sounds)
                    .onChange(of: sounds) { _, on in Sounds.enabled = on }
                LabeledContent("Microphone", value: "General › Sound")
            }
            SettingsSection("What is kept") {
                Toggle("Keep the audio of dictations", isOn: $dictation.keepAudio)
                Picker("Keep dictations", selection: $dictation.historyLimit) {
                    Text("Newest 50").tag(50)
                    Text("Newest 200").tag(200)
                    Text("Newest 1,000").tag(1000)
                }
            }
            SettingsSection("Speech model") {
                Picker(selection: $dictation.pieceSeconds) {
                    Text("Off").tag(0)
                    ForEach([15, 20, 25, 30, 40], id: \.self) { Text("About \($0) seconds").tag($0) }
                } label: {
                    Text("Transcribe long dictations in pieces")
                    Text("Pieces are written down at your pauses, so the wait at the end stays short")
                }
                Picker(selection: $unloadMinutes) {
                    Text("Never").tag(-1)
                    Text("Each dictation").tag(0)
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes without use").tag($0) }
                    Text("An hour without use").tag(60)
                } label: {
                    Text("Free the speech model after")
                    Text("It uses about 700 MB while loaded, and loads again when you next talk")
                }
                Picker(selection: $speechBackend) {
                    Text("Automatic (graphics chip)").tag("auto")
                    Text("Processor").tag("cpu")
                } label: {
                    Text("Run speech on")
                    Text("Try Processor only if dictation fails or returns nonsense")
                }
                if gpuUnavailable {
                    LabeledContent {
                        Button("Try again") {
                            models.transcriber.retryGPU()
                            gpuUnavailable = false
                            Task { await models.unload(.transcription) }
                        }
                    } label: {
                        Text("The graphics chip stopped answering")
                        Text("Speech is running on the processor, which is slower")
                    }
                }
            }
            SettingsSection("Your style") {
                LabeledContent("Filler words, “scratch that”, “new line”", value: "Writing style › Your style")
            }
            .onChange(of: unloadMinutes) { _, value in ModelCenter.speechUnloadMinutes = value }
            .onAppear { gpuUnavailable = models.transcriber.gpuUnavailable }
            .onChange(of: speechBackend) { _, value in
                ModelCenter.speechBackend = value
                // Changing this forgets an earlier GPU failure, so the GPU is tried again. It takes effect at the next load.
                models.transcriber.retryGPU()
                gpuUnavailable = false
                Task { await models.unload(.transcription) }
            }
        }
    }
}

/// Plays one audio file at a time, and says how far through it is so a bar can show and move it.
@MainActor
@Observable
final class AudioPlayback {
    static let shared = AudioPlayback()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?
    /// The file loaded now, playing or paused.
    private(set) var current: URL?
    private(set) var isPlaying = false
    /// Seconds into the file.
    private(set) var time: Double = 0
    /// The file's length in seconds.
    private(set) var duration: Double = 0
    /// How fast it plays: 1 is as recorded.
    private(set) var rate: Double = 1
    static let rates: [Double] = [1, 1.25, 1.5, 2]

    /// The speed button: the next speed, then back to 1.
    func nextRate() {
        let at = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(at + 1) % Self.rates.count]
        player?.rate = Float(rate)
    }

    /// Plays the file, or stops it if it is the one playing.
    func toggle(_ url: URL) {
        if current == url, player?.isPlaying == true {
            player?.stop()
            sync()
            return
        }
        load(url)
        player?.play()
        follow()
    }

    /// Plays the file from `time` seconds in.
    func play(_ url: URL, at time: Double) {
        if current != url || player == nil { load(url) }
        player?.currentTime = time
        player?.play()
        follow()
    }

    /// Plays or pauses the file, keeping its place.
    func playPause(_ url: URL) {
        if current != url || player == nil { load(url) }
        if player?.isPlaying == true { player?.pause() } else { player?.play() }
        follow()
    }

    /// Plays faster or slower (1 is as recorded), now and for what is played next.
    func setRate(_ rate: Double) {
        self.rate = rate
        player?.enableRate = true
        player?.rate = Float(rate)
    }

    /// Moves to `time` seconds in, playing or not.
    func seek(_ url: URL, to time: Double) {
        if current != url || player == nil { load(url) }
        player?.currentTime = max(0, min(time, duration))
        sync()
    }

    /// The length of a file that is not loaded, for a bar that has not been played yet.
    func length(of url: URL) -> Double {
        if current == url, duration > 0 { return duration }
        return (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }

    private func load(_ url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.rate = Float(rate)
        current = url
        duration = player?.duration ?? 0
        time = 0
    }

    /// Keeps `time` and `isPlaying` in step with the player while it plays.
    private func follow() {
        sync()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    private func sync() {
        isPlaying = player?.isPlaying ?? false
        time = player?.currentTime ?? 0
        if !isPlaying {
            ticker?.invalidate()
            ticker = nil
        }
    }
}
