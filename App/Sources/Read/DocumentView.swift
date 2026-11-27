import AppKit
import ChirpCore
import ChirpML
import SwiftUI

/// A document open in the Library: where it came from and its title, which stay put; its summary in a
/// panel fixed above the text; the text laid out for reading, or the original; and one bar at the
/// bottom. Its header, under the title, holds the Reading view / Original switch, Copy, Export,
/// Summarize, and "…" for Pin, Move to Folder, Save as Audio and Delete.
struct DocumentDetail: View {
    @Environment(ReadController.self) private var reader
    @Environment(MeetingRecorder.self) private var recorder
    let item: SavedItem
    let folder: String?
    /// The actions the Library window gives every item.
    var header = ItemHeaderParts()

    /// What the document keeps beside its text.
    @State private var extra: DocumentExtra?
    @State private var layout = DocLayout()
    /// The document `layout` was made for. Until the layout of a newly picked document has been read,
    /// the one held is the last document's, and its ranges do not belong to this text.
    @State private var layoutFor: Int64?
    /// Its sentences, for when the reader is holding something else and cannot give them.
    @State private var ownSentences: [ReadingSentence] = []
    @State private var segments: [TranscriptSegment] = []
    @State private var loadedFor: String = ""

    /// True when the reader holds this document: the place, the marks and the summary come from it.
    private var live: Bool { reader.item?.id == item.id }
    /// The document as it is now: the reader's copy when it holds it (its place and summary move).
    private var current: SavedItem { live ? reader.item ?? item : item }
    private var sentences: [ReadingSentence] { live ? reader.sentences : ownSentences }
    /// A summary of this document is being written and has something to show yet: it fills in as it goes.
    private var writing: Bool { live && reader.summarizing && !(reader.summaryDraft ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DocumentHead(item: current, extra: extra, folder: folder, speakers: speakers, live: live, header: header, renameSpeakers: reloadSegments, refetched: {
                extra = item.id.flatMap { try? recorder.library.documentExtra(itemID: $0) } ?? extra
            })
                .padding(.leading, 30).padding(.trailing, 40).padding(.top, 16)
            if !current.summary.isEmpty || writing {
                SummaryPanel(item: current, collapsed: extra?.summaryCollapsed ?? false, draft: writing ? reader.summaryDraft : nil) { folded in
                    guard let id = item.id else { return }
                    try? recorder.library.setSummaryCollapsed(itemID: id, folded)
                    extra = (try? recorder.library.documentExtra(itemID: id)) ?? extra
                }
                .padding(.leading, 30).padding(.trailing, 40).padding(.top, 12)
            }
            if extra?.isTranscript == true {
                TranscriptDocument(item: current, segments: segments)
            } else if reader.showOriginal, let original = extra?.originalURL, FileManager.default.fileExists(atPath: original.path) {
                ZStack(alignment: .bottom) {
                    OriginalView(url: original, source: current.source).padding(.top, 12)
                    ReadingDock(item: current, live: live, sentences: sentences, away: .constant(false), goToPlace: {})
                        .padding(.horizontal, 20).padding(.bottom, 18)
                }
            } else {
                ReadingPage(item: current, extra: extra, layout: usableLayout, sentences: sentences, live: live)
                    // Under the summary panel the text starts a little lower, and stays out from under it.
                    .padding(.top, current.summary.isEmpty && !writing ? 0 : 8)
                    .clipped()
            }
        }
        .background(Color.paper)
        .onAppear(perform: load)
        .onChange(of: item.id) { load() }
        .onChange(of: item.updatedAt) { load() }
        .onChange(of: reader.version) { load() }
        .accessibilityIdentifier("document.detail")
    }

    /// The layout, only when it is this document's and every range in it lies inside this text.
    private var usableLayout: DocLayout {
        layoutFor == item.id && layout.fits(length: current.body.utf16.count) ? layout : DocLayout()
    }

    private var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    private func reloadSegments() {
        guard let id = item.id else { return }
        segments = (try? recorder.library.segments(itemID: id)) ?? []
    }

    /// Reads what the document keeps and lays its text out. Done again only when the text has changed.
    private func load() {
        guard let id = item.id else { return }
        let library = recorder.library
        extra = try? library.documentExtra(itemID: id)
        let body = current.body
        let key = "\(id)-\(body.utf16.count)-\(extra?.layout.count ?? 0)"
        if extra?.isTranscript == true { reloadSegments() }
        guard key != loadedFor else { return }
        loadedFor = key
        layoutFor = id
        let length = body.utf16.count
        if let kept = extra.flatMap({ DocLayout(json: $0.layout) }), kept.fits(length: length), !kept.blocks.isEmpty {
            layout = kept
        } else {
            // Saved before layouts were kept, or plain text: laid out from how its lines are written.
            layout = DocLayout.plain(body)
        }
        ownSentences = live ? [] : ReadingText.sentences(body)
    }
}

// MARK: - Head

/// The source line, the title and what can be done: they stay put while the text scrolls.
private struct DocumentHead: View {
    @Environment(ReadController.self) private var reader
    @Environment(MeetingRecorder.self) private var recorder
    let item: SavedItem
    let extra: DocumentExtra?
    let folder: String?
    let speakers: [String]
    let live: Bool
    let header: ItemHeaderParts
    let renameSpeakers: () -> Void
    /// Called when the original has been fetched again, so the page reads what is kept anew.
    let refetched: () -> Void
    @State private var naming = false
    @State private var fetching = false

