import AppKit
import ChirpCore
import SwiftUI

// Meetings and voice notes in the Library. A recording has a page from the moment it starts. A meeting is its notes (Summary, Key
// points, Decisions, My notes) or its transcript, picked in its header; a voice note is its words as
// clean text. What the user kept at a moment (a typed note, a picture of the front window) sits in
// the transcript at that moment and in "My notes"; a click on one goes to that moment.

/// The small grey line and the title above a recording, shared by the live page and the saved one.
private struct RecordingHead<Title: View>: View {
    let live: Bool
    let line: String
    /// The kind's icon before the line (rule 7), when it is not being recorded.
    var symbol: String?
    @ViewBuilder var title: () -> Title

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if live { Circle().fill(Color.spelling).frame(width: 7, height: 7).accessibilityHidden(true) }
                else if let symbol { Image(symbol).font(.system(size: 11)).foregroundStyle(Color.quiet).accessibilityHidden(true) }
                Text(line).font(.system(size: 12)).foregroundStyle(Color.quiet).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            title()
        }
    }
}

/// A recording being made, or being finished after Stop: what has been said so far with the notes
/// sent at their moments, then "My notes", and the small bar that says it is recording.
struct LiveMeetingView: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(AppModel.self) private var app

    /// A meeting being recorded shows its transcript alone, without the notes to come.
    private var transcriptOnly: Bool { recorder.kind == .meeting && app.showTranscript }

    var body: some View {
        @Bindable var recorder = recorder
        let entries = MeetingText.timeline(lines: MeetingText.merged(recorder.shownSegments), notes: recorder.timedNotes)
        ZStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 0) {
            // What it is and its name stay above the lines as they arrive.
            VStack(alignment: .leading, spacing: 0) {
                RecordingHead(live: recorder.phase == .recording, line: sourceLine) {
                    TextField(recorder.kind.untitled, text: $recorder.title)
                        .textFieldStyle(.plain).font(.detailTitle).tracking(-0.2).frame(minHeight: 29)
                        .disabled(recorder.phase != .recording)
                        .accessibilityLabel("Title")
                }
                // Its actions, in its header like a saved one's: Stop recording and Attach a file.
                ItemActionBar(actions: liveActions, more: []) {
                    if recorder.kind == .meeting {
                        ViewSwitch(
                            label: "Show", options: [.init(title: "Notes"), .init(title: "Transcript")],
                            selection: Binding(get: { app.showTranscript ? 1 : 0 }, set: { app.showTranscript = $0 == 1 }),
                            identifier: "meeting.tabs")
                    }
                }
                .padding(.top, 10)
                if let warning = recorder.warning {
                    HStack(spacing: 6) {
                        Image("chirp.warning").font(.system(size: 11))
                        Text(warning).font(.system(size: 12))
                    }
                    .foregroundStyle(Color.caution).padding(.top, 8)
                    .accessibilityIdentifier("record.warning")
                }
                if !transcriptOnly {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Color.quiet).padding(.top, 6)
                        .accessibilityIdentifier("record.status")
                }
            }
            .padding(.leading, 30).padding(.trailing, 40).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading("Transcript so far")
                    if entries.isEmpty {
                        Text("Words appear here a few seconds after they are spoken.").font(.system(size: 13)).foregroundStyle(Color.quiet)
                    }
                    TranscriptTimeline(entries: entries, names: recorder.kind == .meeting, now: lastLine(entries))
                    if !recorder.timedNotes.isEmpty, !transcriptOnly {
                        SectionHeading("My notes", count: recorder.timedNotes.count)
                        MyNotesList(notes: recorder.timedNotes, go: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 30).padding(.trailing, 40).padding(.bottom, 96)
            }
            .defaultScrollAnchor(.bottom)
          }
            if recorder.phase == .recording { LiveDock().padding(.bottom, 18) }
        }
        .accessibilityIdentifier("record.live")
    }

    /// Stop recording, while it is recording; a file to keep with it, while it can still take one.
    private var liveActions: [HeaderAction] {
        var out: [HeaderAction] = []
        if recorder.phase == .recording {
            out.append(HeaderAction(id: "stop", title: "Stop recording", symbol: "chirp.stop", help: "Stop recording", stop: true, staysOut: true) { recorder.stop() })
            out.append(HeaderAction(id: "attach", title: "Attach a file", symbol: "chirp.attach", help: "Keep a file with this recording") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                for url in panel.urls where !recorder.attach(url) { Toast.show("Chirp could not keep \(url.lastPathComponent)", seconds: 5) }
            })
        }
        return out
    }

    /// "Recording now · started 14:02 · your microphone and this Mac's sound".
    private var sourceLine: String {
        switch recorder.phase {
        case .recording:
            let heard = recorder.includesComputerSound ? "your microphone and this Mac’s sound" : "your microphone"
            return "Recording now · started \(recorder.startedAt.formatted(date: .omitted, time: .shortened)) · \(heard)"
        case .finishing(let step): return step.isEmpty ? "Finishing" : step
        case .idle: return "Saved"
        }
    }

    private var hint: String {
        recorder.kind == .meeting ? "Notes will be written when you stop." : "Saved to Notes when you stop."
    }

    private func lastLine(_ entries: [MeetingText.TimelineEntry]) -> String? {
        guard recorder.phase == .recording else { return nil }
        return entries.last { if case .line = $0 { true } else { false } }?.id
    }
}

