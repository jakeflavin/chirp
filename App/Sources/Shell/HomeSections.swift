import AppKit
import ChirpCore
import SwiftUI

// Home's welcome line and its sections. Each section is a view of its own that draws nothing when it
// has nothing to show, so one can be taken out of Home by removing its one line there. Each kind has a
// look of its own, so they are told apart at a glance: This week is a strip of numbers under the
// welcome line; Pinned and folders are tiles; In progress is rows in a white card; Coming up is a
// calendar row; Carry on is a tinted band; Captured today is a timeline; Try this is an amber band.

// MARK: - The welcome line

/// The top of Home: a greeting for the time of day, the date and one line written by rule, and the
/// bird at the right end showing what Chirp is doing.
struct HomeHello: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation
    @Environment(ReadController.self) private var reader

    /// What the line is made from.
    let day: WelcomeLine.Day
    /// False on an empty Home, where the bird sits in the middle of the page instead.
    var showsBird = true
    /// This week's numbers, in a strip under the line.
    var week = WeekCounts()
    @State private var gaze = CGPoint.zero
    /// True for a moment after a meeting's notes are ready: the bird looks at the new row.
    @State private var looksAtRow = false
    @State private var lookCount = 0

    static func subtitle(_ day: WelcomeLine.Day, now: Date = Date(), withLine: Bool = true) -> String {
        let date = now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return withLine ? "\(date) · \(WelcomeLine.line(day, now: now))" : date
    }

    static func greeting(now: Date = Date()) -> String {
        WelcomeLine.greeting(hour: Calendar.current.component(.hour, from: now))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.greeting()).font(.pageTitle).tracking(-0.5).foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.subtitle(day, withLine: showsBird)).font(.system(size: 13)).foregroundStyle(Color.quiet).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.hello")
                HomeWeek(counts: week).padding(.top, 14)
            }
            Spacer(minLength: 8)
            if showsBird {
                HStack(alignment: .bottom, spacing: 2) {
                    // The one red thing on Home: the light beside the bird while it is recording.
                    if recorder.phase == .recording {
                        Circle().fill(Color.spelling).frame(width: 7, height: 7).padding(.bottom, 8).accessibilityHidden(true)
                    }
                    // It sits at the right of the line, so it faces left, into the page. The
                    // drawing is mirrored, so a look to the left is given as a look to the right.
                    let look = looksAtRow ? CGPoint(x: HomeBird.rowGaze.x, y: HomeBird.rowGaze.y) : gaze
                    Bird(mood: mood, level: level, size: 60, gaze: CGPoint(x: -look.x, y: look.y))
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: 60, height: 60)
                }
                // It looks at the pointer when it comes near.
                .padding(40)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): gaze = CGPoint(x: max(-2, min(2, (point.x - 70) / 30)), y: max(-2, min(2, (point.y - 70) / 30)))
                    case .ended: gaze = .zero
                    }
                }
                .padding(-40)
                .accessibilityIdentifier("home.bird")
                // When notes are ready it stops pecking and looks at the new row.
                .onChange(of: recorder.writingNotesFor) { was, now in
                    let ready = was.flatMap { try? recorder.library.item($0) }?.summary.isEmpty == false
                    if HomeBird.looksAtNewRow(wasWriting: was, nowWriting: now, stopped: recorder.notesStoppedFor, hasNotes: ready) { lookAtRow() }
                }
                .onChange(of: HomeDebug.birdLookAsked) { lookAtRow() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PageLayout.gutter).padding(.trailing, PageLayout.gutter).padding(.top, 6)
    }

    /// Looks down at the rows for a few seconds, then sits as it was.
    private func lookAtRow() {
        lookCount += 1
        let mine = lookCount
        looksAtRow = true
        HomeDebug.birdLooksAtRow = true
        Task {
            try? await Task.sleep(for: .seconds(HomeBird.lookSeconds))
            guard mine == lookCount else { return }
            looksAtRow = false
            HomeDebug.birdLooksAtRow = false
        }
    }

    /// What Chirp is doing, as the bird shows it: listening while it records or takes dictation, its
    /// beak moving while it reads aloud, thinking while notes or a summary are written.
    private var mood: BirdMood {
        if recorder.phase == .recording || dictation.phase == .recording { return .listening }
        if reader.isPlaying { return .speaking }
        if recorder.phase != .idle || recorder.writingNotesFor != nil || dictation.phase != .idle || reader.summarizing || reader.isPreparing || dictation.importStatus != nil {
            return .thinking
        }
        return .idle
    }

    private var level: Double {
        if dictation.phase == .recording { return dictation.levels.last ?? 0 }
        return 0
    }
}