    var body: some View {
        let source = DocumentRows.source(
            item, extra: extra, readSeconds: LibraryRows.measure(item).seconds, speakers: speakers.count, folder: folder)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(source.link == nil ? "chirp.file" : "chirp.link").font(.system(size: 11)).frame(width: 14)
                if let link = source.link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        HStack(spacing: 3) {
                            Text(source.linkTitle).underline(true, color: PageLayout.line).lineLimit(1)
                            Image("chirp.open").font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(link.absoluteString)
                    .accessibilityLabel("Open \(source.linkTitle) in the browser")
                    .accessibilityIdentifier("document.source")
                    if !source.rest.isEmpty { Text("· " + source.rest).lineLimit(1) }
                } else {
                    Text(source.rest).lineLimit(1).accessibilityIdentifier("document.source")
                }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.quiet)
            Text(item.title).font(.detailTitle).tracking(-0.2).lineLimit(2).padding(.top, 5)
                .accessibilityAddTraits(.isHeader)
            ItemActionBar(actions: parts.actions, more: parts.more) {
                if extra?.isTranscript != true { viewSwitch }
            }
            .padding(.top, 10)
            if reader.summarizing, live {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(reader.summaryProgress.map { "Summarizing part \($0.part) of \($0.of)" } ?? "Writing a summary").font(.system(size: 12.5)).foregroundStyle(Color.quiet)
                }
                .frame(height: 26).padding(.top, 6)
            }
            // A web page saved before originals were kept, whose address is known.
            if OriginalFetch.canFetch(item, extra: extra) {
                HeaderOffer(lead: "No copy of this page was kept", rest: " when it was saved.", button: fetching ? "Fetching…" : "Fetch the original again",
                            symbol: "chirp.getOriginal", busy: fetching, action: fetchOriginal)
                    .padding(.top, 12)
                    .accessibilityIdentifier("document.fetchOriginal")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(PageLayout.line).frame(height: 1) }
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            SpeakerNames(itemID: item.id ?? -1, speakers: speakers) {
                naming = false
                renameSpeakers()
            }
        }
    }

    /// Reading view | Original. With no original kept, Original stays in its place, disabled, and says why.
    private var viewSwitch: some View {
        let kept = OriginalFetch.hasOriginal(extra)
        return ViewSwitch(
            label: "View",
            options: [.init(title: "Reading view"), .init(title: "Original", unavailable: kept ? nil : "No original was kept for this document.")],
            selection: Binding(get: { kept && reader.showOriginal ? 1 : 0 }, set: { reader.showOriginal = $0 == 1 }),
            identifier: "document.view")
    }

    /// Copy and Export, then Summarize until there is a summary (then the panel holds it); a transcribed
    /// link names its speakers. "…" adds Save as Audio before Delete.
    private var parts: ItemHeaderParts {
        var extraActions: [HeaderAction] = []
        if item.summary.isEmpty, Features.on(.summarize) {
            extraActions.append(HeaderAction(id: "summarize", title: "Summarize", symbol: "chirp.summarize", help: "Write a short summary of it", disabled: reader.summarizing) { summarize() })
        }
        if extra?.isTranscript == true, speakers.count > 1 {
            extraActions.append(HeaderAction(id: "speakers", title: "Name the speakers", symbol: "chirp.edit", help: "Give each voice a name") { naming = true })
        }
        var more: [HeaderMenuItem] = []
        if extra?.isTranscript != true, Features.on(.read) {
            more.append(HeaderMenuItem(id: "saveAudio", title: "Save as Audio…", symbol: "chirp.voiceNote", disabled: reader.exportProgress != nil, run: saveAudio))
        }
        return header.adding(actions: extraActions, more: more)
    }

    /// Fetches the page again and keeps it as the original; the reading view does not change.
    private func fetchOriginal() {
        guard !fetching else { return }
        fetching = true
        Task {
            let problem = await OriginalFetch.fetch(item, library: recorder.library)
            fetching = false
            if let problem { Toast.show(problem, seconds: 5) } else { refetched() }
        }
    }

    private func summarize() {
        Task {
            if !live { reader.open(item) }
            await reader.summarize()
        }
    }

    /// Asks where to save, then reads the whole document into an audio file there.
    private func saveAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = item.title + ".m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !live { reader.open(item) }
        reader.exportAudio(to: url)
    }
}

/// Gives the speakers of a transcribed link their names.
private struct SpeakerNames: View {
    @Environment(MeetingRecorder.self) private var recorder
    let itemID: Int64
    let speakers: [String]
    let done: () -> Void
    @State private var names: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name the speakers").font(.system(size: 13, weight: .semibold))
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                TextField(speaker, text: Binding(get: { names.indices.contains(index) ? names[index] : "" }, set: { if names.indices.contains(index) { names[index] = $0 } }))
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .accessibilityLabel("Name for \(speaker)")
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    for (index, speaker) in speakers.enumerated() {
                        let name = names[index].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name != speaker { try? recorder.library.renameSpeaker(itemID: itemID, from: speaker, to: name) }
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { names = speakers.map { _ in "" } }
    }
}

// MARK: - Summary panel