/// The bar at the foot of a recording being made: the light, "Recording", the clock and the level. It
/// is a view of its own because the level changes many times a second, and only this should be redrawn for it.
private struct LiveDock: View {
    @Environment(MeetingRecorder.self) private var recorder

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.spelling).frame(width: 7, height: 7).padding(.leading, 12).accessibilityHidden(true)
            Text("Recording").font(.system(size: 13, weight: .semibold))
            Text(recorder.elapsed.clock).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color.quiet)
            HStack(spacing: 2.5) {
                ForEach(Array(recorder.levels.suffix(8).enumerated()), id: \.offset) { _, level in
                    Capsule().fill(Color.quiet).frame(width: 2.5, height: 4 + 14 * max(0, min(1, level)))
                }
            }
            .frame(height: 22).animation(.linear(duration: 0.1), value: recorder.levels)
            .accessibilityHidden(true)
        }
        .padding(.trailing, 16)
        .frame(height: 46)
        .chirpGlassCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(recorder.elapsed.clock)")
    }
}

/// A transcript with what the user kept in it: each line with its time and who said it, and each note
/// or picture at the right, at its moment, like a message that was sent.
struct TranscriptTimeline: View {
    let entries: [MeetingText.TimelineEntry]
    /// Whether lines say who spoke (a meeting) or not (a voice note being made).
    var names = true
    /// The entry to light: the line being said or played, or the note that was asked for.
    var now: String?
    /// Called when a line is clicked, to play the recording from there.
    var play: ((Double) -> Void)?
    /// Called to give a speaker a name.
    var rename: ((String) -> Void)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(entries) { entry in
                switch entry {
                case .line(let line): said(line, lit: entry.id == now).id(entry.id)
                case .note(let note): TranscriptNote(note: note, lit: entry.id == now).id(entry.id)
                }
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
        .padding(.top, 4)
    }