// MARK: - 1 · In progress

/// What is being recorded, written, fetched or waiting its turn right now, where it is looked for
/// first. Shown only while there is something. It reads the same state as the Library's "Now" rows
/// (`NowRows`): the recorder's own row, the recordings whose notes are not written yet, the file or
/// link being transcribed, and the jobs waiting behind them.
struct HomeInProgress: View {
    @Environment(AppModel.self) private var app
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation

    /// Recent recordings, among which those whose notes are not written yet are found.
    let recordings: [SavedItem]

    /// One thing in progress.
    struct Row: Identifiable {
        enum What { case recording, finishing, notes(SavedItem, waiting: Bool), importing, waitingImport(Int) }

        var id: String
        var what: What
        var symbol: String?
        var title: String
        /// What is happening, in ink ("Recording · 1:02", "Waiting for the recording to finish…").
        var state: String
        /// What it is, in grey ("Note").
        var kind: String
        var fraction: Double?
    }

    @MainActor static func rows(recorder: MeetingRecorder, dictation: DictationController, recordings: [SavedItem]) -> [Row] {
        var out: [Row] = []
        if let live = recorder.progressRow {
            let kind = live.kind == .voiceNote ? "Note" : "Meeting"
            out.append(Row(id: "recording", what: live.live ? .recording : .finishing, symbol: live.live ? nil : LibrarySection.holding(live.kind.itemKind).symbol, title: live.title, state: live.line, kind: kind))
        }
        for item in recordings {
            guard let id = item.id, let line = recorder.notesLine(for: id) else { continue }
            let kind = "\(item.kind == .voiceNote ? "Note" : "Meeting") · \(LibraryRows.length(item.duration))"
            out.append(Row(id: "notes.\(id)", what: .notes(item, waiting: recorder.notesState(for: id) == .waiting), symbol: LibrarySection.holding(item.kind).symbol, title: LibraryRows.title(item), state: line, kind: kind))
        }
        if let status = dictation.importStatus {
            out.append(Row(id: "import", what: .importing, symbol: "chirp.link", title: status.name, state: status.line.hasSuffix("…") ? status.line : status.line + "…", kind: "", fraction: LibraryList.fraction(in: status.line)))
        }
        for job in Jobs.shared.waitingImports {
            out.append(Row(id: "waiting.\(job.id)", what: .waitingImport(job.id), symbol: "chirp.link", title: job.title, state: job.line, kind: ""))
        }
        return out
    }

    var body: some View {
        let rows = Self.rows(recorder: recorder, dictation: dictation, recordings: recordings)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("In progress", count: rows.count)
                VStack(spacing: 0) {
                ForEach(rows) { row in
                    HomeStateRow(symbol: row.symbol, live: row.symbol == nil, title: row.title, state: row.state, kind: row.kind, fraction: row.fraction, line: row.id != rows.last?.id) {
                        HStack(spacing: 2) {
                            switch row.what {
                            case .recording:
                                ActButton(title: "Open") { openLive() }
                                ActButton(title: "Stop") { recorder.stop() }
                            case .finishing:
                                ActButton(title: "Open") { openLive() }
                            case .notes(let item, let waiting):
                                ActButton(title: "Open") { app.open(item) }
                                if let id = item.id, let state = recorder.notesState(for: id), state != .stopping {
                                    ActButton(title: waiting ? "Cancel" : "Stop") { recorder.stopNotes(for: id) }
                                }
                            case .importing:
                                ActButton(title: "Cancel") { dictation.cancelImport() }
                            case .waitingImport(let job):
                                ActButton(title: "Cancel") { Jobs.shared.cancel(job) }
                            }
                        }
                    }
                }
                }
                // Rows in a white card: what is live is the one thing on Home on a card.
                .padding(.horizontal, 14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            }
            .accessibilityIdentifier("home.inProgress")
        }
    }

    /// Opens the recording being made on its own page, as its row in the Library does.
    private func openLive() {
        app.section = recorder.kind == .voiceNote ? .notes : .meetings
        recorder.openLive()
    }
}