/// The summary, in a panel fixed above the text: it stays in view while the document scrolls, folds
/// to one line, and is left folded or open as it was.
private struct SummaryPanel: View {
    @Environment(ReadController.self) private var reader
    let item: SavedItem
    let collapsed: Bool
    /// The summary so far while one is being written: shown in place of the kept one, without the buttons, so Copy
    /// and Read aloud only ever take a finished summary.
    var draft: String? = nil
    let fold: (Bool) -> Void
    @State private var copied = false
    private var text: String { draft ?? item.summary }
    /// The panel's width: under 520 points its buttons show only their icons, each with a tooltip.
    @State private var width: CGFloat = 800
    private var iconsOnly: Bool { width < 520 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    fold(!collapsed)
                } label: {
                    Image(collapsed ? "chirp.chevron" : "chirp.disclose").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.quiet).frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Open the summary" : "Collapse the summary")
                .accessibilityIdentifier("summary.fold")
                Text("Summary").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                if collapsed {
                    Text(DocumentRows.summaryLine(text)).font(.system(size: 13)).foregroundStyle(Color.quiet)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 8)
                }
                if draft == nil {
                panelButton(copied ? "Copied" : "Copy", symbol: copied ? "chirp.check" : "chirp.copy") {
                    RichCopy.copy(markdown: item.summary)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .accessibilityIdentifier("summary.copy")
                if !collapsed {
                    if Features.on(.read) {
                        panelButton("Read aloud", symbol: "chirp.read") {
                            reader.readOnce(DocumentImporter.Imported(title: "Summary", text: MarkdownLines.plain(item.summary), source: "Summary"))
                        }
                    }
                    if Features.on(.summarize) {
                        panelButton("Summarize again", symbol: "chirp.again") {
                            Task {
                                if reader.item?.id != item.id { reader.open(item) }
                                await reader.summarize()
                            }
                        }
                        .disabled(reader.summarizing)
                    }
                }
                }
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: 38)
            if !collapsed {
                // A long summary scrolls inside the panel, so the text under it keeps its room.
                ScrollView {
                    MarkdownText(text, size: 13.5).textSelection(.enabled)
                        .padding(.leading, 32).padding(.trailing, 18).padding(.bottom, 12)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("read.summary")
            }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary")
    }

    /// A button in the panel's head: its icon and name, or in a narrow panel its icon with the name as a tooltip.
    @ViewBuilder private func panelButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        if iconsOnly {
            IconButton(symbol: symbol, label: title, size: 26, action: action)
        } else {
            ActButton(title: title, symbol: symbol, action: action)
        }
    }
}

// MARK: - Reading view

/// Marks the sentence reading stopped at, so the place can be found in the laid-out lines.
private struct LeftOffAttribute: TextAttribute {}

/// Marks the word "Say it as" is open on, so the question can be put under it.
private struct SayItAsAttribute: TextAttribute {}

/// The document's text laid out for reading: headings, paragraphs, lists, quotes, tables and pictures,
/// with the sentence and word being read marked, and the bar floating at its foot.
private struct ReadingPage: View {
    @Environment(ReadController.self) private var reader
    @AppStorage(ReadingChoices.marksKey) private var marks = true
    @AppStorage(ReadingChoices.followKey) private var follow = true
    let item: SavedItem
    let extra: DocumentExtra?
    let layout: DocLayout
    let sentences: [ReadingSentence]
    let live: Bool
    /// True once the user has scrolled away from the sentence being read; following waits until they scroll back.
    @State private var away = false
    /// Bumped to bring the place back into view (Continue).
    @State private var toPlace = 0

    /// The sentence reading is at, or was left at.
    private var index: Int {
        if live { return reader.index }
        return sentences.lastIndex { $0.offset <= item.position } ?? 0
    }
    private var playing: Bool { live && (reader.isPlaying || reader.wordRange != nil) }
    /// The word "Say it as" is open on in this reader, as a place in the document's text.
    private var sayRange: NSRange? { live && reader.sayItAs?.place == .reader ? reader.sayItAs?.range : nil }
    /// True when there is a place to come back to that is not the start, and nothing is being read.
    private var leftOff: Bool { !playing && index > 0 && sentences.indices.contains(index) }

