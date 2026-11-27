import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Chirp's colours, and what each is for. The rules are in Docs/DESIGN.md (section 4, Colour); in short:
//
//   Paper, Card, Float   surfaces: the window, a raised card, anything that floats over other apps
//   Ink, Quiet           words: what you read, and what supports it
//   Clay (the accent)    what you can act on in a window: selection, the main button, switches, links
//   Amber                the bird, and whatever the bird is offering or doing right now
//   Robin, Jay, Moss     meaning: a mistake (and recording, and deleting); grammar; style (and "done")
//   Caution              something needs attention but nothing is broken
//
// Every colour has a light and a dark value. No view uses a system colour (.red, .orange, .blue) directly.
extension Color {
    /// Words you read.
    static let ink = Color("Ink")
    /// The background of a window.
    static let paper = Color("Paper")
    /// A raised surface on paper.
    static let card = Color("Card")
    /// The surface of anything that floats over other apps: the perch and its cards.
    static let float = Color("Float")
    /// Words that support what you read: captions, hints, counts.
    static let quiet = Color("Quiet")
    /// Amber: the bird's own colour. `birdBody` and `amber` are the same colour under two names.
    static let birdBody = Color("BirdBody")
    static let amber = Color("BirdBody")
    /// Words and icons that sit on amber.
    static let onAmber = Color("OnAmber")
    /// Robin: a mistake. Also the recording light and anything that deletes.
    static let spelling = Color("Spelling")
    /// Jay: grammar. Also the other people in a transcript.
    static let grammar = Color("Grammar")
    /// Moss: style. Also "allowed" and "done".
    static let style = Color("Style")
    /// Something needs attention but nothing is broken.
    static let caution = Color("Caution")
    /// The bird's wing and tail, its cheek, and its eye.
    static let birdWing = Color("BirdWing")
    static let birdCheek = Color("BirdCheek")
    static let birdEye = Color("BirdEye")
    /// The recording light on the menu bar icon, the same light or dark.
    static let recordLight = Color("RecordLight")
    /// The button that stops a recording in the menu bar popover: one red, light or dark, that white reads on.
    static let recordButton = Color("RecordButton")
    /// A document's cover where it has no picture: flat on the perch, and a gradient from top to bottom on Home.
    static let documentCover = Color("DocumentCover")
    static let documentCoverTop = Color("DocumentCoverTop")
    static let documentCoverBottom = Color("DocumentCoverBottom")
}

extension Font {
    /// Page titles: 28 bold, the Mac's own typeface. The same on every page.
    static let pageTitle = Font.system(size: 28, weight: .bold)
    /// The title of whatever is open on the right of a list page: a meeting, a document, a note.
    static let detailTitle = Font.system(size: 20, weight: .semibold)
    /// A section heading inside a page or a sheet: 13 semibold.
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    /// The text of a document in the reader.
    static let reading = Font.system(size: 16)
    /// The grey line under a name: what the thing is.
    static let rowMeta = Font.system(size: 12)
}

/// The measurements every page shares, so titles, rows and headings start on one left line.
enum PageLayout {
    /// From the left edge of the page to the start of every title, heading and row.
    static let gutter: CGFloat = 44
    /// The list column of a list page, including its own padding.
    static let listWidth: CGFloat = 300
    /// The least height of a two-line row.
    static let rowHeight: CGFloat = 52
    /// A line between rows: ink at low strength.
    static let line = Color.ink.opacity(0.12)
    /// The tint under a row that is pointed at.
    static let hover = Color.ink.opacity(0.05)
    /// The tint under the picked row.
    static let selected = Color.ink.opacity(0.09)
}

/// How every page starts: a 28-point bold title with one grey line under it, in the same place.
struct PageHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.pageTitle).tracking(-0.5).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            // The line is always there, so the content under the header starts at the same height on every page.
            Text(subtitle.isEmpty ? " " : subtitle).font(.system(size: 13)).foregroundStyle(Color.quiet).lineLimit(1)
                .accessibilityHidden(subtitle.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PageLayout.gutter).padding(.trailing, PageLayout.gutter).padding(.top, 6)
    }
}