/// A row whose second line starts with what is happening, in ink, then what the thing is, in grey.
struct HomeStateRow<Actions: View>: View {
    var symbol: String?
    /// A red light in place of the symbol: this is being recorded now.
    var live = false
    let title: String
    let state: String
    let kind: String
    var fraction: Double?
    /// A line under it, between it and the next row.
    var line = true
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if live {
                    Circle().fill(Color.spelling).frame(width: 7, height: 7)
                } else if let symbol {
                    Image(symbol).font(.system(size: 14)).foregroundStyle(Color.quiet)
                }
            }
            .frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                HStack(spacing: 8) {
                    Text(state).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink).monospacedDigit().lineLimit(1)
                    if !kind.isEmpty { Text(kind).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1) }
                    if let fraction { ProgressBar(value: fraction).frame(width: 70).accessibilityHidden(true) }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            actions()
        }
        .frame(minHeight: PageLayout.rowHeight)
        .padding(.horizontal, 10)
        .background(hovering ? PageLayout.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottom) { Rectangle().fill(PageLayout.line).frame(height: 1).padding(.horizontal, 10).opacity(hovering || !line ? 0 : 1) }
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - 2 · Coming up

/// The next meeting on the calendar still to come today, with Record ready. One row; gone when the
/// meeting has begun.
struct HomeComingUp: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(PerchController.self) private var perch
    let meeting: CalendarMeeting?

    /// The next thing on the calendar that is a meeting and has not started, before the day ends.
    @MainActor static func next(now: Date = Date()) -> CalendarMeeting? {
        guard Features.on(.meetings) else { return nil }
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        return CalendarReader.shared.events().filter { $0.isMeeting && $0.start > now && $0.start < endOfDay }.min { $0.start < $1.start }
    }

    /// "2:00 pm · in 10 minutes · with Ana".
    static func line(_ meeting: CalendarMeeting, now: Date = Date()) -> String {
        var parts = [meeting.start.formatted(date: .omitted, time: .shortened).lowercased().replacingOccurrences(of: "\u{202F}", with: " ")]
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { parts.append("now") } else if minutes < 60 { parts.append(minutes == 1 ? "in 1 minute" : "in \(minutes) minutes") } else {
            let hours = minutes / 60, rest = minutes % 60
            parts.append(rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min")
        }
        if let first = meeting.attendees.first {
            let short = first.split(separator: " ").first.map(String.init) ?? first
            parts.append(meeting.attendees.count == 1 ? "with \(short)" : "with \(short) and \(meeting.attendees.count - 1) more")
        }
        return parts.joined(separator: " · ")
    }

    /// "in 10 min", "in 1 h 5 min", "now".
    static func untilLine(_ meeting: CalendarMeeting, now: Date = Date()) -> String {
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded())
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// "with Ana · Calendar".
    static func whoLine(_ meeting: CalendarMeeting) -> String {
        guard let first = meeting.attendees.first else { return "Calendar" }
        let short = first.split(separator: " ").first.map(String.init) ?? first
        return (meeting.attendees.count == 1 ? "with \(short)" : "with \(short) and \(meeting.attendees.count - 1) more") + " · Calendar"
    }

    var body: some View {
        if let meeting {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("Coming up")
                // A calendar row: the time leads in its own column, an amber rule beside it.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.start.formatted(date: .omitted, time: .shortened).lowercased().replacingOccurrences(of: "\u{202F}", with: " "))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).monospacedDigit()
                        Text(Self.untilLine(meeting)).font(.rowMeta).foregroundStyle(Color.quiet)
                    }
                    .frame(width: 70, alignment: .leading)
                    Capsule().fill(Color.amber).frame(width: 3, height: 34).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                        Text(Self.whoLine(meeting)).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // A meeting, not a voice note: with an offer showing it takes the offer up.
                    ActButton(title: "Record", symbol: "chirp.record", primary: true) { perch.recordMeeting() }
                        .disabled(recorder.phase != .idle)
                        .accessibilityHint(recorder.phase == .idle ? "Starts recording this meeting" : "A recording is already under way")
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(meeting.title), \(Self.line(meeting))")
            }
            .accessibilityIdentifier("home.comingUp")
        }
    }
}