    var body: some View {
        let ns = item.body as NSString
        let rows = Self.rows(layout.blocks)
        let place = sentences.indices.contains(index) ? sentences[index].offset : -1
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, ns: ns)
                                .frame(maxWidth: 572, alignment: .leading)
                                .padding(.top, row.gap)
                                .id(row.id)
                                .onScrollVisibilityChange(threshold: 0.5) { visible in
                                    // Scrolling back to the sentence being read starts the following again.
                                    if visible, row.contains(place) { away = false }
                                }
                                // "Say it as" hangs below its word, over the rows after this one.
                                .zIndex(sayRange.map { row.contains($0.location) } ?? false ? 1 : 0)
                        }
                    }
                    // Room at the foot for the bar that floats over the text.
                    .padding(.leading, 30).padding(.trailing, 40).padding(.top, 16).padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting, reader.isPlaying { away = true }
                }
                .environment(\.openURL, OpenURLAction { url in
                    // The word being spoken is a link to "Say it as".
                    if url.scheme == "chirp-word" {
                        let parts = (url.host ?? "").split(separator: "-").compactMap { Int($0) }
                        if parts.count == 2 { reader.openSayItAs(place: .reader, word: NSRange(location: parts[0], length: parts[1])) }
                        return .handled
                    }
                    // Each sentence is a link back to itself: clicking jumps playback there. A real link opens.
                    guard url.scheme == "chirp-sentence" else { return .systemAction }
                    if let i = Int(url.host ?? "") {
                        away = false
                        if !live { reader.open(item) }
                        reader.jump(to: i)
                    }
                    return .handled
                })
                .onChange(of: reader.index) { _, _ in
                    guard live, follow, !away, let row = rows.first(where: { $0.contains(place) }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(row.id, anchor: .center) }
                }
                .onChange(of: toPlace) {
                    guard let row = rows.first(where: { $0.contains(place) }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(row.id, anchor: .center) }
                }
                .onChange(of: "\(item.id ?? 0)-\(rows.count)", initial: true) { _, _ in
                    away = false
                    // A document opens at the place it was left, not at its top. Done a moment later,
                    // once the text has been laid out, and without the sliding.
                    guard index > 0, let row = rows.first(where: { $0.contains(place) }) else { return }
                    let target = row.id
                    Task { @MainActor in proxy.scrollTo(target, anchor: .center) }
                }
            }
            VStack(spacing: 8) {
                if let progress = reader.exportProgress, live {
                    HStack(spacing: 8) {
                        ProgressView(value: progress).frame(width: 140)
                        Text("Saving audio, \(Int(progress * 100))%").font(.system(size: 12.5)).monospacedDigit()
                        ActButton(title: "Cancel") { reader.cancelExport() }
                    }
                    .padding(.horizontal, 14).frame(height: 36)
                    .chirpGlassCapsule()
                }
                ReadingDock(item: item, live: live, sentences: sentences, away: $away) { toPlace += 1 }
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
    }

    // MARK: Rows

    /// What is drawn as one piece: a block, or the rows of one table together.
    struct Row: Identifiable {
        var blocks: [DocLayout.Block]
        var id: String { blocks[0].id }
        var kind: DocLayout.Block.Kind { blocks[0].kind }
        /// The space above it, set by what it is and what is over it.
        var gap: CGFloat = 0
        func contains(_ offset: Int) -> Bool {
            guard offset >= 0, let last = blocks.last else { return false }
            return offset >= blocks[0].start && offset <= last.end
        }
    }

    static func rows(_ blocks: [DocLayout.Block]) -> [Row] {
        var out: [Row] = []
        for block in blocks {
            let table = block.kind == .tableHead || block.kind == .tableRow
            if table, let last = out.indices.last, out[last].kind == .tableHead || out[last].kind == .tableRow {
                out[last].blocks.append(block)
                continue
            }
            var row = Row(blocks: [block])
            let above = out.last?.kind
            switch block.kind {
            case .heading: row.gap = above == nil ? 2 : 24
            case .subheading: row.gap = above == nil ? 2 : 20
            case .bullet, .numbered: row.gap = above == .bullet || above == .numbered ? 6 : (above == .heading || above == .subheading ? 8 : 14)
            case .quote, .image: row.gap = above == nil ? 0 : 18
            default: row.gap = above == nil ? 0 : (above == .heading ? 8 : above == .subheading ? 4 : above == .image || above == .quote ? 18 : 14)
            }
            out.append(row)
        }
        return out
    }

    @ViewBuilder private func rowView(_ row: Row, ns: NSString) -> some View {
        let block = row.blocks[0]
        switch block.kind {
        case .heading:
            words(block, ns).font(.system(size: 20, weight: .bold)).tracking(-0.3).lineSpacing(3).accessibilityAddTraits(.isHeader)
        case .subheading:
            words(block, ns).font(.system(size: 16, weight: .semibold)).lineSpacing(3).accessibilityAddTraits(.isHeader)
        case .paragraph:
            words(block, ns).font(.reading).lineSpacing(8)
        case .bullet, .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Group {
                    if block.kind == .bullet {
                        Circle().fill(Color.quiet.opacity(0.8)).frame(width: 5, height: 5).offset(y: -4)
                    } else {
                        Text(block.marker ?? "").font(.system(size: 14)).monospacedDigit().foregroundStyle(Color.quiet)
                    }
                }
                .frame(width: block.kind == .bullet ? 22 : 30, alignment: block.kind == .bullet ? .center : .leading)
                words(block, ns).font(.reading).lineSpacing(8)
            }
        case .quote:
            words(block, ns).font(.system(size: 17.5, weight: .medium)).lineSpacing(7)
                .padding(.leading, 18).padding(.vertical, 1)
                .overlay(alignment: .leading) { Rectangle().fill(Color.ink.opacity(0.28)).frame(width: 2) }
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(ns.substring(with: NSRange(location: block.start, length: block.length)))
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(3).fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .image:
            DocumentPicture(url: block.image.flatMap { name in extra?.folderURL?.appendingPathComponent(name) }, caption: block.caption)
        case .tableHead, .tableRow:
            table(row.blocks, ns)
        }
    }

    /// A table: a heading row in small grey type over a rule, then rows with a line under each. The row
    /// being read is tinted, and the cell being read more strongly.
    private func table(_ blocks: [DocLayout.Block], _ ns: NSString) -> some View {
        let active = marks && playing
        let now = sentences.indices.contains(index) ? sentences[index] : nil
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(blocks) { block in
                let head = block.kind == .tableHead
                let rowNow = active && (now.map { $0.offset >= block.start && $0.offset < block.end } ?? false)
                GridRow {
                    ForEach(Array((block.cells ?? []).enumerated()), id: \.offset) { _, cell in
                        let cellNow = rowNow && (now.map { $0.offset >= cell.start && $0.offset < cell.start + max(cell.length, 1) } ?? false)
                        Text(cellText(cell, block, ns, head: head))
                            .font(.system(size: head ? 12.5 : 14.5, weight: head ? .semibold : .regular)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, head ? 6 : 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cellNow ? Color.amber.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                .background(rowNow ? Color.amber.opacity(0.13) : .clear)
                Rectangle().fill(head ? Color.ink.opacity(0.3) : PageLayout.line).frame(height: 1)
            }
        }
        .padding(.top, 6)
    }

    /// A cell's words: a click on them jumps reading there.
    private func cellText(_ cell: DocLayout.Cell, _ block: DocLayout.Block, _ ns: NSString, head: Bool) -> AttributedString {
        guard cell.length > 0 else { return AttributedString("") }
        var a = AttributedString(ns.substring(with: NSRange(location: cell.start, length: cell.length)))
        let range = DocLayout.sentences(in: cell.start, length: cell.length, of: sentences)
        if let first = range.first { a.link = URL(string: "chirp-sentence://\(first)") }
        // Said outright: a link is otherwise drawn in the link colour.
        a.foregroundColor = head ? Color.quiet : Color.ink
        return a
    }

    /// A block's words as styled text. Each sentence is a link that jumps reading to it; the sentence
    /// being read is tinted and the word being spoken tinted more strongly; the sentence reading was
    /// left at is tinted grey, with a marker in the margin beside it.
    private func words(_ block: DocLayout.Block, _ ns: NSString) -> some View {
        let range = DocLayout.sentences(in: block.start, length: block.length, of: sentences)
        let stop = leftOff && range.contains(index) ? index : nil
        let pieces = pieces(block, ns, range: range)
        // The sentence left at is a piece of its own, so its line can be found for the marker.
        var text = Text("")
        var asking = false
        for piece in pieces {
            if piece.asked {
                asking = true
                text = text + Text(piece.text).customAttribute(SayItAsAttribute())
            } else {
                text = text + (piece.sentence == stop && stop != nil ? Text(piece.text).customAttribute(LeftOffAttribute()) : Text(piece.text))
            }
        }
        return text
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if stop != nil || asking {
                    GeometryReader { proxy in
                        if stop != nil, let y = Self.markerY(layouts, in: proxy) {
                            Image("chirp.bookmarkFill").font(.system(size: 13)).foregroundStyle(Color.amber)
                                // Amber alone is too faint on Paper: a thin On Amber edge holds its shape.
                                .shadow(color: Color.onAmber.opacity(0.35), radius: 0, x: 0.5, y: 0)
                                .shadow(color: Color.onAmber.opacity(0.35), radius: 0, x: -0.5, y: 0)
                                .shadow(color: Color.onAmber.opacity(0.35), radius: 0, x: 0, y: 0.5)
                                .shadow(color: Color.onAmber.opacity(0.35), radius: 0, x: 0, y: -0.5)
                                .frame(width: 13, height: 18)
                                .position(x: -16.5, y: y)
                                .accessibilityLabel("You stopped here")
                                .accessibilityIdentifier("read.leftOff")
                        }
                        if asking, let box = Self.askedBox(layouts, in: proxy) {
                            // Under the word, kept inside the column.
                            SayItAsPopover()
                                .frame(width: SayItAsPopover.width)
                                .fixedSize()
                                .offset(x: max(0, min(box.minX - 12, proxy.size.width - SayItAsPopover.width)), y: box.maxY + 8)
                        }
                    }
                }
            }
    }

    /// The box of the word "Say it as" is open on.
    private static func askedBox(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> CGRect? {
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line where run[SayItAsAttribute.self] != nil {
                    return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                }
            }
        }
        return nil
    }

    /// The middle of the first line holding the sentence reading was left at.
    private static func markerY(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> CGFloat? {
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line where run[LeftOffAttribute.self] != nil {
                    return origin.y + line.typographicBounds.rect.midY
                }
            }
        }
        return nil
    }

    private struct Piece {
        var text: AttributedString
        var sentence: Int?
        /// The word "Say it as" is open on.
        var asked = false
    }

    /// Cuts a block's words wherever a sentence, a style or the spoken word starts or ends, and styles each piece.
    private func pieces(_ block: DocLayout.Block, _ ns: NSString, range: Range<Int>) -> [Piece] {
        let start = block.start, end = block.end
        guard end > start, end <= ns.length else { return [] }
        var cuts: Set<Int> = [start, end]
        func cut(_ at: Int) { if at > start, at < end { cuts.insert(at) } }
        for i in range {
            cut(sentences[i].offset)
            cut(sentences[i].offset + sentences[i].length)
        }
        for span in block.spans {
            cut(span.start)
            cut(span.start + span.length)
        }
        let active = marks && playing
        let word = active ? reader.wordRange : nil
        if let word {
            cut(word.location)
            cut(NSMaxRange(word))
        }
        let asked = sayRange
        if let asked {
            cut(asked.location)
            cut(NSMaxRange(asked))
        }
        let stop = leftOff ? index : nil
        let sorted = cuts.sorted()
        var out: [Piece] = []
        var at = range.lowerBound
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            var text = AttributedString(ns.substring(with: NSRange(location: a, length: b - a)))
            text.foregroundColor = Color.ink
            // The sentence this piece is in.
            while at < range.upperBound, sentences[at].offset + sentences[at].length <= a { at += 1 }
            let sentence = at < range.upperBound && sentences[at].offset <= a ? at : nil
            if let sentence { text.link = URL(string: "chirp-sentence://\(sentence)") }
            for span in block.spans where span.start <= a && span.start + span.length >= b {
                switch span.style {
                case .bold: text.inlinePresentationIntent = (text.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                case .italic: text.inlinePresentationIntent = (text.inlinePresentationIntent ?? []).union(.emphasized)
                case .code: text.inlinePresentationIntent = (text.inlinePresentationIntent ?? []).union(.code)
                case .link:
                    if let url = span.url.flatMap(URL.init(string:)) {
                        text.link = url
                        text.foregroundColor = Color.grammar
                        text.underlineStyle = Text.LineStyle(pattern: .solid, color: Color.grammar.opacity(0.4))
                    }
                }
            }
            if let sentence, active, sentence == index {
                text.backgroundColor = Color.amber.opacity(0.24)
                if let word, word.location <= a, NSMaxRange(word) >= b {
                    text.backgroundColor = Color.amber.opacity(0.55)
                    // Clicking the word just spoken asks how it should sound.
                    text.link = URL(string: "chirp-word://\(word.location)-\(word.length)")
                }
            } else if let sentence, sentence == stop {
                text.backgroundColor = Color.ink.opacity(0.07)
            }
            var piece = Piece(text: text, sentence: sentence)
            if let asked, asked.location <= a, NSMaxRange(asked) >= b {
                piece.asked = true
                piece.text.backgroundColor = Color.amber.opacity(0.55)
            }
            out.append(piece)
        }
        return out
    }
}

