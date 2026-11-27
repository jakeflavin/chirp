import AppKit
import ChirpCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The words on a list row, and how a page's items are grouped. Worked out here so every page says
/// the same thing about the same item.
@MainActor
enum LibraryRows {
    /// The first line of a row. A dictation has no title, so its own words stand in for one.
    static func title(_ item: SavedItem) -> String {
        switch item.kind {
        case .dictation, .note:
            let text = item.title.isEmpty || item.kind == .dictation ? item.body : item.title
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? "(empty)" : line
        default: return item.title.isEmpty ? item.kind.label : item.title
        }
    }

    /// "Fri 13 Nov" for a row; "9:58" when `timeOnly` (rows already under their day).
    static func when(_ date: Date, timeOnly: Bool = false) -> String {
        if timeOnly || Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "42 min", or "2 h 31 min" for something long, or "4 sec" for something under a minute.
    static func length(_ seconds: Double) -> String {
        if seconds >= 1, seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// The grey line under a row's name: what it is, when, and how long or how far heard. `kind` puts the
    /// kind's name first, for a list that mixes kinds.
    static func meta(_ item: SavedItem, kind: Bool = false, timeOnly: Bool = false) -> String {
        var parts: [String] = []
        let date = when(item.createdAt, timeOnly: timeOnly)
        switch item.kind {
        case .meeting:
            if kind { parts.append("Meeting") }
            parts += [date, length(item.duration)]
            let people = MeetingCalendar.people(fromSource: item.source)
            if !people.isEmpty { parts.append(people.count > 3 ? "\(people.count) people" : people.map { $0.split(separator: " ").first.map(String.init) ?? $0 }.joined(separator: ", ")) }
        case .voiceNote:
            // A note says how it was made and when it last changed.
            let line = NoteRows.line(item, facts: item.id.flatMap { noteFacts[$0] }, folder: nil)
            parts.append(line)
        case .dictation:
            if kind { parts.append("Dictation") }
            if let id = item.appBundleID, let name = appName(id) { parts.append(name) }
            parts.append(date)
        case .note:
            if kind { parts.append("Note") }
            parts.append(date)
        case .document:
            // What it is and how long: "PDF · 14 pages", "longrunjournal.com · 9 min read".
            if kind { parts.append("Document") }
            parts += DocumentRows.facts(item, extra: extra(item), readSeconds: measure(item).seconds, speakers: speakers(item))
        }
        // A word said twice in a row ("Document · Document", when a document's facts know only its kind) once.
        return parts.enumerated().filter { $0.offset == 0 || $0.element != parts[$0.offset - 1] }.map(\.element).joined(separator: " · ")
    }

    /// How much of a document has been heard, 0 to 100.
    static func heard(_ item: SavedItem) -> Int { DocumentRows.heard(item) }

    /// What each document keeps beside its text (format, pages, site), by item id. Read when a page loads.
    private static var facts: [Int64: DocumentExtra] = [:]
    private static var speakerCounts: [Int64: Int] = [:]
    /// What each note keeps beside its words (how it was made, when edited and exported), by item id.
    private static var noteFacts: [Int64: NoteExtra] = [:]
    private static var library: Library?

    /// Reads what the documents keep, so rows can say what each is.
    static func refresh(_ library: Library) {
        self.library = library
        facts = (try? library.documentFacts()) ?? [:]
        noteFacts = (try? library.noteFacts()) ?? [:]
        speakerCounts = [:]
    }

    static func extra(_ item: SavedItem) -> DocumentExtra? { item.id.flatMap { facts[$0] } }

    /// How many voices a transcribed document has; zero for anything else.
    static func speakers(_ item: SavedItem) -> Int {
        guard let id = item.id, facts[id]?.isTranscript == true else { return 0 }
        if let known = speakerCounts[id] { return known }
        let count = (try? library?.speakerCount(itemID: id)) ?? 0
        speakerCounts[id] = count
        return count
    }

    /// Two lines of what is inside: the first points of the notes, or the first words.
    static func preview(_ item: SavedItem, library: Library) -> String {
        if let id = item.id, let known = previews[id], known.stamp == item.updatedAt { return known.text }
        var text = ""
        switch item.kind {
        case .voiceNote:
            // A note's words after its first line, which is its title.
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let lead = item.title.replacingOccurrences(of: "…", with: "")
            text = body.hasPrefix(lead) ? String(body.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:\n")) : body
        case .meeting:
            // What the notes say.
            let points = MeetingText.sections(of: item.summary).flatMap(\.bullets)
            text = MarkdownLines.plain(points.prefix(3).joined(separator: "\n")).replacingOccurrences(of: "\n", with: " ")
            if text.isEmpty { text = item.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            if text.isEmpty, let id = item.id {
                text = ((try? library.segments(itemID: id)) ?? []).prefix(4).map(\.text).joined(separator: " ")
            }
        case .note:
            // The title is the note's first words; the preview goes on from there.
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let lead = item.title.replacingOccurrences(of: "…", with: "")
            text = body.hasPrefix(lead) && body.count > lead.count + 2 ? String(body.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:\n")) : body
        case .dictation, .document: text = ""
        }
        text = String(text.prefix(220)).replacingOccurrences(of: "\n", with: " ")
        if let id = item.id { previews[id] = (item.updatedAt, text) }
        return text
    }

    /// Previews already worked out, by item id. `stamp` is the item's last change.
    private static var previews: [Int64: (stamp: Date, text: String)] = [:]

    /// One group of rows under a small heading.
    struct Group: Identifiable {
        let title: String
        let items: [SavedItem]
        var id: String { title }
        /// True for the pinned group: it has a full heading with its count, and a filled pin on each row.
        var isPinned: Bool { title == "Pinned" }
    }

    /// A page's items under their headings: pinned first; documents by how far heard; the rest by when.
    static func groups(_ items: [SavedItem], section: LibrarySection) -> [Group] {
        let pinned = items.filter(\.starred)
        let rest = items.filter { !$0.starred }
        var out: [Group] = pinned.isEmpty ? [] : [Group(title: "Pinned", items: pinned)]
        if section == .documents {
            // Pinned, then today's, then everything earlier.
            return DocumentRows.groups(items).map { Group(title: $0.title, items: $0.items) }
        } else {
            let cal = Calendar.current
            let weekAgo = cal.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400)
            let today = rest.filter { cal.isDateInToday($0.createdAt) }
            let week = rest.filter { !cal.isDateInToday($0.createdAt) && $0.createdAt >= weekAgo }
            let earlier = rest.filter { $0.createdAt < weekAgo }
            if !today.isEmpty { out.append(Group(title: "Today", items: today)) }
            if !week.isEmpty { out.append(Group(title: "This week", items: week)) }
            if !earlier.isEmpty { out.append(Group(title: "Earlier", items: earlier)) }
        }
        return out
    }

    /// The grey line under a list page's title: how many, and how many of them are recent or in progress.
    /// An empty page says so in the same place ("0 meetings"): every page has a grey line under its title.
    static func subtitle(for section: LibrarySection, items: [SavedItem]) -> String {
        let weekAgo = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400)
        let recent = items.filter { $0.createdAt >= weekAgo }.count
        func counted(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        switch section {
        case .meetings: return items.isEmpty ? "0 meetings" : counted(items.count, "meeting", "meetings") + " · \(recent) this week"
        case .notes:
            // "5 notes · 1 voice note".
            let voice = items.filter { $0.audioFile != nil || $0.duration > 0 }.count
            return items.isEmpty ? "0 notes" : counted(items.count, "note", "notes") + (voice > 0 ? " · " + counted(voice, "voice note", "voice notes") : "")
        case .documents: return DocumentRows.subtitle(items)
        case .everything: return items.isEmpty ? "0 items" : counted(items.count, "item", "items") + " · \(recent) this week"
        default: return ""
        }
    }

    /// App names already looked up, by bundle id (empty for an app that is not installed). Finding one
    /// means asking macOS and reading the disk, which is too slow to do for every row each time the list is drawn.
    private static var appNames: [String: String] = [:]

    /// The name of the app with this bundle id, looked up once.
    static func appName(_ bundleID: String) -> String? {
        if let known = appNames[bundleID] { return known.isEmpty ? nil : known }
        let name = DictationRow.appName(bundleID)
        appNames[bundleID] = name ?? ""
        return name
    }

    /// How long each document is, by item id: measuring means going through its whole text, and a book
    /// is long. `stamp` is the item's last change, so an edited document is measured again.
    private static var measures: [Int64: (stamp: Date, length: Int, seconds: Double)] = [:]

    /// A document's length in UTF-16 units (what `position` counts in) and its listening time at normal speed.
    static func measure(_ item: SavedItem) -> (length: Int, seconds: Double) {
        if let id = item.id, let known = measures[id], known.stamp == item.updatedAt { return (known.length, known.seconds) }
        let length = item.body.utf16.count
        let seconds = ReadingText.estimatedDuration(item.body)
        if let id = item.id { measures[id] = (item.updatedAt, length, seconds) }
        return (length, seconds)
    }
}

/// The list column of a list page: small headings, and rows of a name, a grey line and two lines of
/// what is inside. The arrow keys move through it.
struct LibraryList: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation
    let section: LibrarySection
    let items: [SavedItem]
    let folders: [Folder]
    @Binding var selectedID: Int64?
    let askDelete: (SavedItem) -> Void
    /// Pins or unpins an item; moves it to a folder (nil for none); asks for a new folder to put it in.
    var pin: (SavedItem) -> Void = { _ in }
    var move: (SavedItem, Int64?) -> Void = { _, _ in }
    var newFolder: (SavedItem) -> Void = { _ in }
    /// The item's header actions (Copy, Export, Read aloud, then Pin, Move to Folder… and Delete…), so a
    /// row's right-click menu offers what its header does.
    var header: (SavedItem) -> ItemHeaderParts = { _ in ItemHeaderParts() }
    @FocusState private var focused: Bool

    var body: some View {
        // A meeting whose notes are not written yet is listed under "Now", not under its day.
        let groups = LibraryRows.groups(items.filter { $0.id.flatMap { recorder.notesLine(for: $0) } == nil }, section: section)
        let order = groups.flatMap(\.items).compactMap(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // What is not finished yet, under "Now": the recording being made, notes being written, imports.
                    NowRows(section: section, items: items, selectedID: $selectedID)
                    ForEach(groups) { group in
                        if group.isPinned {
                            // The pinned group has a heading of its own, in full ink with its count.
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Pinned").font(.sectionTitle).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                                Text("\(group.items.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.quiet).monospacedDigit()
                            }
                            .padding(.leading, 10).padding(.top, 12).padding(.bottom, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("library.pinned")
                        } else {
                            Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.quiet)
                                .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.items, id: \.listID) { item in
                            // Made again when what the row says changes (a pin, a folder, how far heard): a row
                            // kept from before went on showing what it said then.
                            row(item, pinned: group.isPinned)
                                .id(stamp(item, pinned: group.isPinned))
                                .id(item.listID)
                        }
                        // A rule closes the pinned group off from the dated ones.
                        if group.isPinned, groups.count > 1 {
                            Rectangle().fill(PageLayout.line).frame(height: 1).padding(.horizontal, 10).padding(.top, 8)
                        }
                    }
                }
                // With the row's own 10, the words start on the page's left line.
                .padding(.leading, PageLayout.gutter - 10).padding(.trailing, 10).padding(.bottom, 16)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onMoveCommand { direction in
                guard let current = selectedID, let at = order.firstIndex(of: current) else {
                    selectedID = order.first
                    return
                }
                let next = direction == .down ? at + 1 : direction == .up ? at - 1 : at
                guard order.indices.contains(next) else { return }
                selectedID = order[next]
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(order[next]) }
            }
            .onDeleteCommand {
                if let id = selectedID, let item = items.first(where: { $0.id == id }) { askDelete(item) }
            }
            .accessibilityIdentifier("library.list")
        }
    }