/// A page inside the main window: the shared header, then its content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: title, subtitle: subtitle)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.paper)
    }
}

/// A section heading: 13 semibold in full ink, its count after it in grey, at most one link at the far right.
struct SectionHeading<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.sectionTitle).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            if let count { Text("\(count)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.quiet).monospacedDigit() }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, 21).padding(.bottom, 5)
    }
}

/// The one link a section heading may carry, at its far right.
struct HeadingLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            // Quiet at rest so it never competes with the heading; Ink under the pointer so it reads as a link.
            .foregroundStyle(hovering ? Color.ink : Color.quiet)
            .onHover { hovering = $0 }
    }
}

/// Where something came from: a small grey line above the things it produced, with that kind's icon.
struct SourceLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(symbol).font(.system(size: 11)).frame(width: 14)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.quiet)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(text)")
    }
}

/// An item as two lines: its name, then what it is underneath. The right edge holds only things to
/// press, shown on the row pointed at (or always, when `alwaysShowActions`).
struct ItemRow<Actions: View>: View {
    var symbol: String?
    let title: String
    let meta: String
    /// How far through, 0 to 1, drawn as a short bar after the grey line.
    var progress: Double?
    var titleWeight: Font.Weight = .medium
    var alwaysShowActions = false
    var selected = false
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(symbol).font(.system(size: 14)).foregroundStyle(Color.quiet).frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: titleWeight)).foregroundStyle(Color.ink).lineLimit(1)
                HStack(spacing: 8) {
                    Text(meta).font(.rowMeta).foregroundStyle(Color.quiet).lineLimit(1)
                    if let progress {
                        ProgressBar(value: progress).frame(width: 90).accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 8)
            // Hidden by opacity only, so VoiceOver can still reach the row's actions without a pointer.
            actions()
                .opacity(alwaysShowActions || hovering || selected ? 1 : 0)
        }
        .frame(minHeight: PageLayout.rowHeight)
        .padding(.horizontal, 10)
        .background(selected ? PageLayout.selected : hovering ? PageLayout.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PageLayout.line).frame(height: 1).padding(.horizontal, 10).opacity(hovering || selected ? 0 : 1)
        }
        // The tint reaches past the text on both sides, so the text itself stays on the page's left line.
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thin amber bar showing how far through something is.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.12))
                // Amber alone is too faint on Paper, so the filled part has a thin darker edge.
                Capsule().fill(Color.amber)
                    .overlay(Capsule().strokeBorder(Color.onAmber.opacity(0.35), lineWidth: 1))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// A small round button holding one symbol, for the right edge of a row and for bars.
struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    /// Amber, for the action in use.
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(symbol).font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(active ? Color.onAmber : Color.ink.opacity(0.8))
                .frame(width: size, height: size)
                .background(active ? Color.amber : hovering ? Color.ink.opacity(0.08) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A short action with words on it ("Redo notes", "Open"). `primary` is the one amber action of a row.
struct ActButton: View {
    let title: String
    var symbol: String?
    var primary = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(symbol).font(.system(size: 11, weight: .medium)) }
                Text(title).font(.system(size: 12.5, weight: primary ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(primary ? Color.onAmber : Color.ink.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 26)
            .background(primary ? Color.amber : hovering ? Color.ink.opacity(0.08) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// The filled capsule behind a chip: something that opens a choice (a template, a voice) or one of a set of tabs.
struct ChipLabel: View {
    let title: String
    var selected = false
    /// A small arrow after the words, for a chip that opens something.
    var arrow: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            if let arrow { Image(arrow).font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.quiet) }
        }
        .foregroundStyle(Color.ink.opacity(0.9))
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.ink.opacity(selected ? 0.14 : 0.07), in: Capsule())
        .contentShape(Capsule())
    }
}

/// A rounded surface for grouped content.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.07)))
    }
}

/// An empty state: one plain line saying what goes here, and the action that starts it.
struct EmptyLine<Action: View>: View {
    let text: String
    @ViewBuilder var action: () -> Action

    init(_ text: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.text = text
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 13)).foregroundStyle(Color.quiet)
            action()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

