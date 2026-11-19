import AppKit
import ChirpCore
import SwiftUI
import UniformTypeIdentifiers

// The perch as a place to drop a file.
// While any file is being dragged anywhere the perch has an amber ring; with the file over it, it
// opens a little and says what a drop does, the bird looking at the file; once dropped, the file is
// shown with what it is and what can be done with it. Nothing is saved unless that is chosen.

/// Where a file being dragged is, as far as the perch is concerned.
struct FileDrag: Equatable {
    /// A file is being dragged somewhere on screen.
    var near = false
    /// It is over the perch.
    var over = false
    /// The first file of the drag, when macOS says which it is.
    var url: URL?

    /// The perch shows it will take the file.
    var lit: Bool { near || over }
}

/// Notices a file being dragged anywhere on screen, the way a drop shelf does: the system's drag
/// pasteboard changes when a drag begins, and holds file addresses when files are what is dragged.
/// Only the pointer is watched (no keys), and only the pasteboard's types and first address are read.
@MainActor
final class FileDragWatcher {
    private unowned let perch: PerchController
    private var monitors: [Any] = []
    /// The drag pasteboard's count when the button last went down: a drag that began since has moved it on.
    private var countAtDown = NSPasteboard(name: .drag).changeCount
    private var checked = false

    init(perch: PerchController) {
        self.perch = perch
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.countAtDown = NSPasteboard(name: .drag).changeCount
                self?.checked = false
            }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        monitors = [down, dragged, up].compactMap { $0 }
    }

    /// Looks once per drag, as soon as the pasteboard shows one has begun.
    private func look() {
        guard !checked else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != countAtDown else { return }
        checked = true
        guard board.types?.contains(.fileURL) == true else { return }
        let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        perch.fileDragBegan(url)
    }

    private func ended() {
        checked = false
        // The drop itself, when it lands on the perch, arrives a moment after the button comes up.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            perch.fileDrag = FileDrag()
        }
    }
}

extension PerchController {
    /// A file drag began somewhere. The perch lights up only for a file it can do something with.
    func fileDragBegan(_ url: URL?) {
        if let url, !Features.shared.set.takesDrop(audio: url.isAudioOrVideo) { return }
        guard url != nil || Features.shared.set.takesDrop(audio: false) || Features.shared.set.takesDrop(audio: true) else { return }
        guard presence != .hidden, !hiddenNow else { return }
        fileDrag.near = true
        fileDrag.url = url
    }

    /// What a drop does, in a few words: "Drop to read, summarize or keep".
    var dropLine: String {
        if let url = fileDrag.url, url.isAudioOrVideo { return "Drop to transcribe" }
        let offers = DroppedFile.offers(features: Features.shared.set, recording: recorder.phase == .recording, isFile: true, kept: false)
        let words = offers.map { offer in
            switch offer {
            case .attach: "attach"
            case .read: "read"
            case .summarize: "summarize"
            case .keep: "keep"
            }
        }
        switch words.count {
        case 0: return "Drop it here"
        case 1: return "Drop to \(words[0])"
        default: return "Drop to " + words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1]
        }
    }

    /// True while the bar gives way to the line that says what a drop does.
    var invitesDrop: Bool { fileDrag.over && content == nil || fileDrag.over && content == .tiles }

    /// What the dropped file offers now, the first being the one Return presses.
    var dropOffers: [DroppedFile.Offer] {
        guard let doc = dropped else { return [] }
        return DroppedFile.offers(features: Features.shared.set, recording: recorder.phase == .recording, isFile: doc.url != nil, kept: doc.saved != nil)
    }

    /// Does one of the dropped file's actions.
    func dropDo(_ offer: DroppedFile.Offer) {
        switch offer {
        case .attach: attachDropped()
        case .read: readDropped()
        case .summarize: summarizeDropped()
        case .keep: keepDroppedInLibrary()
        }
    }

    /// Keeps the dropped file with the recording being made, and puts the panel away.
    func attachDropped() {
        guard Features.shared.set.records, recorder.phase == .recording, let doc = dropped, let url = doc.url else { return }
        dropped = nil
        if recorder.attach(url) { say("“\(doc.imported.title)” is kept with this recording") } else { say("Chirp could not read \(url.lastPathComponent)", error: true) }
    }

    /// Test links: `file-drag?state=near` (`over`, empty to end), with `path` for the file being dragged.
    func registerDropDebug() {
        LinkHandler.commands["file-drag"] = { [weak self] q in
            guard let self else { return }
            let url = q["path"].map { URL(fileURLWithPath: $0) }
            switch q["state"] {
            case "near":
                self.fileDrag = FileDrag()
                self.fileDragBegan(url ?? URL(fileURLWithPath: "/tmp/book.epub"))
            case "over":
                self.fileDrag = FileDrag()
                self.fileDragBegan(url ?? URL(fileURLWithPath: "/tmp/book.epub"))
                if self.fileDrag.near { self.fileDrag.over = true }
            default: self.fileDrag = FileDrag()
            }
        }
        LinkHandler.stateProviders["fileDrag"] = { [weak self] in
            guard let self else { return [:] }
            var out: [String: Any] = ["near": self.fileDrag.near, "over": self.fileDrag.over, "line": self.dropLine, "invites": self.invitesDrop]
            if let doc = self.dropped {
                out["facts"] = doc.facts
                out["firstLines"] = doc.firstLines
                out["about"] = doc.about
                out["book"] = doc.imported.about
                out["offers"] = self.dropOffers.map(\.rawValue)
                out["kept"] = doc.saved != nil
            }
            return out
        }
    }
}