    private func said(_ line: TranscriptSegment, lit: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.start.clock).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet).frame(width: 40, alignment: .leading)
            (Text(names ? (line.speaker == "Me" ? "You" : line.speaker) + "  " : "").fontWeight(.semibold)
                .foregroundStyle(line.speaker == "Me" ? Color.ink : Color.grammar)
                + Text(line.text).foregroundStyle(Color.ink.opacity(0.86)))
                .font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                .padding(.horizontal, lit ? 3 : 0)
                .background(lit ? Color.amber.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { play?(line.start) }
        .contextMenu {
            if let rename, names, line.speaker != "Me" { Button("Rename \(line.speaker)…") { rename(line.speaker) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(names ? (line.speaker == "Me" ? "You" : line.speaker) + ", " : "")\(line.start.clock): \(line.text)")
    }
}

/// A note or a picture in the transcript: at the right, with its time before it. A picture opens full size.
private struct TranscriptNote: View {
    let note: TimedNote
    let lit: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 40)
            Text(note.clock).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet)
            if note.isPicture {
                Button {
                    if let url = MeetingRecorder.pictureURL(note) { NSWorkspace.shared.open(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        KeptPicture(note: note, width: 210, height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.ink.opacity(0.2), lineWidth: 0.5))
                        Text(note.caption).font(.system(size: 12)).foregroundStyle(Color.quiet).lineLimit(1).padding(.horizontal, 4).padding(.bottom, 1)
                            .frame(maxWidth: 210, alignment: .leading)
                    }
                    .padding(6)
                    .background(Color.amber.opacity(lit ? 0.4 : 0.22), in: shape)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .help("Open the picture full size")
                .accessibilityLabel("Open the picture full size: \(note.line)")
            } else {
                Text(note.text).font(.system(size: 13)).foregroundStyle(Color.ink).textSelection(.enabled)
                    .frame(maxWidth: 358, alignment: .leading).fixedSize()
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.amber.opacity(lit ? 0.4 : 0.22), in: shape)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My note at \(note.clock): \(note.line)")
    }
}

/// "My notes": what the user kept, in order, each with its time. A row goes to its moment.
struct MyNotesList: View {
    let notes: [TimedNote]
    /// Goes to a note's moment in the transcript and the audio. Nil while the recording is still being made.
    let go: ((TimedNote) -> Void)?

    var body: some View {
        let sorted = notes.sorted { $0.at < $1.at }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { index, note in
                HStack(spacing: 10) {
                    Text(note.clock).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet).frame(width: 40, alignment: .leading)
                    if note.isPicture {
                        KeptPicture(note: note, width: 46, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.ink.opacity(0.25), lineWidth: 0.5))
                    }
                    Text(note.line).font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.86)).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let go {
                        Button { go(note) } label: {
                            Image("chirp.open").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.quiet)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Go to \(note.clock) in the recording")
                        .accessibilityLabel("Go to \(note.clock) in the recording")
                    }
                }
                .frame(minHeight: note.isPicture ? 42 : 30)
                .overlay(alignment: .bottom) {
                    if index < sorted.count - 1 { Rectangle().fill(PageLayout.line).frame(height: 1) }
                }
                .contentShape(Rectangle())
                .onTapGesture { go?(note) }
                .accessibilityIdentifier("meeting.myNote")
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }
}