/// A picture of the document, with the words under it.
private struct DocumentPicture: View {
    let url: URL?
    let caption: String?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(572, image.size.width), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(caption ?? "Picture")
            }
            if let caption, !caption.isEmpty, image != nil {
                Text(caption).font(.system(size: 12.5)).foregroundStyle(Color.quiet).lineSpacing(2)
            }
        }
        .padding(.bottom, image == nil ? 0 : 2)
        .task(id: url) {
            // Read off the main thread: a book has many, and some are large.
            guard let url else { return }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

// MARK: - The bar

/// One bar: back a sentence, play or pause (or Continue, at a place that was left), forward, how far
/// through, the time left, and the voice and speed. In a narrow window it drops the voice's name, then
/// Continue's word, then the time, before the line shortens, so nothing
/// is squeezed and the bar never pushes the page past the window's edge.
struct ReadingDock: View {
    @Environment(ReadController.self) private var reader
    @Environment(ModelCenter.self) private var models
    let item: SavedItem
    let live: Bool
    let sentences: [ReadingSentence]
    @Binding var away: Bool
    let goToPlace: () -> Void

    private var index: Int { live ? reader.index : (sentences.lastIndex { $0.offset <= item.position } ?? 0) }
    private var playing: Bool { live && reader.isPlaying }
    /// True when reading stopped part way: the bar offers to carry on from there.
    private var canContinue: Bool { !playing && index > 0 && !(live && reader.isPreparing) }

    var body: some View {
        if Features.on(.read) {
            ViewThatFits(in: .horizontal) {
                row(scrubber: 130, time: true, voiceName: true, continueWord: true, sayItAsWord: true)
                row(scrubber: 120, time: true, voiceName: false, continueWord: true, sayItAsWord: true)
                row(scrubber: 100, time: true, voiceName: false, continueWord: false, sayItAsWord: true)
                row(scrubber: 96, time: false, voiceName: false, continueWord: false, sayItAsWord: true)
                row(scrubber: 60, time: false, voiceName: false, continueWord: false, sayItAsWord: false)
                row(scrubber: 36, time: false, voiceName: false, continueWord: false, sayItAsWord: false)
            }
            // Space plays or pauses (or continues), ← and → move a sentence; not while a field is typed in.
            .playbackKeys { key in
                switch key {
                case .back: back()
                case .forward: forward()
                case .playPause: if canContinue { carryOn() } else { playPause() }
                }
            }
        }
    }

    /// Makes this the document the reader holds, when it was holding something else.
    private func take() { if !live { reader.open(item) } }

    private func back() {
        take()
        reader.skip(-1)
    }

    private func forward() {
        take()
        reader.skip(1)
    }

    /// Continue: back to the place that was left, and on from there.
    private func carryOn() {
        take()
        away = false
        goToPlace()
        reader.play()
    }

    private func playPause() {
        take()
        away = false
        reader.toggle()
    }

    private func row(scrubber: CGFloat, time: Bool, voiceName: Bool, continueWord: Bool, sayItAsWord: Bool) -> some View {
        @Bindable var reader = reader
        return HStack(spacing: 6) {
            IconButton(symbol: "chirp.back", label: "Back a sentence", size: 34, action: back)
            if canContinue {
                Button(action: carryOn) {
                    HStack(spacing: 6) {
                        Image("chirp.play").font(.system(size: 12))
                        if continueWord { Text("Continue").font(.system(size: 13, weight: .semibold)) }
                    }
                    .foregroundStyle(Color.onAmber)
                    .padding(.leading, continueWord ? 10 : 0).padding(.trailing, continueWord ? 14 : 0)
                    .frame(width: continueWord ? nil : 34, height: 34)
                    .background(Color.amber, in: Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityLabel("Continue")
                .buttonStyle(.plain)
                .help("Carry on from where you stopped")
                .accessibilityIdentifier("read.continue")
            } else {
                IconButton(symbol: playing ? "chirp.pause" : "chirp.play", label: playing ? "Pause" : "Play", size: 34, active: playing, action: playPause)
                    .accessibilityIdentifier("read.play")
            }
            IconButton(symbol: "chirp.forward", label: "Forward a sentence", size: 34, action: forward)
            Scrubber(value: sentences.isEmpty ? 0 : Double(index) / Double(sentences.count)) { fraction in
                guard !sentences.isEmpty else { return }
                take()
                away = false
                reader.jump(to: min(sentences.count - 1, Int(fraction * Double(sentences.count))))
            }
            .frame(width: scrubber)
            .accessibilityLabel("Progress through the document")
            .accessibilityValue("\(sentences.isEmpty ? 0 : Int(Double(index) / Double(sentences.count) * 100)) percent")
            if time {
                Text(status).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color.quiet).lineLimit(1).fixedSize()
                    .padding(.leading, 2)
                    .accessibilityIdentifier("read.status")
            }
            Menu {
                Picker("Voice", selection: $reader.voiceID) {
                    ForEach(Voice.voices) { v in Text("\(v.name) · \(v.accent)").tag(v.id) }
                }
                Picker("Speed", selection: $reader.speed) {
                    ForEach(ReadController.speeds, id: \.self) { s in Text(s.speedLabel).tag(s) }
                }
            } label: {
                Text(voiceName ? "\(Voice.voices.first { $0.id == reader.voiceID }?.name ?? "Voice") · \(reader.speed.speedLabel)" : reader.speed.speedLabel)
                    .font(.system(size: 12.5)).foregroundStyle(Color.ink.opacity(0.9))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(GlassFill.row, in: Capsule())
                    .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.leading, 4)
            .accessibilityLabel("Voice and speed")
            // A name read wrong is fixed where it is heard: reading pauses and the question sits on the word.
            let asking = live && reader.sayItAs?.place == .reader
            Button {
                take()
                if asking { reader.closeSayItAs() } else { reader.openSayItAs(place: .reader) }
            } label: {
                Group {
                    if sayItAsWord { Text("Say it as").font(.system(size: 12.5, weight: asking ? .semibold : .regular)) } else { Image("chirp.sayAs").font(.system(size: 12, weight: .medium)) }
                }
                    .foregroundStyle(asking ? Color.onAmber : Color.ink.opacity(0.9))
                    .padding(.horizontal, sayItAsWord ? 10 : 7).frame(height: 26)
                    .background(asking ? AnyShapeStyle(Color.amber) : AnyShapeStyle(GlassFill.row), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).fixedSize()
            .disabled(sentences.isEmpty)
            .help("How a word just spoken should sound")
            .accessibilityLabel("Say it as")
            .accessibilityIdentifier("read.sayItAs")
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 46)
        .chirpGlassCapsule()
    }

    /// The words on the bar: what Chirp is busy with, or the time left.
    private var status: String {
        if live {
            if case .downloading(let f) = models.state(.voice) { return "Downloading the voice, \(Int(f * 100))%" }
            if reader.isPreparing { return "Getting the voice ready" }
            return "\(LibraryRows.length(reader.timeLeft)) left"
        }
        let total = LibraryRows.measure(item).seconds
        let left = total * (1 - Double(DocumentRows.heard(item)) / 100)
        return index > 0 ? "\(LibraryRows.length(left / reader.speed)) left" : LibraryRows.length(total / reader.speed)
    }
}

// MARK: - Transcript of a link

/// A transcribed link or file: its lines with their times (and who spoke, when several did), and one
/// bar to play the sound that was kept. A click on a line plays from there.
private struct TranscriptDocument: View {
    let item: SavedItem
    let segments: [TranscriptSegment]
    @State private var playback = AudioPlayback.shared
    @State private var speed: Double = 1

    private var audio: URL? { item.audioFile.map { ChirpStore.audioDirectory.appendingPathComponent($0) } }
    private var mine: Bool { audio != nil && playback.current == audio }
    /// The line being played.
    private var now: Int? {
        guard mine, playback.time > 0 || playback.isPlaying else { return nil }
        return segments.lastIndex { $0.start <= playback.time + 0.05 }
    }

    var body: some View {
        let speakers = Set(segments.map(\.speaker))
        let first = segments.first?.speaker
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(line.start.clock).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet.opacity(0.85))
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    if speakers.count > 1 {
                                        // The first voice in ink, the others in the colour for other people.
                                        Text(line.speaker).font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(line.speaker == first ? Color.ink : Color.grammar)
                                    }
                                    Text(line.text).font(.system(size: 14.5)).lineSpacing(5).foregroundStyle(Color.ink)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(index == now ? Color.amber.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { if let audio { playback.play(audio, at: line.start) } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .id(index)
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.leading, 20).padding(.trailing, 40).padding(.top, 10).padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: now) { _, line in
                    if let line, playback.isPlaying { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) } }
                }
            }
            if let audio { dock(audio).padding(.horizontal, 20).padding(.bottom, 18) }
        }
        .accessibilityIdentifier("document.transcript")
    }

    /// Back and forward fifteen seconds, play or pause, the place, the time and the speed.
    private func dock(_ audio: URL) -> some View {
        let total = mine && playback.duration > 0 ? playback.duration : item.duration
        let time = mine ? playback.time : 0
        return HStack(spacing: 6) {
            IconButton(symbol: "chirp.back15", label: "Back 15 seconds", size: 34) { playback.seek(audio, to: time - 15) }
            IconButton(symbol: mine && playback.isPlaying ? "chirp.pause" : "chirp.play", label: mine && playback.isPlaying ? "Pause" : "Play", size: 34, active: mine && playback.isPlaying) {
                playback.playPause(audio)
                playback.setRate(speed)
            }
            .accessibilityIdentifier("transcript.play")
            IconButton(symbol: "chirp.fwd15", label: "Forward 15 seconds", size: 34) { playback.seek(audio, to: time + 15) }
            Scrubber(value: total > 0 ? time / total : 0) { fraction in playback.seek(audio, to: fraction * total) }
                .frame(width: 180)
                .accessibilityLabel("Place in the recording")
                .accessibilityValue("\(time.clock) of \(total.clock)")
            Text("\(time.clock) / \(total.clock)").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color.quiet).fixedSize()
                .padding(.leading, 2)
            Menu {
                Picker("Speed", selection: $speed) {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { s in Text(s.speedLabel).tag(s) }
                }
            } label: {
                Text(speed.speedLabel).font(.system(size: 12.5)).foregroundStyle(Color.ink.opacity(0.9))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(GlassFill.row, in: Capsule())
                    .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.leading, 4)
            .accessibilityLabel("Speed")
            .onChange(of: speed) { playback.setRate(speed) }
            // The speed is this document's: what is played next elsewhere is at its own.
            .onDisappear { playback.setRate(1) }
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 46)
        .chirpGlassCapsule()
        // Space plays or pauses, ← and → move 15 seconds; not while a field is typed in.
        .playbackKeys { key in
            let now = mine ? playback.time : 0
            switch key {
            case .back: playback.seek(audio, to: now - 15)
            case .forward: playback.seek(audio, to: now + 15)
            case .playPause:
                playback.playPause(audio)
                playback.setRate(speed)
            }
        }
    }
}