// MARK: - 3 · Folders

/// The folders, most recently used first, for the tiles of Pinned and folders.
enum HomeFolders {

    struct Chip: Identifiable {
        var id: Int64
        var name: String
        var count: Int
        /// When something was last put in it.
        var used: Date?
    }

    /// Reads the folders with their counts and when each was last added to.
    static func chips(_ library: Library, kinds: [ItemKind]) -> [Chip] {
        let counts = (try? library.folderCounts(kinds: kinds)) ?? [:]
        let all: [Chip] = ((try? library.folders()) ?? []).compactMap { folder in
            guard let id = folder.id else { return nil }
            let newest = (try? library.items(kinds: kinds, folderID: id, limit: 1))?.first?.createdAt
            return Chip(id: id, name: folder.name, count: counts[id] ?? 0, used: newest)
        }
        return all.sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// "5 items · today", "1 item · Friday", "Empty".
    static func line(_ chip: Chip, now: Date = Date()) -> String {
        guard chip.count > 0 else { return "Empty" }
        let items = chip.count == 1 ? "1 item" : "\(chip.count) items"
        guard let used = chip.used else { return items }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: used), to: calendar.startOfDay(for: now)).day ?? 0
        let when = days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? used.formatted(.dateTime.weekday(.wide)) : used.formatted(.dateTime.day().month(.abbreviated))
        return "\(items) · \(when)"
    }
}

/// Pinned and folders, one area at the top of Home: the one 17-point heading on Home, then tiles.
/// Pinned items are white cards with their kind and a filled pin (Unpin); folders are grey tiles. Pinned
/// first, then folders most recently used first; seven at most, the rest are in the sidebar.
struct HomePinnedFolders: View {
    @Environment(AppModel.self) private var app
    let pinned: [SavedItem]
    let folders: [HomeFolders.Chip]
    let folderNames: [Int64: String]
    let unpin: (SavedItem) -> Void
    /// How wide the area is, for how many tiles go in a row.
    @State private var width: CGFloat = 800

    static let most = 7

    var body: some View {
        if !pinned.isEmpty || !folders.isEmpty {
            let items = Array(pinned.prefix(Self.most))
            let chips = Array(folders.prefix(max(0, Self.most - items.count)))
            VStack(alignment: .leading, spacing: 0) {
                Text("Pinned and folders").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 26).padding(.bottom, 10)
                // Rows of equal tiles, five at most to a row, as many as fit at about 150 points each.
                let tiles: [Tile] = items.map { .item($0) } + chips.map { .folder($0) }
                let across = max(2, min(5, Int((width + 10) / 160)))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: across)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(start..<start + across, id: \.self) { index in
                                if tiles.indices.contains(index) {
                                    switch tiles[index] {
                                    case .item(let item): pinnedTile(item)
                                    case .folder(let chip): folderTile(chip)
                                    }
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                }
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.pinned")
        }
    }

    private enum Tile {
        case item(SavedItem)
        case folder(HomeFolders.Chip)
    }