/// A saved meeting or voice note. A meeting shows its notes or its transcript (the switch in its header);
/// a voice note shows its words. One bar at the bottom plays the recording. Its header, under the title,
/// holds the switch, Copy, Export, Read aloud and "…" for Pin, Move to Folder, Attach and Delete.
struct MeetingDetail: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(AppModel.self) private var app
    @State var item: SavedItem
    let folders: [Folder]
    /// The actions the Library window gives every item.
    var header = ItemHeaderParts()
    @State private var segments: [TranscriptSegment] = []
    @State private var syncedTitle = ""
    @State private var renaming: String?
    @State private var newName = ""
    /// The entry of the transcript to light and bring into view: where a point was said, or a note's moment.
    @State private var shownEntry: String?
    // Worked out in `load()`, not each time the page is drawn.
    /// The transcript with neighbouring lines by one speaker joined, as it is shown.
    @State private var merged: [TranscriptSegment] = []
    /// The transcript line each point in the notes was traced to, for the points that could be traced.
    @State private var sources: [String: Int] = [:]
    /// What the recording was given besides its sound, and what the user kept during it.
    @State private var context = RecordingContext()
    /// The people invited, from the calendar.
    @State private var people: [String] = []
    @State private var playback = AudioPlayback.shared

    private var audio: URL? { item.audioFile.map { ChirpStore.audioDirectory.appendingPathComponent($0) } }
    private var isMeeting: Bool { item.kind == .meeting }
    /// A meeting's transcript is showing in place of its notes.
    private var showingTranscript: Bool { isMeeting && app.showTranscript }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        head
                        if showingTranscript { transcript } else if isMeeting { notes } else { words }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Room at the foot for the bar that floats over the page.
                    .padding(.leading, 30).padding(.trailing, 40).padding(.top, 18).padding(.bottom, 96)
                }
                .onChange(of: shownEntry) { _, entry in
                    guard let entry else { return }
                    // A moment later, once the transcript has been laid out.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(entry, anchor: .center) }
                    }
                }
            }
            if let audio {
                PlaybackDock(url: audio, fallbackDuration: item.duration, marks: context.notes.map(\.at))
                    .padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .onAppear(perform: load)
        .onChange(of: recorder.version) { load() }
        // A file dropped on a recording is kept with it (anywhere else in the window it is added to the Library).
        .onFileDrop { url in attach(url) }
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming, let id = item.id { recorder.renameSpeaker(itemID: id, from: old, to: newName) }
                renaming = nil
            }
            // The people the calendar says were invited.
            ForEach(people.prefix(5), id: \.self) { name in
                Button(name) {
                    if let old = renaming, let id = item.id { recorder.renameSpeaker(itemID: id, from: old, to: name) }
                    renaming = nil
                }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Head

    /// The line above the title: what it is, when, how long, who was there, and its folder.
    private var meta: String {
        let today = Calendar.current.isDateInToday(item.createdAt)
        let when = today ? "Today " + item.createdAt.formatted(date: .omitted, time: .shortened) : item.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
        var parts = [isMeeting ? "Meeting" : "Note", when, LibraryRows.length(item.duration)]
        if !people.isEmpty { parts.append("with " + ListFormatter.localizedString(byJoining: people.map { $0.split(separator: " ").first.map(String.init) ?? $0 })) }
        if let folder = item.folderID.flatMap({ id in folders.first { $0.id == id }?.name }) { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordingHead(live: false, line: meta, symbol: isMeeting ? "chirp.meeting" : "chirp.voiceNote") {
                TextField("Title", text: $item.title)
                    .textFieldStyle(.plain).font(.detailTitle).tracking(-0.2)
                    // Room for a line that holds an emoji, which stands taller than the letters and was cut off.
                    .frame(minHeight: 29)
                    .onSubmit { recorder.update(item) }
                    .accessibilityLabel("Title")
                    .accessibilityIdentifier("meeting.title")
            }
            .help(people.joined(separator: ", "))
            ItemActionBar(actions: header.actions, more: header.more) {
                if isMeeting {
                    ViewSwitch(
                        label: "Show", options: [.init(title: "Notes"), .init(title: "Transcript")],
                        selection: Binding(get: { app.showTranscript ? 1 : 0 }, set: { app.showTranscript = $0 == 1 }),
                        identifier: "meeting.tabs")
                }
            }
            .padding(.top, 10)
            // The files kept with it, then the way to add one. A voice note shows the row once it has a file.
            if isMeeting || !context.attachments.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(context.attachments.enumerated()), id: \.offset) { index, file in
                        FileChip(title: file.name, symbol: "chirp.file") { openFile(file) }
                            .help(file.file == nil ? "Only this document's text was kept" : "Open \(file.name)")
                            .contextMenu { Button("Remove from This Recording", role: .destructive) { removeFile(at: index) } }
                            .accessibilityIdentifier("meeting.file")
                    }
                    FileChip(title: "Attach a file", symbol: "chirp.attach", quiet: true, action: addDocument)
                        .help("Slides, a sheet, a PDF, a document. It is kept here and found by searching.")
                        .accessibilityIdentifier("meeting.addDocument")
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: A meeting's notes

    @ViewBuilder private var notes: some View {
        if let line = item.id.flatMap({ recorder.notesLine(for: $0) }) {
            // Being written, or waiting its turn behind another job.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(line).font(.system(size: 13)).foregroundStyle(Color.quiet)
                // Stop while they are being written, Cancel while they wait: the meeting keeps its transcript.
                if let id = item.id, let state = recorder.notesState(for: id), state != .stopping {
                    ActButton(title: state == .writing ? "Stop" : "Cancel") { recorder.stopNotes(for: id) }
                        .accessibilityIdentifier("meeting.notes.stop")
                }
            }
            .padding(.top, 18)
            .accessibilityIdentifier("meeting.writing")
        } else if item.summary.isEmpty {
            EmptyLine(segments.isEmpty ? "Nothing was said in this recording." : "No notes yet.") {
                if !segments.isEmpty { Button("Write notes", action: writeNotes).accessibilityIdentifier("meeting.redo") }
            }
            .padding(.top, 8)
        } else {
            WovenNotesView(
                notes: MeetingText.weave(userNotes: "", summary: item.summary),
                hasSource: { sources[$0] != nil }
            ) { point in
                // Show where it was said.
                if let line = sources[point] ?? MeetingText.source(of: point, in: merged), merged.indices.contains(line) {
                    shownEntry = MeetingText.TimelineEntry.line(merged[line]).id
                }
                app.showTranscript = true
            }
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityIdentifier("meeting.summary")
        }
        myNotes
        // A recording made before notes had times holds what was typed as one text.
        if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if context.notes.isEmpty { SectionHeading("My notes") }
            Text(item.body).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Color.ink.opacity(0.86)).textSelection(.enabled)
                .frame(maxWidth: 620, alignment: .leading).padding(.top, context.notes.isEmpty ? 0 : 8)
        }
        older
    }

    /// "My notes": the lines sent and the pictures kept, in order with their times.
    @ViewBuilder private var myNotes: some View {
        if !context.notes.isEmpty {
            SectionHeading("My notes", count: context.notes.count)
            MyNotesList(notes: context.notes) { note in go(to: note) }
        }
    }

    /// What recordings made before this build kept by themselves: links from the calendar and looks at the screen.
    @ViewBuilder private var older: some View {
        if !context.links.isEmpty || !context.screens.isEmpty {
            SectionHeading("With this recording", count: context.screens.count + min(4, context.links.count))
            ForEach(context.links.prefix(4), id: \.self) { link in
                if let url = URL(string: link) {
                    // Ink and underlined: Clay at this size is too faint to read on Paper.
                    Link(destination: url) {
                        Label(url.host() ?? link, image: "chirp.link").font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle(Color.ink).underline()
                    }
                }
            }
            if !context.screens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(context.screens.enumerated()), id: \.offset) { _, screen in ScreenThumbnail(screen: screen) }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: A voice note's words

    /// The note as clean text: its paragraphs, then what was kept while it was said.
    @ViewBuilder private var words: some View {
        let text = item.body.isEmpty ? MeetingText.cleanText(segments) : item.body
        if text.isEmpty {
            EmptyLine("Nothing was said in this recording.").padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.system(size: 13)).lineSpacing(4).foregroundStyle(Color.ink.opacity(0.86)).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }
            .padding(.top, 14)
            .accessibilityIdentifier("meeting.words")
        }
        myNotes
    }

    // MARK: A meeting's transcript

    private var transcript: some View {
        let entries = MeetingText.timeline(lines: merged, notes: context.notes)
        // The line being played is lit, unless a point or a note was just asked for.
        let playing = playback.current == audio && playback.isPlaying
            ? MeetingText.lineIndex(at: playback.time, in: merged).map { MeetingText.TimelineEntry.line(merged[$0]).id } : nil
        return TranscriptTimeline(
            entries: entries, now: playing ?? shownEntry,
            play: { time in if let audio { AudioPlayback.shared.play(audio, at: time) } },
            rename: { name in
                newName = name
                renaming = name
            }
        )
        .padding(.top, 12)
        .accessibilityIdentifier("meeting.transcript")
    }

    /// Goes to a note's moment: in a meeting the transcript opens there, and the recording plays from it.
    private func go(to note: TimedNote) {
        if isMeeting {
            shownEntry = MeetingText.TimelineEntry.note(note).id
            app.showTranscript = true
        }
        if let audio { AudioPlayback.shared.play(audio, at: note.at) }
    }

    private func writeNotes() {
        guard let id = item.id else { return }
        recorder.update(item)
        Task { await recorder.writeNotes(for: id) }
    }

    // MARK: Files

    /// Lets the user pick a file to keep with this recording: any kind.
    private func addDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(attach)
    }

    /// Keeps a picked or dropped file with this recording.
    private func attach(_ url: URL) {
        guard let id = item.id else { return }
        if !recorder.attach(url, to: id) { Toast.show("Chirp could not keep \(url.lastPathComponent)", seconds: 5) }
        reloadContext()
    }

    private func removeFile(at index: Int) {
        guard let id = item.id else { return }
        recorder.removeAttachment(at: index, from: id)
        reloadContext()
    }

    /// Opens the kept copy of an attached file in the app that reads it.
    private func openFile(_ file: RecordingContext.Attachment) {
        guard let url = MeetingRecorder.attachmentURL(file), FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reloadContext() {
        guard let id = item.id, let fresh = try? recorder.library.item(id) else { return }
        item.context = fresh.context
        context = RecordingContext(json: fresh.context)
    }

    /// Finds, once, the transcript line each point in the notes came from.
    private func traceSources() {
        let notes = MeetingText.weave(userNotes: "", summary: item.summary)
        var found: [String: Int] = [:]
        for point in notes.sections.flatMap(\.points) {
            if let line = MeetingText.source(of: point, in: merged) { found[point] = line }
        }
        sources = found
    }

    /// Reads the transcript again and takes in what changed elsewhere: new notes, folder, context, and the
    /// title Chirp gave it.
    private func load() {
        guard let id = item.id else { return }
        segments = (try? recorder.library.segments(itemID: id)) ?? []
        merged = MeetingText.merged(segments)
        // What is stored there is the attendees' names, except for a recording made from an audio file,
        // where it is the file's path: that is not a person.
        people = MeetingCalendar.people(fromSource: item.source)
        defer {
            context = RecordingContext(json: item.context)
            traceSources()
        }
        guard let fresh = try? recorder.library.item(id) else { return }
        if fresh.summary != item.summary || fresh.folderID != item.folderID || fresh.context != item.context || fresh.starred != item.starred
            || fresh.body != item.body
        {
            item.summary = fresh.summary
            item.folderID = fresh.folderID
            item.context = fresh.context
            item.starred = fresh.starred
            item.body = fresh.body
        }
        // Chirp names a recording after it is saved. Take that name unless the user typed their own meanwhile.
        if fresh.title != item.title, item.title == syncedTitle || syncedTitle.isEmpty { item.title = fresh.title }
        syncedTitle = fresh.title
    }
}