// MARK: - Empty pages

/// An empty page: the bird, one line, and the one button that fills the page. The
/// bird hops in once when the page opens, then sits. It is never on a page that has content.
struct EmptyPage<Action: View>: View {
    /// What the bird does once it has landed.
    enum Look {
        case ahead
        /// Down at the empty space where items go (a new folder).
        case down
        /// Left and right once (a search that found nothing).
        case around
    }

    let title: String
    let line: String
    var look = Look.ahead
    @ViewBuilder var action: () -> Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var gaze = CGPoint.zero

    init(_ title: String, line: String, look: Look = .ahead, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.title = title
        self.line = line
        self.look = look
        self.action = action
    }

    var body: some View {
        VStack(spacing: 4) {
            Bird(mood: .idle, size: 72, gaze: gaze).frame(width: 72, height: 72).accessibilityHidden(true)
                .offset(y: landed || reduceMotion ? 0 : -18)
                .opacity(landed || reduceMotion ? 1 : 0)
                .padding(.bottom, 8)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            Text(line).font(.system(size: 13)).foregroundStyle(Color.quiet).multilineTextAlignment(.center).frame(maxWidth: 360)
            action().padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .task {
            guard !reduceMotion else {
                if look == .down { gaze = CGPoint(x: 0, y: 2) }
                return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { landed = true }
            try? await Task.sleep(for: .milliseconds(500))
            switch look {
            case .ahead: break
            case .down: gaze = CGPoint(x: -0.6, y: 2)
            case .around:
                gaze = CGPoint(x: -2, y: 0)
                try? await Task.sleep(for: .milliseconds(450))
                gaze = CGPoint(x: 2, y: 0)
                try? await Task.sleep(for: .milliseconds(450))
                gaze = .zero
            }
        }
    }
}

/// The one amber button of an empty page.
struct EmptyPageButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.onAmber)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Color.amber, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("empty.action")
    }
}