    private func pinnedTile(_ item: SavedItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(LibrarySection.holding(item.kind).symbol).font(.system(size: 10.5))
                Text(item.kind.label).font(.system(size: 11.5))
                Spacer(minLength: 4)
                Button {
                    unpin(item)
                } label: {
                    Image("chirp.pinFill").font(.system(size: 10)).foregroundStyle(Color.ink.opacity(0.7))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unpin")
                .accessibilityLabel("Unpin \(LibraryRows.title(item))")
            }
            .foregroundStyle(Color.quiet)
            Text(LibraryRows.title(item)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                .multilineTextAlignment(.leading).padding(.top, 4)
            Text(LibraryRows.meta(item)).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1).padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.leading, 11).padding(.trailing, 6).padding(.top, 7).padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.ink.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { app.open(item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(LibraryRows.title(item)), pinned \(item.kind.label.lowercased())")
        .accessibilityAction { app.open(item) }
    }

    private func folderTile(_ chip: HomeFolders.Chip) -> some View {
        Button {
            app.folderID = chip.id
            app.section = .folder
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image("chirp.folder").font(.system(size: 11.5)).foregroundStyle(Color.quiet).frame(height: 20)
                Text(chip.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                    .multilineTextAlignment(.leading).padding(.top, 4)
                Text(HomeFolders.line(chip)).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1).padding(.top, 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.top, 7).padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.name), folder, \(HomeFolders.line(chip))")
        .accessibilityHint("Opens the folder")
        .accessibilityIdentifier("home.folder")
    }
}

/// A row of Captured today: the time in the left gutter, the kind's icon, the name and what it is. Plain,
/// no card; what can be done shows on the row pointed at.
struct HomeTimelineRow<Actions: View>: View {
    let time: String
    let symbol: String
    let title: String
    let meta: String
    var selected = false
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(time).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet).lineLimit(1)
                .frame(width: 62, alignment: .leading)
            Image(symbol).font(.system(size: 13)).foregroundStyle(Color.quiet).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(meta).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions()
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityHidden(!(hovering || selected))
        }
        .frame(minHeight: 46)
        .padding(.trailing, 10)
        .background(hovering || selected ? PageLayout.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PageLayout.line).frame(height: 1).padding(.leading, 104).opacity(hovering || selected ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(time), \(title), \(meta)")
    }
}

/// A small cover for a document being listened to: the first picture kept with it, or a plain card with its kind's icon.
struct DocumentCover: View {
    let item: SavedItem

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Color.documentCoverTop, Color.documentCoverBottom], startPoint: .top, endPoint: .bottom))
            .overlay(Image("chirp.documents").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)))
            .frame(width: 32, height: 44)
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - 4 · One tip

/// "Try this": one tip made from what Chirp already knows, with its action and a way to put it away.
struct HomeTipSection: View {
    let tip: HomeTip?
    let act: (HomeTip) -> Void
    let dismiss: (HomeTip) -> Void

    static let dismissedKey = "homeTipsDismissed"
    static let dismissedAtKey = "homeTipDismissedAt"

    /// Works the tip out from the library. Text only of short dictations is looked at; nothing is kept.
    @MainActor static func pick(library: Library, engine: PersonalLanguage, documents: [SavedItem], now: Date = Date()) -> HomeTip? {
        let on = Features.shared.set
        let dictations = on.isOn(.dictate) ? ((try? library.items(kinds: [.dictation], limit: 200)) ?? []) : []
        let facts = HomeTip.Facts(
            dictations: dictations.map(\.body), snippets: ((try? engine.snippets(includeDisabled: true)) ?? []).map(\.text), features: on,
            recordings: ((try? library.count(kind: .meeting)) ?? 0) + ((try? library.count(kind: .voiceNote)) ?? 0),
            notes: (try? library.count(kind: .voiceNote)) ?? 0,
            documentsHeard: documents.filter { $0.position > 0 }.count, summaries: documents.filter { !$0.summary.isEmpty }.count,
            dictationCount: (try? library.count(kind: .dictation)) ?? 0,
            corrections: (try? engine.corrections(atLeast: HomeTip.repeatsNeeded)) ?? [],
            dictionary: ((try? engine.dictionary(includeDisabled: true)) ?? []).map(\.term))
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: dismissedAtKey)
        return HomeTip.pick(facts, dismissed: Set(defaults.stringArray(forKey: dismissedKey) ?? []), lastDismissal: at > 0 ? Date(timeIntervalSince1970: at) : nil, now: now)
    }

    /// "Add to Dictionary": the word goes in, with the spelling it was corrected from as a "sounds like"
    /// (unless only its capitals differ), and its count is forgotten.
    static func addWord(_ tip: HomeTip, engine: PersonalLanguage) {
        guard case .addWord(let term, let wrong) = tip.action else { return }
        _ = try? engine.addWord(term, soundsLike: wrong.caseInsensitiveCompare(term) == .orderedSame ? [] : [wrong])
        try? engine.forgetCorrections(of: term)
        // Added: the tip has done its work, and the next one need not wait.
        remember(dismissed: tip, quiet: false)
    }

    /// Puts a tip away for good, and keeps the section quiet for a few days.
    static func remember(dismissed tip: HomeTip, quiet: Bool = true) {
        let defaults = UserDefaults.standard
        defaults.set(Array(Set(defaults.stringArray(forKey: dismissedKey) ?? []).union([tip.id])), forKey: dismissedKey)
        if quiet { defaults.set(Date().timeIntervalSince1970, forKey: dismissedAtKey) }
    }

    var body: some View {
        if let tip {
            // No heading: an amber band with the bird, because the bird is offering it.
            HStack(spacing: 12) {
                Bird(size: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tip.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                    Text(tip.detail).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                ActButton(title: tip.button) { act(tip) }.accessibilityIdentifier("home.tip.act")
                IconButton(symbol: "chirp.close", label: "Dismiss") { dismiss(tip) }.accessibilityIdentifier("home.tip.dismiss")
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 10)
            .background(Color.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 26)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Try this")
            .accessibilityIdentifier("home.tip")
        }
    }

    private func symbol(_ tip: HomeTip) -> String {
        switch tip.action {
        case .saveSnippet: "chirp.snippetAdd"
        case .addWord: "chirp.addWord"
        case .newNote: "chirp.note"
        case .readDocument: "chirp.read"
        case .summarizeDocument: "chirp.summarize"
        }
    }
}