/// A file kept with a recording, as a small chip under its title; the last chip adds one.
private struct FileChip: View {
    let title: String
    let symbol: String
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .foregroundStyle(quiet ? Color.quiet.opacity(0.9) : Color.quiet)
            .padding(.leading, 7).padding(.trailing, 9).frame(height: 24)
            .background(Color.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.ink.opacity(0.18), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The bar that plays a recording: play or pause, back fifteen seconds, the line to drag along it with
/// a mark where each note was kept, the time, and the speed. In a narrow pane it drops the back button
/// and the total time before the line shortens. It is a view of its own because the time changes
/// four times a second, and only this part should be redrawn for it.
struct PlaybackDock: View {
    let url: URL
    /// The recording's length as saved, shown until the file has been loaded.
    let fallbackDuration: Double
    /// When each note or picture was kept, in seconds.
    var marks: [Double] = []
    @State private var playback = AudioPlayback.shared
    @State private var length: Double = 0

    private var mine: Bool { playback.current == url }
    private var time: Double { mine ? playback.time : 0 }
    private var total: Double { mine && playback.duration > 0 ? playback.duration : length > 0 ? length : fallbackDuration }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(scrubber: 260, time: true)
            row(scrubber: 150, time: true)
            row(scrubber: 150, time: true, back: false, total: false)
            row(scrubber: 90, time: true, back: false, total: false)
            row(scrubber: 60, time: false, back: false, total: false)
        }
        .onAppear { length = playback.length(of: url) }
        // Space plays or pauses, but not while the title or a note is being typed.
        .playbackKeys([.playPause]) { _ in playback.playPause(url) }
    }