// MARK: - Copying

/// Puts text on the clipboard as rich text (headings, lists, bold, links) with its Markdown as the
/// plain form, so it pastes with its shape into Mail or Notes and as Markdown into a plain editor.
@MainActor
enum RichCopy {
    static func copy(markdown: String, to board: NSPasteboard = .general) {
        let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, Helvetica, sans-serif; font-size: 13px\">" + RichText.html(fromMarkdown: markdown) + "</body></html>"
        board.clearContents()
        if let data = html.data(using: .utf8) {
            board.setData(data, forType: .html)
            // Rich text made from the same HTML, for apps that take that and not HTML.
            if let attributed = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            {
                board.setData(rtf, forType: .rtf)
            }
        }
        board.setString(markdown, forType: .string)
    }
}

/// "Say it as" in the Library's reader: the word, a field for how it should sound, Preview, Cancel and
/// Save to Dictionary. It sits under the word; reading is paused while it is open.
private struct SayItAsPopover: View {
    @Environment(ReadController.self) private var reader
    @FocusState private var typing: Bool
    static let width: CGFloat = 380

    var body: some View {
        let offer = reader.sayItAs
        VStack(alignment: .leading, spacing: 0) {
            // The words to choose from, the picked one in amber.
            HStack(spacing: 6) {
                ForEach(offer?.words ?? [], id: \.self) { word in
                    let picked = word == offer?.picked
                    Button { reader.pickSayItAs(word) } label: {
                        Text(word).font(.system(size: 12.5, weight: picked ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(picked ? Color.onAmber : Color.ink)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(picked ? Color.amber : Color.ink.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(word)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Which words")
            Text("Say it as").font(.system(size: 12)).foregroundStyle(Color.quiet).padding(.top, 10).padding(.bottom, 4)
            TextField("", text: Binding(get: { reader.sayItAs?.text ?? "" }, set: { reader.typeSayItAs($0) }))
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 9).frame(height: 30)
                .background(Color.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ink.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 9.5, style: .continuous).strokeBorder(Color.amber.opacity(typing ? 0.4 : 0), lineWidth: 3).padding(-1.5))
                .focused($typing)
                .onSubmit { reader.saveSayItAs() }
                .onExitCommand { reader.closeSayItAs() }
                .accessibilityLabel("Say \(offer?.picked ?? "it") as")
                .accessibilityIdentifier("sayItAs.field")
            if let problem = offer?.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color.caution).padding(.top, 6)
            }
            HStack(spacing: 6) {
                ActButton(title: "Preview", symbol: "chirp.read") { reader.previewSayItAs() }
                Spacer(minLength: 8)
                ActButton(title: "Cancel") { reader.closeSayItAs() }
                ActButton(title: "Save to Dictionary", primary: true) { reader.saveSayItAs() }
                    .accessibilityIdentifier("sayItAs.save")
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
        .background(Color.float, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.ink.opacity(0.13)))
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
        .onAppear { typing = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Say it as")
    }
}