/// Saves a sentence as a snippet: the one thing to add is its cue.
struct SnippetFromTip: View {
    @Environment(\.dismiss) private var close
    let text: String
    let save: (_ cue: String) -> Void
    @State private var cue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as a snippet").font(.system(size: 15, weight: .bold))
            Text("Say or type the cue and Chirp gives you the saved text.").foregroundStyle(Color.quiet)
            TextField("Cue, such as “my sign-off”", text: $cue).textFieldStyle(.roundedBorder).accessibilityLabel("Cue")
            Text(text).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Saved text: \(text)")
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(cue.trimmingCharacters(in: .whitespaces))
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.system(size: 13))
        .padding(22).frame(width: 420)
        .background(Color.paper)
    }
}

// MARK: - 5 · This week

/// A few counts Chirp already keeps, for the week so far. A count of nothing is left out.
struct HomeWeek: View {
    let counts: WeekCounts

    /// Reads the week's counts. Recordings and dictations are read for the week; documents are handed in.
    @MainActor static func counts(library: Library, documents: [SavedItem], now: Date = Date()) -> WeekCounts {
        let start = WeekCounts.weekStart(for: now)
        let on = Features.shared.set
        let kinds = [ItemKind.meeting, .voiceNote, .dictation].filter(on.shows)
        let items = kinds.isEmpty ? [] : ((try? library.items(kinds: kinds, limit: 1500)) ?? []).filter { $0.createdAt >= start }
        return WeekCounts(items: items + documents, since: start, fixesAccepted: on.isOn(.write) ? FixTally.thisWeek(now: now) : 0)
    }

    /// Four numbers in one line, divided by hairlines, with "This week" at their left and no heading
    /// of their own; under the welcome line.
    var body: some View {
        let tiles = counts.tiles
        if !tiles.isEmpty {
            // One line where it fits; closer together, then in two lines, in a narrow window.
            ViewThatFits(in: .horizontal) {
                strip(tiles, gap: 16, label: true)
                strip(tiles, gap: 10, label: true)
                VStack(alignment: .leading, spacing: 8) {
                    strip(Array(tiles.prefix(2)), gap: 10, label: true)
                    strip(Array(tiles.dropFirst(2)), gap: 10, label: false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("This week")
            .accessibilityIdentifier("home.week")
        }
    }
}

extension HomeWeek {
    /// The numbers in one line, divided by hairlines, "This week" at the left (or room left for it).
    fileprivate func strip(_ tiles: [WeekCounts.Tile], gap: CGFloat, label: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text("This\nweek").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.75))
                .fixedSize().padding(.trailing, gap).opacity(label ? 1 : 0).accessibilityHidden(!label)
            ForEach(tiles) { tile in
                Rectangle().fill(PageLayout.line).frame(width: 1, height: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tile.value).font(.system(size: 16, weight: .semibold)).tracking(-0.2).monospacedDigit().foregroundStyle(Color.ink)
                    Text(tile.label).font(.system(size: 12)).foregroundStyle(Color.quiet).lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, gap)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
    }
}

/// How many writing fixes were accepted this week: one number kept in the preferences, started again
/// each week. Counted where a fix is put into another app's text.
enum FixTally {
    private static let weekKey = "fixesAcceptedWeek"
    private static let countKey = "fixesAcceptedCount"