    private func row(scrubber: CGFloat, time showsTime: Bool, back: Bool = true, total showsTotal: Bool = true) -> some View {
        HStack(spacing: 6) {
            IconButton(symbol: mine && playback.isPlaying ? "chirp.pause" : "chirp.play", label: mine && playback.isPlaying ? "Pause" : "Play", size: 34, active: true) {
                playback.playPause(url)
            }
            .accessibilityIdentifier("meeting.play")
            if back { IconButton(symbol: "chirp.back15", label: "Back 15 seconds", size: 34) { playback.seek(url, to: time - 15) } }
            Scrubber(value: total > 0 ? time / total : 0, marks: total > 0 ? marks.map { $0 / total } : []) { fraction in
                playback.seek(url, to: fraction * total)
            }
            .frame(width: scrubber)
            .padding(.horizontal, 4)
            .accessibilityLabel("Place in the recording")
            .accessibilityValue("\(time.clock) of \(total.clock)")
            .accessibilityAdjustableAction { direction in
                playback.seek(url, to: time + (direction == .increment ? 10 : -10))
            }
            if showsTime {
                Text(showsTotal ? "\(time.clock) / \(total.clock)" : time.clock).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color.quiet).fixedSize()
            }
            Button {
                playback.nextRate()
            } label: {
                Text(playback.rate.speedLabel).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet)
                    .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Playback speed")
            .accessibilityLabel("Speed")
            .accessibilityValue(playback.rate.speedLabel)
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 46)
        .chirpGlassCapsule()
    }
}