extension Date {
    /// "3:41 PM" for today, "Yesterday 3:41 PM", then "Nov 3" for anything older.
    var shortRelative: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday " + formatted(date: .omitted, time: .shortened) }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

extension URL {
    /// True for a sound or video file, which Chirp transcribes; anything else is a document to read.
    var isAudioOrVideo: Bool {
        let type = UTType(filenameExtension: pathExtension)
        return type?.conforms(to: .audio) == true || type?.conforms(to: .movie) == true
    }
}

extension View {
    /// Takes a file dragged onto the view (the first one, when several are dragged together).
    /// `isTargeted` is true while a file is held over it.
    func onFileDrop(isTargeted: Binding<Bool>? = nil, _ take: @escaping @MainActor @Sendable (URL) -> Void) -> some View {
        onDrop(of: [UTType.fileURL], isTargeted: isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in take(url) } }
            }
            return true
        }
    }

    /// Space, ← and → for a player's bar, anywhere in the bar's window, as a media app takes them. They
    /// do nothing while a text field or text view has the keyboard, so typing a space or moving the cursor
    /// in a field on the same page never plays or skips. `press` is told which key; `keys` limits which
    /// are taken (a bar with no back or forward takes only Space).
    func playbackKeys(_ keys: Set<PlaybackKey> = Set(PlaybackKey.allCases), press: @escaping (PlaybackKey) -> Void) -> some View {
        modifier(PlaybackKeys(keys: keys, press: press))
    }
}

/// A key `playbackKeys` takes.
enum PlaybackKey: CaseIterable {
    case playPause, back, forward

    init?(keyCode: UInt16) {
        switch keyCode {
        case 49: self = .playPause
        case 123: self = .back
        case 124: self = .forward
        default: return nil
        }
    }
}

/// Watches the keys of the window the view is in. A `.keyboardShortcut` with no modifiers fires even
/// while a text field has the keyboard, and `.onKeyPress` needs the bar itself to have focus, which a
/// list beside it usually holds; a key monitor that steps aside for text does what both should.
private struct PlaybackKeys: ViewModifier {
    let keys: Set<PlaybackKey>
    let press: (PlaybackKey) -> Void
    @State private var box = Box()

    /// What the monitor reads when a key comes in. Kept current on every draw, so the monitor never
    /// acts on the item the bar showed when it appeared.
    @MainActor final class Box {
        var keys: Set<PlaybackKey> = []
        var press: (PlaybackKey) -> Void = { _ in }
        /// A view in the bar's window, to tell its window's keys from another window's.
        weak var anchor: NSView?
        var monitor: Any?
    }

    func body(content: Content) -> some View {
        box.keys = keys
        box.press = press
        return content
            .background(Anchor(box: box).frame(width: 0, height: 0).accessibilityHidden(true))
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        guard box.monitor == nil else { return }
        let box = box
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are called on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = box.anchor?.window, event.window === window, let key = PlaybackKey(keyCode: event.keyCode),
                    box.keys.contains(key), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                    !(key == .playPause && event.isARepeat),
                    // A field being typed in keeps its keys.
                    !(window.firstResponder is NSText)
                else { return false }
                box.press(key)
                return true
            }
            return handled ? nil : event
        }
    }

    private func stop() {
        if let monitor = box.monitor { NSEvent.removeMonitor(monitor) }
        box.monitor = nil
    }

    private struct Anchor: NSViewRepresentable {
        let box: Box
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            box.anchor = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { box.anchor = view }
    }
}

extension Double {
    /// A reading speed as shown on its button: 1 → "1×", 1.5 → "1.5×".
    var speedLabel: String { "\(formatted())×" }
}

/// Lays views out in a row and wraps to the next line when the row is full, like words in a paragraph.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + lineSpacing))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

extension Image {
    /// An icon from the asset catalog drawn from its NSImage at a set size and weight. In the window's
    /// toolbar SwiftUI draws a Label's named custom symbol blank (SF Symbols were fine), so the toolbar's
    /// labels use this. Everywhere else `Image(name)` is used, which follows the font as SF Symbols do.
    static func toolbarIcon(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> Image {
        Image(nsImage: NSImage(named: name)?.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage())
    }
}
