import AppKit
import ChirpCore
import SwiftUI

/// One thing the start bar can begin.
struct StartAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// True while this is the thing Chirp is doing now; the button is then tinted and stops it.
    var active = false
    let run: () -> Void
}

/// The start bar: one glass group of the things started from Home, one for each feature that is
/// switched on. There is no More: adding files and links is the toolbar's Add. In a window too narrow
/// for the names, the actions show as their icons.
struct StartBar: View {
    let actions: [StartAction]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(titles: true)
            bar(titles: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(titles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                StartButton(action: action, showsTitle: titles)
                if index < actions.count - 1 { Rectangle().fill(GlassFill.line).frame(width: 1, height: 18) }
            }
        }
        .padding(4)
        .frame(height: 40)
        .fixedSize()
        .chirpGlassCapsule()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start something")
    }
}

/// One action on the start bar. It sits on glass, so it is drawn with a fill, never glass of its own.
private struct StartButton: View {
    let action: StartAction
    var showsTitle = true
    @State private var hovering = false

    var body: some View {
        Button(action: action.run) {
            HStack(spacing: 7) {
                Image(action.symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
                if showsTitle { Text(action.title).font(.system(size: 13, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(action.active ? Color.onAmber : Color.ink.opacity(0.88))
            .padding(.leading, 10).padding(.trailing, 13).frame(height: 32)
            .background(action.active ? Color.amber : hovering ? GlassFill.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(showsTitle ? "" : action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("start.\(action.id)")
    }
}

/// Home: the first page. A welcome line with the bird and
/// This week under it, one bar to start something, Pinned and folders as tiles, then sections that each
/// show only when they have something to show, each with a look of its own: In progress, Coming up,
/// Carry on, Captured today (dictations have their own page and are left off), Try this.
struct HomePage: View {
    @Environment(AppModel.self) private var app
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation
    @Environment(ReadController.self) private var reader
    @Environment(PerchController.self) private var perch

    let pickDocument: () -> Void
    let pickAudio: () -> Void
    let askAddress: () -> Void
    let askLink: () -> Void
    let askDelete: (SavedItem) -> Void

    /// Documents part heard.
    @State private var listening: [SavedItem] = []
    /// How many of today's captures Home lists; the heading's count and "See everything" cover the rest.
    static let capturedShown = 6
    /// What is pinned in the Library, newest first, and the folders' names for their rows.
    @State private var pinned: [SavedItem] = []
    @State private var folderNames: [Int64: String] = [:]
    /// What was saved today, newest first.
    @State private var today: [SavedItem] = []
    /// The recording whose notes are being written, when there is one.
    @State private var writing: SavedItem?
    /// True when the recording in progress was started from "Voice note".
    /// The row of "Captured today" the arrow keys are on.
    @State private var cursor: Int?
    @State private var copiedID: Int64?
    /// What the welcome line is made from, the next meeting, the folders, the one tip and the week's counts.
    @State private var welcome = WelcomeLine.Day()
    @State private var comingUp: CalendarMeeting?
    @State private var folderChips: [HomeFolders.Chip] = []
    @State private var tip: HomeTip?
    @State private var week = WeekCounts()
    private let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    /// The newest recordings, for those whose notes are still being written or wait their turn.
    @State private var recentRecordings: [SavedItem] = []
    /// The tip whose sentence is being saved as a snippet.
    @State private var snippetFor: HomeTip?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let on = Features.shared.set
                let inProgress = HomeInProgress.rows(recorder: recorder, dictation: dictation, recordings: recentRecordings)
                // Nothing to show in any section: the bird sits in the middle of the page instead of beside the line.
                let empty = !on.on.isEmpty && inProgress.isEmpty && comingUp == nil && pinned.isEmpty && listening.isEmpty && today.isEmpty
                    && folderChips.isEmpty && tip == nil && week.tiles.isEmpty
                // The welcome line, written by rule from the day, with the bird beside it.
                // The welcome line, with This week under it (moved up from the foot of the page).
                HomeHello(day: welcome, showsBird: !empty, week: week)
                VStack(alignment: .leading, spacing: 0) {
                    let start = startActions
                    if !start.isEmpty { StartBar(actions: start).padding(.top, 18) }
                    if on.on.isEmpty { allOff } else if empty { HomeEmpty() } else {
                        // Each section is one line here and shows only when it has something to show.
                        HomePinnedFolders(pinned: pinned, folders: folderChips, folderNames: folderNames) { item in
                            if let id = item.id { try? recorder.library.setPinned(id: id, false) }
                            app.libraryVersion += 1
                        }
                        HomeInProgress(recordings: recentRecordings)
                        HomeComingUp(meeting: comingUp)
                        if !listening.isEmpty { carryOnSection }
                        if !today.isEmpty { capturedSection }
                        HomeTipSection(tip: tip, act: act, dismiss: { tip in
                            HomeTipSection.remember(dismissed: tip)
                            reload()
                        })
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, PageLayout.gutter).padding(.bottom, 28)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $snippetFor) { tip in
            if case .saveSnippet(let text) = tip.action {
                SnippetFromTip(text: text) { cue in
                    try? app.engine.save(Snippet(cue: cue, text: text))
                    // Saved: the tip has done its work, and the next one need not wait.
                    HomeTipSection.remember(dismissed: tip, quiet: false)
                    reload()
                }
            }
        }
        // The clock in the line and the meeting coming up move on while Home is open.
        .onReceive(minute) { _ in reload() }
        .onChange(of: recorder.version) { reload() }
        .onChange(of: recorder.writingNotesFor) { reload() }
        .onChange(of: dictation.historyVersion) { reload() }
        .onChange(of: reader.version) { reload() }
        .onChange(of: app.libraryVersion) { reload() }
        .onChange(of: Features.shared.set) { reload() }
        .onChange(of: recorder.phase) { _, phase in
            if phase == .idle { reload() }
        }
    }

    // MARK: Start bar

    /// The start bar's actions: those of the features that are switched on.
    private var startActions: [StartAction] {
        let recording = recorder.phase == .recording
        let all: [(Feature, StartAction)] = [
            (.dictate, StartAction(id: "dictate", title: "Dictate", symbol: "chirp.dictate", active: dictation.phase == .recording) { perch.dictate() }),
            // Note opens a note in the perch to type or dictate into.
            (.notes, StartAction(id: "note", title: "Note", symbol: "chirp.note", active: perch.notes.isOpen) { perch.note() }),
            (.meetings, StartAction(id: "meeting", title: "Record a meeting", symbol: "chirp.meeting", active: recording && recorder.kind == .meeting) {
                if recorder.phase == .idle || recording { perch.recordMeeting() }
            }),
            (.read, StartAction(id: "read", title: "Read aloud", symbol: "chirp.read", active: reader.isPlaying) {
                if reader.isPlaying { reader.pause() } else { pickAndRead(summarize: false) }
            }),
            (.summarize, StartAction(id: "summarize", title: "Summarize", symbol: "chirp.summarize", active: reader.summarizing) { pickAndRead(summarize: true) }),
        ]
        return all.filter { Features.on($0.0) }.map(\.1)
    }

    /// Home with every feature switched off: one line, and the way to the switches.
    private var allOff: some View {
        EmptyLine("Every feature is switched off.") {
            Button("Open Settings") {
                app.settingsTab = .general
                app.section = .settings
            }
        }
        .padding(.top, 18)
    }

    /// Asks for a document, keeps it, and reads it aloud or writes its summary.
    private func pickAndRead(summarize: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentImporter.supportedTypes
        panel.allowsMultipleSelection = false
        panel.message = summarize ? "Choose a document to summarize" : "Choose a document to read aloud"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.section = .documents
        reader.importFile(url)
        guard reader.item?.id != nil else { return }
        if summarize { Task { await reader.summarize() } } else { reader.play() }
    }

    // MARK: Carry on

    /// Documents part heard, to carry on with: one tinted band each, with the cover, how far, and Continue.
    /// What is being recorded or written has its own section, In progress.
    private var carryOnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Carry on", count: listening.count).padding(.bottom, -3)
            ForEach(listening, id: \.listID) { item in
                let done = LibraryRows.heard(item)
                let left = LibraryRows.measure(item).seconds * Double(100 - done) / 100
                HStack(spacing: 12) {
                    DocumentCover(item: item)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LibraryRows.title(item)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                        Text("Listening · \(done)% · \(LibraryRows.length(left)) left").font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1)
                        ProgressBar(value: Double(done) / 100).frame(width: 130).padding(.top, 3).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    if Features.on(.read) {
                        ActButton(title: "Continue", symbol: "chirp.play", primary: true) {
                            app.open(item)
                            reader.open(item)
                            if reader.item?.id == item.id { reader.play() }
                        }
                    } else {
                        ActButton(title: "Open") { app.open(item) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { app.open(item) }
            }
        }
        .accessibilityIdentifier("home.carryOn")
    }

    // MARK: Captured today

    /// What was captured today, as a timeline: the time in the left gutter, plain rows, no card. "See all"
    /// opens All.
    private var capturedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Captured today", count: today.count) {
                HeadingLink(title: "See all") { app.section = .everything }
                    .accessibilityIdentifier("home.everything")
            }
            VStack(spacing: 0) {
                ForEach(Array(today.prefix(Self.capturedShown).enumerated()), id: \.element.listID) { index, item in
                    HomeTimelineRow(
                        time: item.createdAt.formatted(date: .omitted, time: .shortened), symbol: LibrarySection.holding(item.kind).symbol,
                        title: LibraryRows.title(item), meta: timelineMeta(item), selected: cursor == index
                    ) {
                        HStack(spacing: 2) {
                            IconButton(symbol: copiedID == item.id ? "chirp.check" : "chirp.copy", label: item.kind == .meeting || item.kind == .voiceNote ? "Copy notes" : "Copy") { copy(item) }
                            if let file = item.audioFile {
                                let url = ChirpStore.audioDirectory.appendingPathComponent(file)
                                // Pause while this item's own audio is the one playing.
                                let playing = AudioPlayback.shared.current == url && AudioPlayback.shared.isPlaying
                                IconButton(symbol: playing ? "chirp.pause" : "chirp.play", label: playing ? "Pause" : "Play") { AudioPlayback.shared.toggle(url) }
                            } else if Features.on(.read) {
                                IconButton(symbol: "chirp.read", label: "Read aloud") { readAloud(item) }
                            }
                            Menu {
                                Button("Open") { app.open(item) }
                                Divider()
                                Button("Delete…", role: .destructive) { askDelete(item) }
                            } label: {
                                Image("chirp.more").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink.opacity(0.8))
                                    .frame(width: 28, height: 28).contentShape(Circle())
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .help("More")
                            .accessibilityLabel("More for \(LibraryRows.title(item))")
                        }
                    }
                    .onTapGesture { app.open(item) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { app.open(item) }
                }
            }
            .focusable(!today.isEmpty)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard !today.isEmpty else { return }
                let at = cursor ?? -1
                cursor = max(0, min(min(today.count, Self.capturedShown) - 1, direction == .up ? at - 1 : direction == .down ? at + 1 : at))
            }
            .onKeyPress(.return) {
                guard let cursor, today.indices.contains(cursor) else { return .ignored }
                app.open(today[cursor])
                return .handled
            }
            .onKeyPress(.escape) {
                guard cursor != nil else { return .ignored }
                cursor = nil
                return .handled
            }
        }
        .accessibilityIdentifier("home.captured")
    }

    /// "Meeting · 42 min · Launch": what it is and its folder, without the time (that is in the gutter).
    private func timelineMeta(_ item: SavedItem) -> String {
        let time = LibraryRows.when(item.createdAt, timeOnly: true)
        var parts: [String] = []
        // Without the time, and without a word said twice ("Document · Document").
        for part in LibraryRows.meta(item, kind: true, timeOnly: true).components(separatedBy: " · ") where part != time && part != parts.last { parts.append(part) }
        if let folder = item.folderID.flatMap({ folderNames[$0] }) { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    private func copy(_ item: SavedItem) {
        let text: String
        if item.kind == .meeting || item.kind == .voiceNote {
            let notes = [item.summary, item.body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            text = notes.isEmpty
                ? ((try? recorder.library.segments(itemID: item.id ?? -1)) ?? []).map(\.text).joined(separator: " ")
                : MarkdownLines.plain(notes.joined(separator: "\n\n"))
        } else {
            text = item.body
        }
        TextInserter.copy(text)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedID = nil
        }
    }

    /// Reads a document from where it was left; anything else is read once and not kept as a document.
    private func readAloud(_ item: SavedItem) {
        if item.kind == .document {
            app.open(item)
            reader.open(item)
            if reader.item?.id == item.id { reader.play() }
        } else if !item.body.isEmpty {
            reader.readOnce(DocumentImporter.Imported(title: LibraryRows.title(item), text: item.body, source: item.kind.label))
        }
    }

    // MARK: Data

    /// The kinds "Captured today" lists: recordings, notes and documents. Dictations are left off Home
    /// (there are dozens a day, and they have their own page).
    static func capturedKinds(_ on: FeatureSet) -> [ItemKind] { on.shownKinds.filter { $0 != .dictation } }

    private func reload() {
        let library = recorder.library
        let on = Features.shared.set
        // Documents part heard are Read aloud's to carry on with.
        let documents = on.isOn(.read) ? (try? library.items(kinds: [.document], limit: 200)) ?? [] : []
        listening = documents.filter { $0.position > 0 && (1..<99).contains(LibraryRows.heard($0)) }.prefix(5).map { $0 }
        let start = Calendar.current.startOfDay(for: Date())
        // What a switched-off feature saved is kept, and not listed.
        today = ((try? library.items(kinds: Self.capturedKinds(on), limit: 120)) ?? []).filter { $0.createdAt >= start }
        writing = recorder.writingNotesFor.flatMap { try? library.item($0) }
        LibraryRows.refresh(library)
        pinned = (try? library.pinned(kinds: on.shownKinds, limit: 12)) ?? []
        folderNames = Dictionary(((try? library.folders()) ?? []).compactMap { f in f.id.map { ($0, f.name) } }, uniquingKeysWith: { a, _ in a })
        if let cursor, !today.indices.contains(cursor) { self.cursor = nil }
        // What the welcome line and the sections show.
        recentRecordings = (try? library.items(kinds: [ItemKind.meeting, .voiceNote].filter(on.shows), limit: 30)) ?? []
        comingUp = HomeComingUp.next()
        welcome = WelcomeLine.Day(
            recordings: today.filter { $0.kind == .meeting }.count, notes: today.filter { $0.kind == .voiceNote }.count,
            documents: today.filter { $0.kind == .document || $0.kind == .note }.count, nextMeeting: comingUp?.start)
        folderChips = HomeFolders.chips(library, kinds: on.shownKinds)
        let allDocuments = on.shows(FeaturePage.documents) ? (try? library.items(kinds: [.document], limit: 200)) ?? [] : []
        tip = HomeTipSection.pick(library: library, engine: app.engine, documents: allDocuments)
        week = HomeWeek.counts(library: library, documents: allDocuments)
    }

    /// Does what a tip's button says.
    private func act(_ tip: HomeTip) {
        switch tip.action {
        case .saveSnippet: snippetFor = tip
        case .addWord:
            HomeTipSection.addWord(tip, engine: app.engine)
            app.libraryVersion += 1
            reload()
        case .newNote: perch.note()
        case .readDocument: pickAndRead(summarize: false)
        case .summarizeDocument: pickAndRead(summarize: true)
        }
    }
}