/// A thin line showing how far through something is; click or drag along it to move there. Small
/// marks stand where something was kept.
struct Scrubber: View {
    /// From 0 to 1.
    let value: Double
    /// Places along it to mark, each from 0 to 1.
    var marks: [Double] = []
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GlassFill.track).frame(height: 4)
                Capsule().fill(Color.amber).frame(width: max(0, min(1, value)) * geo.size.width, height: 4)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Capsule().fill(Color.ink.opacity(0.55)).frame(width: 2, height: 10)
                        .offset(x: max(0, min(1, mark)) * geo.size.width - 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(max(0, min(1, drag.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: 22)
    }
}

/// One look at the screen during a recording: the picture when it was kept, with when and where it was seen.
private struct ScreenThumbnail: View {
    let screen: RecordingContext.Screen

    /// Pictures already read from disk, so drawing the page again does not read and decode each one again.
    private static let pictures = NSCache<NSURL, NSImage>()

    private static func picture(at url: URL) -> NSImage? {
        if let known = pictures.object(forKey: url as NSURL) { return known }
        guard let image = NSImage(contentsOf: url) else { return nil }
        pictures.setObject(image, forKey: url as NSURL)
        return image
    }

    var body: some View {
        let url = screen.image.map { ChirpStore.audioDirectory.appendingPathComponent($0) }
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let url, let image = Self.picture(at: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.ink.opacity(0.06).overlay(Image("chirp.textInPicture").foregroundStyle(Color.quiet))
                }
            }
            .frame(width: 150, height: 94).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.1)))
            Text("\(screen.at.clock) · \(screen.app)").font(.caption).foregroundStyle(Color.quiet).lineLimit(1).frame(width: 150, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
        .help(screen.window.isEmpty ? "Open the picture" : screen.window)
        .accessibilityLabel("On screen at \(screen.at.clock) in \(screen.app)")
    }
}

struct WovenNotesView: View {
    let notes: MeetingText.WovenNotes
    /// Whether a point can be traced to a line of the transcript.
    var hasSource: ((String) -> Bool)?
    /// Called to show the line a point came from.
    var showSource: ((String) -> Void)?

    private static let written = Color.ink.opacity(0.86)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.mine.enumerated()), id: \.offset) { _, line in
                Text(line.text).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ForEach(Array(line.added.enumerated()), id: \.offset) { _, point in
                    self.point(point)
                }
            }
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                Text(section.title).font(.sectionTitle).foregroundStyle(Color.ink)
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                    self.point(point)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A point's words with its bold and italics drawn.
    private static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// One point Chirp wrote, with the marker at the right that leads to where it was said.
    private func point(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.quiet).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                .accessibilityHidden(true)
            Text(Self.styled(text)).font(.system(size: 13)).lineSpacing(2).foregroundStyle(Self.written)
            Spacer(minLength: 6)
            if let showSource, hasSource?(text) == true { SourceMarker { showSource(text) } }
        }
    }
}