    static func thisWeek(now: Date = Date()) -> Int {
        let defaults = UserDefaults.standard
        return defaults.double(forKey: weekKey) == WeekCounts.weekStart(for: now).timeIntervalSince1970 ? defaults.integer(forKey: countKey) : 0
    }

    static func add(_ n: Int = 1, now: Date = Date()) {
        guard n > 0 else { return }
        let defaults = UserDefaults.standard
        let had = thisWeek(now: now)
        defaults.set(WeekCounts.weekStart(for: now).timeIntervalSince1970, forKey: weekKey)
        defaults.set(had + n, forKey: countKey)
    }
}

/// Counts a spelling fix that was accepted, by its two words, so a word corrected often can be
/// suggested for the Dictionary. Only a misspelling swapped for another word counts.
enum CorrectionTally {
    static func note(_ issue: WritingIssue, fix: Fix, wrong: String, engine: PersonalLanguage) {
        guard issue.category == .spelling, fix.kind == .replace else { return }
        try? engine.noteCorrection(wrong: wrong, right: fix.text)
    }
}

// MARK: - Home, before anything is captured

/// An empty Home: the bird, one line, and where to start.
struct HomeEmpty: View {
    var body: some View {
        EmptyPage("Nothing here yet", line: "What you record, note and read shows up here. Start from the bar above, or from the perch.")
            .frame(minHeight: 300)
            .accessibilityIdentifier("home.empty")
    }
}

// MARK: - Test links

/// What Home and onboarding show, for the end-to-end checks (`state` has `home` and `onboarding`).
@MainActor
enum HomeDebug {
    /// The onboarding step on screen, noted by the view as it changes.
    static var onboardingStep = ""
    /// Whether Home's bird is looking at the new row just now, noted by the view.
    static var birdLooksAtRow = false
    /// Bumped by `home-bird?look=1`, which makes the bird look at the rows as it does when notes are ready.
    static var birdLookAsked: Int { BirdLook.shared.asked }

    @Observable final class BirdLook {
        static let shared = BirdLook()
        var asked = 0
    }