    /// Everything a row shows, as one text: when it changes the row is drawn afresh.
    private func stamp(_ item: SavedItem, pinned: Bool) -> String {
        "\(pinned)|\(item.folderID ?? 0)|\(LibraryRows.title(item))|\(LibraryRows.meta(item, kind: section == .everything))|\(item.updatedAt.timeIntervalSince1970)"
    }

    /// The part done that a line of status names ("Getting the sound · 40%"), from 0 to 1.
    static func fraction(in line: String) -> Double? {
        guard let percent = line.range(of: #"(\d{1,3})%"#, options: .regularExpression), let n = Double(line[percent].dropLast()) else { return nil }
        return min(1, n / 100)
    }

    private func row(_ item: SavedItem, pinned: Bool = false) -> some View {
        let picked = item.id == selectedID
        let preview = LibraryRows.preview(item, library: recorder.library)
        let folder = item.folderID.flatMap { id in folders.first { $0.id == id }?.name }
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LibraryRows.title(item)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(LibraryRows.meta(item, kind: section == .everything) + (folder.map { " · \($0)" } ?? ""))
                    .font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1).padding(.top, 1)
                // Documents have no preview line. A note's row is as tall as what it has:
                // no words after its title, no line. Other rows keep room for two, so they are one height.
                if item.kind == .voiceNote {
                    if !preview.isEmpty {
                        Text(preview).font(.system(size: 12.5)).foregroundStyle(Color.quiet)
                            .lineLimit(2).padding(.top, 3)
                    }
                } else if section != .documents, item.kind != .document, item.kind != .dictation {
                    Text(preview.isEmpty ? " " : preview).font(.system(size: 12.5)).foregroundStyle(Color.quiet)
                        .lineLimit(2, reservesSpace: true).padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selectedID = item.id }
            if pinned {
                // The filled pin says it is pinned, and takes the pin off.
                Button {
                    pin(item)
                } label: {
                    Image("chirp.pinFill").font(.system(size: 11)).foregroundStyle(Color.quiet)
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Unpin")
                .accessibilityLabel("Unpin \(LibraryRows.title(item))")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .modifier(RowTint(picked: picked))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = item.id
            focused = true
        }
        .contextMenu {
            let entries = menu(for: item)
            if !entries.isEmpty {
                MenuEntries(items: entries)
            } else {
                fallbackMenu(item)
            }
        }
        // Dragged onto a folder in the sidebar, it goes into it. Other apps get its title as text.
        .draggable(LibraryDrag(item: item, title: LibraryRows.title(item)))
    }

    /// The row's right-click menu: the header's actions, then its "…" menu, in the header's order.
    private func menu(for item: SavedItem) -> [HeaderMenuItem] {
        let parts = header(item)
        // The header's Copy says "Copied" for a moment after use; a menu entry always says what it does.
        let actions = parts.actions.map { action -> HeaderMenuItem in
            var entry = action.asMenuItem
            if action.id == "copy" { entry.title = "Copy" }
            return entry
        }
        var more = parts.more
        if !actions.isEmpty, !more.isEmpty { more[0].dividerBefore = true }
        return actions + more
    }

    /// Pin, folders and Delete…, for a list given no header actions.
    @ViewBuilder private func fallbackMenu(_ item: SavedItem) -> some View {
        Button(item.starred ? "Unpin" : "Pin") { pin(item) }
        Menu("Move to Folder") {
            ForEach(folders) { folder in
                Button {
                    move(item, folder.id)
                } label: {
                    if item.folderID == folder.id { Label(folder.name, image: "chirp.check") } else { Text(folder.name) }
                }
            }
            if !folders.isEmpty { Divider() }
            Button("New Folder…") { newFolder(item) }
        }
        if item.folderID != nil { Button("Remove from Folder") { move(item, nil) } }
        Divider()
        Button("Delete…", role: .destructive) { askDelete(item) }
    }
}

/// A list row's tint: Ink 9% when picked, Ink 5% under the pointer, as `ItemRow` has.
private struct RowTint: ViewModifier {
    let picked: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(picked ? PageLayout.selected : hovering ? PageLayout.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hovering = $0 }
    }
}

extension UTType {
    /// A Library row dragged inside Chirp. Declared in Info.plist (`UTExportedTypeDeclarations`); no
    /// other app reads it.
    static let chirpLibraryItem = UTType(exportedAs: "com.jakeflavin.chirp.library-item")
}

/// What a dragged Library row carries: its item's id in Chirp's own type, for a folder in the sidebar,
/// and its title as plain text for any other app it is dropped on.
struct LibraryDrag: Codable, Sendable, Transferable {
    let id: Int64
    let title: String

    init(item: SavedItem, title: String) {
        self.id = item.id ?? -1
        self.title = title
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .chirpLibraryItem)
        ProxyRepresentation(exporting: \.title)
    }
}