/// At the right of a point in the notes: opens the transcript at the line the point came from.
private struct SourceMarker: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image("chirp.findText").font(.system(size: 11))
                .foregroundStyle(hovering ? Color.accentColor : Color.quiet)
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show where this was said")
        .accessibilityLabel("Show where this was said")
    }
}

/// Settings › Recording: when to offer, and what to keep.
/// Settings › Meetings: only what applies to meetings.
struct MeetingsOptions: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(MeetingDetector.self) private var detector
    @State private var calendar = CalendarReader.shared
    @AppStorage(RecordingSound.key) private var macSound = true

    var body: some View {
        @Bindable var recorder = recorder
        @Bindable var detector = detector
        @Bindable var calendar = calendar
        Form {
            SettingsSection("When a meeting starts") {
                Toggle("Offer to record when a call starts", isOn: $detector.enabled)
                Toggle(isOn: $calendar.enabled) {
                    Text("Use my calendar")
                    Text("For meeting names, who is in them and reminders. Chirp only reads it")
                }
            }
            SettingsSection("Sound") {
                MicrophonePicker()
                Toggle(isOn: $macSound) {
                    Text("Include this Mac’s sound")
                    Text("The other side of a call. On speakers, your microphone’s echo of it is left out")
                }
                .accessibilityIdentifier("settings.macSound")
                Toggle(isOn: $recorder.tellSpeakersApart) {
                    Text("Tell speakers apart")
                    Text("Labels each voice in the transcript; you can name them after")
                }
                .accessibilityIdentifier("settings.speakers")
            }
            SettingsSection("What is kept") {
                Toggle(isOn: $recorder.keepAudio) {
                    Text("Keep a meeting’s audio")
                    Text("Off: only the notes and transcript are kept")
                }
                .accessibilityIdentifier("settings.keepMeetingAudio")
            }
        }
    }
}

/// Settings › Notes: only what applies to notes.
struct NotesOptions: View {
    @Environment(MeetingRecorder.self) private var recorder
    @State private var checks = NoteController.checksWriting
    @State private var titleFromWords = MeetingRecorder.noteTitleFromWords

    var body: some View {
        @Bindable var recorder = recorder
        Form {
            SettingsSection("Writing a note") {
                Toggle(isOn: $checks) {
                    Text("Check writing in notes")
                    Text("The same underlines as in other apps")
                }
                .onChange(of: checks) { _, on in NoteController.checksWriting = on }
                .disabled(!Features.on(.write))
                .accessibilityIdentifier("settings.noteChecks")
            }
            SettingsSection("Voice notes") {
                MicrophonePicker()
                Toggle(isOn: $titleFromWords) {
                    Text("Title from the first words")
                    Text("Off: the title is the date and time")
                }
                .onChange(of: titleFromWords) { _, on in MeetingRecorder.noteTitleFromWords = on }
                .accessibilityIdentifier("settings.noteTitle")
                Toggle(isOn: $recorder.keepNoteAudio) {
                    Text("Keep a voice note’s audio")
                    Text("Off: only the text is kept")
                }
                .accessibilityIdentifier("settings.keepNoteAudio")
            }
        }
    }
}

/// The microphone Chirp listens with. There is one for the Mac: dictation listens with the same one, and
/// its path is not changed for notes or meetings, so this row on Meetings and on Notes sets the one
/// in General.
struct MicrophonePicker: View {
    @State private var microphone = AudioDevices.preferredUID
    @State private var inputs: [AudioDevices.Input] = []

    var body: some View {
        Picker(selection: $microphone) {
            Text("Same as macOS").tag("")
            ForEach(inputs) { Text($0.name).tag($0.uid) }
        } label: {
            Text("Microphone")
        }
        .onChange(of: microphone) { _, uid in AudioDevices.preferredUID = uid }
        .onAppear {
            inputs = AudioDevices.inputs()
            microphone = AudioDevices.preferredUID
        }
    }
}