    static func register(app: AppModel, recorder: MeetingRecorder, dictation: DictationController) {
        LinkHandler.stateProviders["home"] = {
            let library = recorder.library
            let on = Features.shared.set
            let start = Calendar.current.startOfDay(for: Date())
            let today = ((try? library.items(kinds: HomePage.capturedKinds(on), limit: 120)) ?? []).filter { $0.createdAt >= start }
            let documents = on.shows(FeaturePage.documents) ? (try? library.items(kinds: [.document], limit: 200)) ?? [] : []
            let coming = HomeComingUp.next()
            let day = WelcomeLine.Day(
                recordings: today.filter { $0.kind == .meeting }.count, notes: today.filter { $0.kind == .voiceNote }.count,
                documents: today.filter { $0.kind == .document || $0.kind == .note }.count, nextMeeting: coming?.start)
            let recordings = (try? library.items(kinds: [.meeting, .voiceNote], limit: 30)) ?? []
            let tip = HomeTipSection.pick(library: library, engine: app.engine, documents: documents)
            let week = HomeWeek.counts(library: library, documents: documents)
            let folders = HomeFolders.chips(library, kinds: on.shownKinds)
            var out: [String: Any] = [
                "greeting": HomeHello.greeting(), "line": WelcomeLine.line(day, now: Date()), "subtitle": HomeHello.subtitle(day),
                "inProgress": HomeInProgress.rows(recorder: recorder, dictation: dictation, recordings: recordings).map { "\($0.title) | \($0.state)" },
                "comingUp": coming.map { "\($0.title) | \(HomeComingUp.line($0))" } ?? "",
                "folders": folders.map { "\($0.name) | \(HomeFolders.line($0))" },
                "tip": tip?.title ?? "", "tipID": tip?.id ?? "", "tipButton": tip?.button ?? "",
                "week": week.tiles.map { "\($0.value) \($0.label)" },
                "captured": today.map(LibraryRows.title),
                "capturedMeta": today.map { LibraryRows.meta($0, kind: true, timeOnly: true) },
            ]
            out["fixesThisWeek"] = FixTally.thisWeek()
            out["birdLooksAtRow"] = birdLooksAtRow
            out["corrections"] = ((try? app.engine.corrections()) ?? []).map { "\($0.wrong) > \($0.right) x\($0.times)" }
            out["dictionary"] = ((try? app.engine.dictionary(includeDisabled: true)) ?? []).map { $0.soundsLike.isEmpty ? $0.term : "\($0.term) (\($0.soundsLike.joined(separator: ", ")))" }
            return out
        }
        // `home-tip?dismiss=1` is the tip's ×; `reset=1` forgets every dismissal; `home-fixes?add=3` counts fixes as accepted.
        LinkHandler.commands["home-tip"] = { q in
            let library = recorder.library
            if q["reset"] == "1" {
                UserDefaults.standard.removeObject(forKey: HomeTipSection.dismissedKey)
                UserDefaults.standard.removeObject(forKey: HomeTipSection.dismissedAtKey)
            }
            // `quiet=0` ends the few quiet days after an ×, keeping what was put away.
            if q["quiet"] == "0" { UserDefaults.standard.removeObject(forKey: HomeTipSection.dismissedAtKey) }
            if q["act"] == "1" {
                let documents = (try? library.items(kinds: [.document], limit: 200)) ?? []
                if let tip = HomeTipSection.pick(library: library, engine: app.engine, documents: documents) { HomeTipSection.addWord(tip, engine: app.engine) }
            }
            if q["dismiss"] == "1" {
                let documents = (try? library.items(kinds: [.document], limit: 200)) ?? []
                if let tip = HomeTipSection.pick(library: library, engine: app.engine, documents: documents) { HomeTipSection.remember(dismissed: tip) }
            }
            app.libraryVersion += 1
        }
        // `home-seed?dictation=Thanks&times=6` saves that many dictations of those words, without the speech model.
        LinkHandler.commands["home-seed"] = { q in
            guard let text = q["dictation"] else { return }
            for _ in 0..<(Int(q["times"] ?? "1") ?? 1) { _ = try? recorder.library.save(SavedItem(kind: .dictation, title: Library.title(from: text), body: text)) }
            app.libraryVersion += 1
        }
        // `home-correct?wrong=kubernets&right=Kubernetes&times=4` counts that spelling as put right that often;
        // `home-tip?act=1` presses the tip's button when it needs nothing more (Add to Dictionary).
        LinkHandler.commands["home-correct"] = { q in
            guard let wrong = q["wrong"], let right = q["right"] else { return }
            for _ in 0..<(Int(q["times"] ?? "1") ?? 1) { try? app.engine.noteCorrection(wrong: wrong, right: right) }
            app.libraryVersion += 1
        }
        LinkHandler.commands["home-bird"] = { _ in BirdLook.shared.asked += 1 }
        LinkHandler.commands["home-fixes"] = { q in
            FixTally.add(Int(q["add"] ?? "1") ?? 1)
            app.libraryVersion += 1
        }
        LinkHandler.stateProviders["onboarding"] = {
            ["open": app.showOnboarding, "again": app.onboardingAgain, "step": onboardingStep,
             "steps": OnboardingStep.shown(for: Features.shared.set).map(\.rawValue),
             "done": (try? app.engine.setting("onboardingDone", as: Bool.self)) ?? false,
             "macSound": RecordingSound.include] as [String: Any]
        }
        // `onboarding-do?what=next` (`back`, `later`) presses the foot's buttons.
        LinkHandler.commands["onboarding-do"] = { q in onboardingPress?(q["what"] ?? "next") }
    }

    /// Set by the onboarding view while it is open, so a test link can press its buttons.
    static var onboardingPress: ((String) -> Void)?
}