extension PerchController.DroppedDocument {
    /// "EPUB book · 288 pages · about 5 h to listen".
    var facts: String {
        let format = imported.format.isEmpty ? (url.map { DocumentRows.format(ofFileEnding: $0.pathExtension) } ?? "") : imported.format
        return DroppedFile.facts(format: url == nil && format.isEmpty ? "Page" : format, pages: imported.pages, listenSeconds: ReadingText.estimatedDuration(imported.text))
    }

    /// Its first lines, in quotation marks.
    var firstLines: String {
        // A file often opens with its own title: the lines after it say more.
        var text = imported.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(imported.title), text.count > imported.title.count + 40 { text = String(text.dropFirst(imported.title.count)) }
        return DroppedFile.firstLines(text)
    }

    /// What the panel says under the facts: who wrote it and how it is divided when the file says so
    /// ("Cal Newport. 4 parts, 15 chapters. Starts at the introduction."), else its first lines. A file
    /// that only names its author has both.
    var about: String {
        let book = imported.about
        if book.isEmpty { return firstLines }
        // Chapters counted: the line as it is. Only an author: the first lines still say more.
        return book.contains("chapters") || firstLines.isEmpty ? book : "\(book) \(firstLines)"
    }

    var isBook: Bool { (imported.format.isEmpty ? url?.pathExtension.lowercased() == "epub" : imported.format == "EPUB") }
}

// MARK: - Views

/// The amber ring the perch wears while a file is being dragged: a line on its edge with a paler band
/// round it, and a warm wash inside once the file is over it.
struct DropRing: View {
    let radius: CGFloat
    let over: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if over { shape.fill(Color.amber.opacity(0.16)) }
            // The ring: a 2-point amber line on the edge, and a paler band 6 points wide outside it.
            RoundedRectangle(cornerRadius: radius + 6, style: .continuous).strokeBorder(Color.amber.opacity(0.28), lineWidth: 6).padding(-6)
            shape.strokeBorder(Color.amber, lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// With a file over the flat perch: the bird looks up at the file, and one line says what a drop does.
struct DropInvite: View {
    let perch: PerchController

    var body: some View {
        HStack(spacing: PerchStyle.gap) {
            Bird(mood: .idle, size: 32, gaze: CGPoint(x: 1.2, y: -1.6)).frame(width: 32, height: 32)
                .rotationEffect(.degrees(-24))
                .accessibilityHidden(true)
            Rectangle().fill(GlassFill.line).frame(width: 1, height: 20)
            DropLine(text: perch.dropLine).padding(.leading, 6)
        }
        .padding(.leading, 12).padding(.trailing, 20)
        .frame(height: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(perch.dropLine)
    }
}

/// The line itself, with a tray in front of it.
struct DropLine: View {
    let text: String
    var wraps = false

    var body: some View {
        HStack(alignment: wraps ? .top : .center, spacing: 8) {
            Image("chirp.drop").font(.system(size: 14, weight: .medium))
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(wraps ? 3 : 1).fixedSize(horizontal: !wraps, vertical: true)
        }
    }
}

/// With a file over the upright perch: the same line, in a narrow pane beside the column.
struct DropInvitePane: View {
    let perch: PerchController

    var body: some View {
        DropLine(text: perch.dropLine, wraps: true)
            .padding(.leading, 6).padding(.trailing, 14)
            .frame(width: 150, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(perch.dropLine)
    }
}

/// A dropped file before anything has been done with it: a cover or a page, what it is, its first
/// lines, then each action with a few words under it. The first action is the one Return presses.
struct DroppedFileBody: View {
    let perch: PerchController
    let doc: PerchController.DroppedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.facts).font(.system(size: 12, weight: .semibold)).foregroundStyle(GlassFill.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !doc.about.isEmpty {
                        Text(doc.about).font(.system(size: 12.5)).foregroundStyle(GlassFill.quiet).lineSpacing(2).lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("drop.facts")
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 2)
            VStack(spacing: 1) {
                ForEach(Array(perch.dropOffers.enumerated()), id: \.element) { index, offer in
                    DropAction(perch: perch, offer: offer, primary: index == 0, detail: detail(offer))
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        }
    }

    /// A book shows its cover as a dark plate with its title; anything else a page with lines on it.
    @ViewBuilder private var cover: some View {
        if doc.isBook {
            Text(doc.imported.title.uppercased()).font(.system(size: 7.5, weight: .bold)).lineSpacing(1).foregroundStyle(Color.white)
                .padding(.horizontal, 6).padding(.vertical, 8)
                .frame(width: 54, height: 76, alignment: .topLeading)
                .background(Color.documentCover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array([0.6, 1, 1, 0.8, 1, 0.45, 1, 0.7].enumerated()), id: \.offset) { _, width in
                    GeometryReader { geo in
                        Capsule().fill(Color.ink.opacity(0.16)).frame(width: geo.size.width * width)
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 9)
            .frame(width: 54, height: 76, alignment: .top)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.ink.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
            .accessibilityHidden(true)
        }
    }

    private func detail(_ offer: DroppedFile.Offer) -> String {
        switch offer {
        case .attach: perch.recorder.title.isEmpty ? "Keep it with this recording" : "Keep it with \(perch.recorder.title)"
        case .read: "Listen from the start"
        case .summarize: "The main points"
        case .keep: "Save it to Documents"
        }
    }
}

/// One action of a dropped file: a round icon, its name, and a few words under it.
private struct DropAction: View {
    let perch: PerchController
    let offer: DroppedFile.Offer
    let primary: Bool
    let detail: String
    @State private var hovering = false

    private var title: String {
        switch offer {
        case .attach: "Attach to this recording"
        case .read: "Read aloud"
        case .summarize: "Summarize"
        case .keep: "Keep in Library"
        }
    }

    private var symbol: String {
        switch offer {
        case .attach: "chirp.attach"
        case .read: "chirp.read"
        case .summarize: "chirp.summarize"
        case .keep: "chirp.library"
        }
    }

    var body: some View {
        Button { perch.dropDo(offer) } label: {
            HStack(spacing: 11) {
                Image(symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primary ? PerchStyle.onAmber : GlassFill.ink)
                    .frame(width: 30, height: 30)
                    .background(primary ? PerchStyle.amber : GlassFill.row, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(GlassFill.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(GlassFill.quiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                if primary { PerchKey(text: "↵").fixedSize() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(primary || hovering ? GlassFill.row.opacity(primary && hovering ? 1.5 : 0.8) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(primary ? .defaultAction : nil)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityIdentifier("drop.\(offer.rawValue)")
    }
}
