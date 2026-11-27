import AppKit
import ChirpCore
import ChirpML
import KeyboardShortcuts
import SwiftUI

// The perch is one glass surface. At rest it is a capsule holding the bird and the actions. Pointing at
// it makes the same bar taller, with names and shortcuts. Whatever Chirp has to show (a summary, the
// suggestions, finished notes, the rephrase panel) rises out of the bar as part of it: a head row, a
// body, a foot row of what to do next, then the bar. While Chirp is busy the actions give way to that
// one thing, with a way out at the right end. The measurements are in Docs/DESIGN.md (section 2, The
// perch), and every state shares them.

/// The colours and sizes every part of the perch shares.
enum PerchStyle {
    // The solid floating surfaces (the suggestion card, and the perch with Reduce Transparency) use
    // Chirp's own set from Theme.swift.
    static let fill = Color.float
    static let line = Color.ink.opacity(0.13)
    /// Under the pointer.
    static let soft = Color.ink.opacity(0.07)
    /// A quiet chip or key cap.
    static let softer = Color.ink.opacity(0.11)
    static let text = Color.ink
    static let dim = Color.quiet
    static let amber = Color.amber
    static let onAmber = Color.onAmber
    static let red = Color.spelling
    /// The shadow under a solid floating surface.
    static let shadow = Color.black.opacity(0.26)

    // On glass, words, icons and fills come from `GlassFill`.
    /// How much of Chirp's floating surface colour lies over the glass, so words stay readable over a
    /// busy page and in the dark.
    static let wash = 0.62

    /// The bar: one row, this tall, in every state. Upright, it is this wide.
    static let barHeight: CGFloat = 46
    /// A round button on the bar.
    static let button: CGFloat = 34
    /// A word button in a foot row or on the bar.
    static let act: CGFloat = 26
    static let bird: CGFloat = 30
    /// The corner of the surface once it holds anything. Alone, the bar is a capsule.
    static let radius: CGFloat = 22

    // The bar's measurements, plain and taller, lying flat and upright. The views lay themselves out
    // from these and the controller works out from the same numbers where each action is, so the
    // action under the pointer can stay there when the bar grows.

    /// Between neighbours on the bar.
    static let gap: CGFloat = 2
    /// A hairline's room along the bar: the line and 5 points either side.
    static let ruleBox: CGFloat = 11
    /// The taller bar: its thickness lying flat, and its width upright. Tiles sit 10 points in from every edge.
    static let tallBarHeight: CGFloat = 80
    static let tallColumn: CGFloat = 100

    /// From the end of the bar to the first and last thing on it.
    static func inset(tall: Bool, upright: Bool) -> CGFloat { tall ? 10 : upright ? 8 : 6 }
    /// The bird's room along the bar, its margins included.
    /// (Upright and pointed at, a Beta build's mark sits under the bird and takes a little more room.)
    static func birdBox(tall: Bool, upright: Bool) -> CGFloat { tall ? (upright ? 46 + (Beta.isOn ? 14 : 0) : 44) : (upright ? 38 : 40) }
    /// An action's room along the bar: a round button, or a tile with its name and shortcut.
    static func itemLength(tall: Bool, upright: Bool) -> CGFloat { tall ? (upright ? 58 : 76) : button }
    /// More's room along the bar.
    static func moreLength(tall: Bool, upright: Bool) -> CGFloat { tall ? (upright ? 46 : 64) : button }
    /// An action's size across the bar.
    static func itemBreadth(tall: Bool, upright: Bool) -> CGFloat { tall ? (upright ? 80 : 60) : button }

    /// Where the first action starts along the bar.
    private static func firstItem(tall: Bool, upright: Bool) -> CGFloat {
        inset(tall: tall, upright: upright) + birdBox(tall: tall, upright: upright) + gap + ruleBox + gap
    }

    /// Where the bird's part of the plain bar ends and the actions begin.
    static func birdEnd(upright: Bool) -> CGFloat { inset(tall: false, upright: upright) + birdBox(tall: false, upright: upright) + gap }

    /// How many actions are on the bar: the five (at most) the user put there, less those whose feature
    /// is switched off. The perch keeps this up to date. More follows them, and with none the bar is
    /// the bird and More.
    nonisolated(unsafe) static var actionCount = 5
    /// How many actions the extended area shows while it is open; -1 while it is closed. Open, it follows
    /// More, ending with the small "…".
    nonisolated(unsafe) static var extendedCount = -1

    /// The small "…" at the end of the extended area.
    static func dotsLength(tall: Bool, upright: Bool) -> CGFloat { tall ? (upright ? 40 : 40) : 26 }
    /// Between More and the extended area, and inside the area's tint at each end.
    static let areaGap: CGFloat = 4

    /// The middle of an action (0 up to one less than `count`, then More, then the extended area's actions
    /// and its "…") along the bar, plain or taller.
    static func itemCentre(_ item: Int, tall: Bool, upright: Bool, count: Int = actionCount) -> CGFloat {
        let length = itemLength(tall: tall, upright: upright)
        let first = firstItem(tall: tall, upright: upright)
        if item < count { return first + length / 2 + (length + gap) * CGFloat(max(item, 0)) }
        // With no actions there is one hairline, not two, between the bird and More.
        let actions = count == 0 ? 0 : CGFloat(count) * length + CGFloat(count - 1) * gap + gap + ruleBox + gap
        let more = first + actions + moreLength(tall: tall, upright: upright) / 2
        if item == count { return more }
        // In the extended area.
        let start = more + moreLength(tall: tall, upright: upright) / 2 + gap + areaGap * 2
        let index = item - count - 1
        if index < max(extendedCount, 0) { return start + length / 2 + (length + gap) * CGFloat(index) }
        return start + (length + gap) * CGFloat(max(extendedCount, 0)) + dotsLength(tall: tall, upright: upright) / 2
    }

    /// How long the bar with its actions is (and the extended area, while it is open).
    static func barLength(tall: Bool, upright: Bool, count: Int = actionCount) -> CGFloat {
        let more = itemCentre(count, tall: tall, upright: upright, count: count) + moreLength(tall: tall, upright: upright) / 2
        guard extendedCount >= 0, count == actionCount else { return more + inset(tall: tall, upright: upright) }
        let area = gap + areaGap * 3 + (itemLength(tall: tall, upright: upright) + gap) * CGFloat(extendedCount) + dotsLength(tall: tall, upright: upright) + areaGap
        return more + area + inset(tall: tall, upright: upright)
    }

    // The status bubble: what the bird says. One set of sizes for every place it appears.

    /// The bubble is never wider than this; longer words wrap.
    static let bubbleMaxWidth: CGFloat = 300
    /// One line of words is this tall.
    static let bubbleMinHeight: CGFloat = 34
    static let bubbleFont: CGFloat = 13
    /// Before the words, and after the ×.
    static let bubbleLeading: CGFloat = 13
    static let bubbleTrailing: CGFloat = 5
    /// The × is this big.
    static let bubbleClose: CGFloat = 24
    /// From the perch to the bubble, with the tail in between.
    static let bubbleGap: CGFloat = 10
    /// How far the tail stands out from the bubble.
    static let bubbleTail: CGFloat = 6
    /// Wrapped words show this many lines before "More".
    static let bubbleLines = 3
    /// The corner: a capsule for one line, a little squarer when taller.
    static func bubbleRadius(oneLine: Bool) -> CGFloat { oneLine ? 17 : 16 }

    /// The resting perch's footprint: the plain bar with its actions, lying flat or standing upright.
    /// Every busy state is given exactly this box, so starting or ending one never changes the perch's
    /// size, corner or place. Only pointing at it, showing something, a line of words and tucking do.
    static func restSize(upright: Bool) -> CGSize {
        let length = barLength(tall: false, upright: upright)
        return upright ? CGSize(width: barHeight, height: length) : CGSize(width: length, height: barHeight)
    }

    /// The box every busy state is given: the resting bar with all five actions, which is what the busy
    /// bars are laid out for (six slots after the bird). With every feature on this is the resting bar
    /// itself; with some switched off the bar is shorter at rest and comes out to this while busy.
    static func busySize(upright: Bool) -> CGSize {
        let length = barLength(tall: false, upright: upright, count: 5)
        return upright ? CGSize(width: barHeight, height: length) : CGSize(width: length, height: barHeight)
    }

    /// The action nearest a point along the plain bar.
    static func nearestItem(to along: CGFloat, upright: Bool) -> Int {
        (0...(actionCount + max(extendedCount, 0) + (extendedCount >= 0 ? 1 : 0))).min { abs(itemCentre($0, tall: false, upright: upright) - along) < abs(itemCentre($1, tall: false, upright: upright) - along) } ?? 0
    }

    /// Small things: a highlight, a button appearing.
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.86)
}

/// What the bar row is showing.
enum PerchBar: Hashable {
    /// A faint wire only (the "Quiet" setting).
    case wire
    /// The bird alone (the "Present" setting).
    case bird
    /// The bird and the actions.
    case actions
    case dictating, working, meeting, reading, preparing

    /// Chirp is doing something: listening, recording, reading aloud or working. These are laid out
    /// inside the resting bar's own footprint, so the perch does not change size when one starts or ends.
    var isBusy: Bool {
        switch self {
        case .dictating, .working, .meeting, .reading, .preparing: true
        default: false
        }
    }
}

/// One of the actions on the bar.
struct PerchTool: Identifiable {
    /// Its name as shown under it: "Dictate", "Note", "Read", "Fix", "Summarize", "Meeting".
    let id: String
    /// What VoiceOver calls it.
    let label: String
    let symbol: String
    /// Its shortcut as text, or nil when none is set.
    let key: String?
    let action: () -> Void
    /// What it is, for the arrangement.
    var kind: PerchAction = .dictate
}

extension PerchController {
    /// The bar row for the current state. At rest it depends on how much of the perch the user wants to see.
    var bar: PerchBar {
        if let debugBar { return debugBar }
        return bar(for: mode)
    }

    private func bar(for mode: Mode) -> PerchBar {
        // Dictating into the open note: the bar stays as it is, and the note shows where the words will go.
        if notes.isOpen, content == .note, mode == .dictating || mode == .working { return .actions }
        switch mode {
        case .dictating: return .dictating
        case .working, .finishing: return .working
        case .meeting: return .meeting
        case .reading: return reader.isPreparing ? .preparing : .reading
        case .rest:
            if content == .note { return .actions }
            // Holding something, or being moved: the whole bar.
            if content != nil || dragging { return .actions }
            switch presence {
            case .quiet: return .wire
            case .present, .hidden: return .bird
            case .full: return .actions
            }
        }
    }

    /// The actions on the bar in the order the user put them, each with its current shortcut. One
    /// whose feature is switched off is not there.
    var tools: [PerchTool] { shownActions.bar.map(tool) }

    /// The actions in the extended area, while it is open.
    var extendedTools: [PerchTool] { shownActions.extended.map(tool) }

    /// How an action looks on the bar.
    func tool(_ action: PerchAction) -> PerchTool {
        let run = { [weak self] in self?.run(action) ?? () }
        switch action {
        case .dictate: return PerchTool(id: "Dictate", label: "Dictate", symbol: "chirp.dictate", key: ShortcutLayout.dictateLabel(holdKey: dictation.holdKey), action: run, kind: action)
        case .note: return PerchTool(id: "Note", label: "Note", symbol: "chirp.note", key: ShortcutLayout.label(.recordNote, short: true), action: run, kind: action)
        case .read: return PerchTool(id: "Read", label: "Read aloud", symbol: "chirp.read", key: ShortcutLayout.label(.readSelection, short: true), action: run, kind: action)
        case .fix: return PerchTool(id: "Fix", label: "Fix writing", symbol: "chirp.fix", key: ShortcutLayout.label(.writePanel, short: true), action: run, kind: action)
        case .summarize: return PerchTool(id: "Summarize", label: "Summarize", symbol: "chirp.summarize", key: ShortcutLayout.label(.summarize, short: true), action: run, kind: action)
        case .meeting: return PerchTool(id: "Meeting", label: "Record a meeting", symbol: "chirp.meeting", key: ShortcutLayout.label(.recordMeeting, short: true), action: run, kind: action)
        // Each has its own key: Fix writing right ⌥ I, Rephrase right ⌥ K.
        case .rephrase: return PerchTool(id: "Rephrase", label: "Rephrase", symbol: "chirp.rephrase", key: ShortcutLayout.label(.rephrase, short: true), action: run, kind: action)
        case .snippet: return PerchTool(id: "Snippet", label: "Save as a Snippet", symbol: "chirp.snippetAdd", key: nil, action: run, kind: action)
        case .typeAgain: return PerchTool(id: "Again", label: "Type the last dictation again", symbol: "chirp.typeAgain", key: ShortcutLayout.label(.pasteLast, short: true), action: run, kind: action)
        case .library: return PerchTool(id: "Library", label: "Library", symbol: "chirp.library", key: ShortcutLayout.label(.openLibrary, short: true), action: run, kind: action)
        }
    }

    /// How many writing suggestions are waiting in the app in front.
    var fixes: Int { underlines.shown.count }

    /// The action in use, which is the one tinted button on the bar.
    var activeTool: String? {
        switch content {
        case .document: dropped?.summarizing == true || dropped?.summary != nil ? "Summarize" : nil
        case .fixes, .rephrase: "Fix"
        case .note: "Note"
        case .meetingNotes: recorder.kind == .meeting ? "Meeting" : nil
        case .notes: nil
        default: nil
        }
    }

    /// What the working bar says.
    var workingLine: String {
        if case .finishing(let step) = recorder.phase, dictation.phase == .idle { return step.isEmpty ? "Finishing" : step }
        if recorder.writingNotesFor != nil, dictation.phase == .idle { return recorder.stoppingNotes ? "Stopping" : "Writing notes" }
        // A file or a link being transcribed says which part it is on.
        // The bar is short: "Part 12 of 27", not "Transcribing · part 12 of 27".
        if let status = dictation.importStatus {
            guard let part = status.line.range(of: " · part ") else { return status.line }
            return "Part " + status.line[part.upperBound...]
        }
        return "Writing it down"
    }

    /// True while the working bar is about a meeting's notes being written, which its × can stop.
    var canStopNotes: Bool {
        recorder.phase == .idle && dictation.phase == .idle && dictation.importStatus == nil && recorder.writingNotesFor != nil && !recorder.stoppingNotes
    }

    /// What a job waiting its turn says on the bar, when one is waiting and nothing is being dictated.
    var waitingLine: String? {
        guard dictation.phase == .idle || dictation.importStatus != nil else { return nil }
        return Jobs.shared.firstWaiting?.line
    }

    /// How big the surface is, roughly, so a change can be told as growing or shrinking.
    var surfaceLevel: Int {
        switch content {
        case .tiles: return 3
        case .some(let kind): return isTall(kind) ? 6 : 5
        case nil:
            switch bar {
            case .wire: return 0
            case .bird: return 1
            default: return 2
            }
        }
    }
}

/// Remembers the last size of the surface between two passes over the view.
private final class LevelMemory {
    var last = 2
}

/// Everything that changes the surface's shape. When it changes, the shape moves with a spring.
private struct ShapeKey: Hashable {
    var bar: PerchBar
    var content: PerchContent?
    var upright: Bool
    var tucked: Bool
    var dragging: Bool
    var spot: String
    var near: String?
    var bounds: String
}

/// Everything in the perch's panel: the surface, pinned where the perch sits, and the landing spots
/// while it is dragged. Files dropped on the perch are handed to the controller.
struct PerchView: View {
    let perch: PerchController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var memory = LevelMemory()

    var body: some View {
        // The bar is laid out again when a feature is switched on or off: it has one action for each.
        let _ = Features.shared.set
        let bar = perch.bar
        let content = perch.content
        let level = perch.surfaceLevel
        let growing = level >= memory.last
        let key = ShapeKey(
            bar: bar, content: content, upright: perch.upright, tucked: perch.tucked, dragging: perch.dragging,
            spot: perch.spot.stored, near: perch.nearSpot?.stored, bounds: NSStringFromRect(perch.bounds))
        ZStack(alignment: .topLeading) {
            if perch.dragging {
                LandingSpots(perch: perch).transition(.opacity)
            }
            PerchPlacer(pin: perch.pin, bounds: perch.bounds, tuck: perch.tucked ? perch.tuckEdge : nil) {
                PerchSurface(perch: perch, bar: bar, content: content, namespace: glass)
            }
            // What the bird has to say: a piece of its own beside the perch, which stays exactly as it is.
            let side = BubbleSide.choose(for: perch)
            BubblePlacer(anchor: BubbleAnchor(bird: perch.birdFrame, surface: perch.bubbleSurface), side: side, bounds: perch.bounds) {
                if let saying = perch.saying, !perch.tucked {
                    PerchBubble(perch: perch, saying: saying, side: side)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: side.tailAnchor).combined(with: .opacity))
                }
            }
        }
        .animation(GlassMotion.shape(growing: true, reduceMotion: reduceMotion), value: perch.saying?.id)
        .animation(GlassMotion.shape(growing: true, reduceMotion: reduceMotion), value: perch.noticeExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onFileDrop(isTargeted: Binding(get: { perch.fileDrag.over }, set: { over in
            perch.fileDrag.over = over
            // A drag that began where it could not be seen (inside Chirp's own window) still lights the perch.
            if over { perch.fileDrag.near = true }
        })) { url in
            perch.fileDrag = FileDrag()
            perch.add(url)
        }
        .animation(GlassMotion.shape(growing: growing, reduceMotion: reduceMotion), value: key)
        .onChange(of: level) { _, new in memory.last = new }
    }
}

/// Pins its one view to a point: the given part of the view sits on the point, and the view is kept
/// inside the usable screen. A tucked view is slid under the edge so only a sliver shows.
private struct PerchPlacer: SwiftUI.Layout {
    var pin: PerchPin
    var bounds: CGRect
    var tuck: Edge?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in rect: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let area = bounds.insetBy(dx: 6, dy: 6)
        var x = pin.point.x - pin.unit.x * size.width
        var y = pin.point.y - pin.unit.y * size.height
        // On whole points, so words and hairlines stay sharp wherever it was dropped.
        x = min(max(x, area.minX), max(area.minX, area.maxX - size.width)).rounded()
        y = min(max(y, area.minY), max(area.minY, area.maxY - size.height)).rounded()
        switch tuck {
        case .bottom: y = bounds.maxY - PerchController.sliver
        case .leading: x = bounds.minX - size.width + PerchController.sliver
        case .trailing: x = bounds.maxX - PerchController.sliver
        default: break
        }
        view.place(at: CGPoint(x: rect.minX + x, y: rect.minY + y), anchor: .topLeading, proposal: .unspecified)
    }
}

/// The places the perch settles into, shown while it is dragged. The nearest is lit.
private struct LandingSpots: View {
    let perch: PerchController

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(PerchSpot.landings, id: \.stored) { spot in
                let frame = perch.restFrame(for: spot)
                let near = perch.nearSpot == spot
                let shape = RoundedRectangle(cornerRadius: min(frame.width, frame.height) / 2, style: .circular)
                // Float and Ink follow light and dark, so the spots read over a dark desktop as over a light one.
                shape.fill(near ? PerchStyle.amber.opacity(0.35) : Color.float.opacity(0.4))
                    .overlay(shape.strokeBorder(
                        near ? PerchStyle.onAmber : Color.ink.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: near ? [] : [5, 4])))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: The bubble

/// Which side of the perch the bubble is on. Its tail is on the side facing the bird.
enum BubbleSide {
    case above, below, right, left

    /// The edge of the bubble its tail comes out of.
    var tailEdge: Edge {
        switch self {
        case .above: .bottom
        case .below: .top
        case .right: .leading
        case .left: .trailing
        }
    }

    /// Where it grows from when it appears: the tail.
    var tailAnchor: UnitPoint {
        switch self {
        case .above: UnitPoint(x: 0.1, y: 1)
        case .below: UnitPoint(x: 0.1, y: 0)
        case .right: UnitPoint(x: 0, y: 0.3)
        case .left: UnitPoint(x: 1, y: 0.3)
        }
    }

    /// The side for where the perch is now. Lying flat, the bubble is above the bird; with no room there
    /// (the perch near the top of the screen) it goes below. Standing upright with nothing open beside
    /// the column, it is beside the bird's row, toward the middle of the screen.
    @MainActor static func choose(for perch: PerchController) -> BubbleSide {
        let grown = perch.content != nil && perch.content != .tiles
        if perch.upright, !grown {
            return perch.spot == .rightEdge ? .left : .right
        }
        let surface = perch.bubbleSurface
        let need: CGFloat = perch.noticeExpanded ? perch.bounds.height * 0.4 + 70 : 130
        let above = surface.minY - perch.bounds.minY
        let below = perch.bounds.maxY - surface.maxY
        return above >= need || above >= below ? .above : .below
    }
}

/// Puts the bubble beside the perch with its tail level with the bird, and slides it along so that all
/// of it stays on the usable screen.
private struct BubblePlacer: SwiftUI.Layout {
    var anchor: BubbleAnchor
    var side: BubbleSide
    var bounds: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in rect: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let bird = anchor.bird
        // The bubble's own frame includes its tail, which reaches most of the way to the perch.
        let off = PerchStyle.bubbleGap - PerchStyle.bubbleTail
        var x: CGFloat
        var y: CGFloat
        switch side {
        case .above:
            x = bird.midX - 23
            y = anchor.surface.minY - off - size.height
        case .below:
            x = bird.midX - 23
            y = anchor.surface.maxY + off
        case .right:
            x = anchor.surface.maxX + off
            y = bird.midY - PerchStyle.bubbleMinHeight / 2
        case .left:
            x = anchor.surface.minX - off - size.width
            y = bird.midY - PerchStyle.bubbleMinHeight / 2
        }
        let area = bounds.insetBy(dx: 6, dy: 6)
        x = min(max(x, area.minX), max(area.minX, area.maxX - size.width)).rounded()
        y = min(max(y, area.minY), max(area.minY, area.maxY - size.height)).rounded()
        view.place(at: CGPoint(x: rect.minX + x, y: rect.minY + y), anchor: .topLeading, proposal: .unspecified)
    }
}

/// The bubble's outline: a rounded box with a small tail on one edge. The tail is inside the shape's
/// own rectangle, so the box is that rectangle less the tail's depth on that edge.
struct BubbleShape: InsettableShape {
    var edge: Edge
    /// Where the tail's middle is along that edge, from the rectangle's leading or top end.
    var tailAt: CGFloat
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tailAt, radius) }
        set {
            tailAt = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let depth = PerchStyle.bubbleTail
        var box = rect
        switch edge {
        case .bottom: box.size.height -= depth
        case .top:
            box.origin.y += depth
            box.size.height -= depth
        case .leading:
            box.origin.x += depth
            box.size.width -= depth
        case .trailing: box.size.width -= depth
        }
        box = box.insetBy(dx: insetAmount, dy: insetAmount)
        let corner = max(0, min(radius - insetAmount, min(box.width, box.height) / 2))
        // One outline, drawn once round: the tail is part of the edge that faces the bird, so the
        // fill, the glass's edge and its shadow go round it as one shape. (It was a separate square on its
        // point, laid over the edge, and showed as a notch apart from the bubble.)
        let tip = max(0, depth - insetAmount * 0.4)
        let half = max(2, 7 - insetAmount * 0.5)
        let across = edge == .top || edge == .bottom
        let length = across ? box.width : box.height
        // The corners either side of the tail are no rounder than leaves the tail a straight edge to stand
        // on: a one-line bubble is a capsule, whose ends have none, and there the tail sits in the middle.
        let near = min(corner, max(2, (length - half * 2) / 2 - 1))
        let along = min(max(tailAt, near + half + 1), max(near + half + 1, length - near - half - 1))
        let (minX, minY, maxX, maxY) = (box.minX, box.minY, box.maxX, box.maxY)
        // The radius at each corner: top left, top right, bottom right, bottom left.
        let r: [CGFloat] = switch edge {
        case .top: [near, near, corner, corner]
        case .bottom: [corner, corner, near, near]
        case .leading: [near, corner, corner, near]
        case .trailing: [corner, near, near, corner]
        }
        var path = Path()
        func tail(from a: CGPoint, point: CGPoint, to b: CGPoint) {
            path.addLine(to: a)
            path.addArc(tangent1End: point, tangent2End: b, radius: 2.2)
            path.addLine(to: b)
        }
        path.move(to: CGPoint(x: minX + r[0], y: minY))
        if edge == .top {
            tail(from: CGPoint(x: minX + along - half, y: minY), point: CGPoint(x: minX + along, y: minY - tip), to: CGPoint(x: minX + along + half, y: minY))
        }
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r[1]), radius: r[1])
        if edge == .trailing {
            tail(from: CGPoint(x: maxX, y: minY + along - half), point: CGPoint(x: maxX + tip, y: minY + along), to: CGPoint(x: maxX, y: minY + along + half))
        }
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r[2], y: maxY), radius: r[2])
        if edge == .bottom {
            tail(from: CGPoint(x: minX + along + half, y: maxY), point: CGPoint(x: minX + along, y: maxY + tip), to: CGPoint(x: minX + along - half, y: maxY))
        }
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r[3]), radius: r[3])
        if edge == .leading {
            tail(from: CGPoint(x: minX, y: minY + along + half), point: CGPoint(x: minX - tip, y: minY + along), to: CGPoint(x: minX, y: minY + along - half))
        }
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r[0], y: minY), radius: r[0])
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// What the bird says: a status in a small glass bubble of its own, with a tail toward the bird. One
/// line is a capsule as wide as its words; longer words wrap at the bubble's widest; more than three
/// lines end in "More", which opens all of it in the same bubble. It goes on a click, on Escape, with
/// its × or after three seconds, and the perch does not change for it.
private struct PerchBubble: View {
    let perch: PerchController
    let saying: PerchController.Saying
    let side: BubbleSide
    @State private var frame = CGRect.zero

    /// How wide some words are on one line.
    private static func width(of text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// How many lines some words take when wrapped to a width.
    private static func lines(of text: String, width: CGFloat, size: CGFloat) -> Int {
        let font = NSFont.systemFont(ofSize: size)
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let line = font.ascender - font.descender + font.leading
        return max(1, Int((box.height / max(line, 1)).rounded()))
    }

    var body: some View {
        let font = PerchStyle.bubbleFont
        let names = saying.buttons.map { $0.count > 24 ? String($0.prefix(23)) + "…" : $0 }
        // A status has an × after its words; an offer has none, and gets the same room on that side as on the other.
        let trailing = saying.passes ? PerchStyle.bubbleTrailing : PerchStyle.bubbleLeading
        let closeRoom: CGFloat = saying.passes ? PerchStyle.bubbleClose + 4 : 0
        // The room for words on one line: the widest bubble less its padding, the × and the red dot of an error.
        let dot: CGFloat = saying.isError ? 14 : 0
        let room = PerchStyle.bubbleMaxWidth - PerchStyle.bubbleLeading - trailing - closeRoom - dot
        let lead = saying.lead.map { Self.width(of: $0 + "  ", size: font, weight: .semibold) } ?? 0
        let wide = lead + Self.width(of: saying.text, size: font)
        let buttons = names.reduce(CGFloat(6)) { $0 + Self.width(of: $1, size: 12.5, weight: .semibold) + 18 + 4 }
        let oneLine = wide + (names.isEmpty ? 0 : buttons) <= room
        let wraps = wide > room
        let count = wraps ? Self.lines(of: (saying.lead.map { $0 + "  " } ?? "") + saying.text, width: room, size: font) : 1
        let long = count > PerchStyle.bubbleLines
        let expanded = long && perch.noticeExpanded
        let shape = BubbleShape(edge: side.tailEdge, tailAt: tailAt, radius: PerchStyle.bubbleRadius(oneLine: oneLine))
        Group {
            if oneLine {
                HStack(spacing: 4) {
                    mark
                    words.lineLimit(1).fixedSize()
                    if !names.isEmpty { buttonRow(names).padding(.leading, 6) }
                    if saying.passes { close }
                }
                .padding(.leading, PerchStyle.bubbleLeading).padding(.trailing, trailing)
                .frame(height: PerchStyle.bubbleMinHeight)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 4) {
                        mark.padding(.top, 8)
                        wrapped(wraps: wraps, room: room, expanded: expanded)
                        if saying.passes { close }
                    }
                    if long, !expanded {
                        // Nothing is cut with no way to read it: this opens all of it in the same bubble.
                        PerchAct(perch: perch, title: "More") { perch.expandNotice() }
                            .padding(.leading, -9).accessibilityLabel("Show all of it")
                    }
                    // Its buttons on a row of their own under the words, the main one first.
                    if !names.isEmpty { buttonRow(names) }
                }
                .padding(.leading, PerchStyle.bubbleLeading).padding(.trailing, trailing)
                .padding(.top, 5).padding(.bottom, 8)
            }
        }
        .foregroundStyle(GlassFill.ink)
        .fixedSize()
        // Room for the tail on the side that faces the bird.
        .padding(Edge.Set(side.tailEdge), PerchStyle.bubbleTail)
        .contentShape(shape)
        // A status goes on a click anywhere on it. An offer waits for one of its buttons.
        .onTapGesture { if saying.passes { perch.dismissNotice() } }
        .chirpGlass(in: shape, wash: 0.82)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
            frame = new
            // A bubble on its way out no longer takes clicks.
            perch.bubbleFrame = perch.saying == nil ? .zero : new
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(saying.isError ? "Chirp, something went wrong" : saying.passes ? "Chirp says" : "Chirp asks")
    }

    /// The words: which call it is first and heavier, when there is one, then what is said.
    private var words: Text {
        let said = Text(saying.text).foregroundStyle(saying.lead == nil ? GlassFill.ink : GlassFill.quiet)
        guard let lead = saying.lead else { return said.font(.system(size: PerchStyle.bubbleFont)) }
        return (Text(lead + "  ").fontWeight(.semibold) + said).font(.system(size: PerchStyle.bubbleFont))
    }

    /// The bubble's buttons side by side, the main one first and amber.
    private func buttonRow(_ names: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                PerchAct(perch: perch, title: name, primary: index == 0) { perch.pressSayingButton(index) }
            }
        }
    }

    /// The words when they do not sit on one line with everything else: wrapped at the bubble's widest,
    /// three lines at most until "More" is pressed, then all of them, scrolling past 40% of the screen.
    @ViewBuilder private func wrapped(wraps: Bool, room: CGFloat, expanded: Bool) -> some View {
        let text = words.multilineTextAlignment(.leading)
        if expanded {
            PerchScroll(limit: max(120, perch.bounds.height * 0.4 - 60)) {
                text.fixedSize(horizontal: false, vertical: true).frame(width: room, alignment: .leading).padding(.vertical, 4)
            }
            .frame(width: room)
        } else if wraps {
            text.lineLimit(PerchStyle.bubbleLines).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true).frame(width: room, alignment: .leading).padding(.top, 4)
        } else {
            text.lineLimit(1).fixedSize().padding(.top, 4)
        }
    }

    /// The red dot that marks something gone wrong.
    @ViewBuilder private var mark: some View {
        if saying.isError {
            Circle().fill(PerchStyle.red).frame(width: 8, height: 8).padding(.trailing, 2)
                .accessibilityLabel("Error")
        }
    }

    private var close: some View {
        PerchIconButton(perch: perch, symbol: "chirp.close", label: "Dismiss", size: 10.5, side: PerchStyle.bubbleClose) { perch.dismissNotice() }
    }

    /// Where the tail is along its edge, so it stays level with the bird wherever the bubble was slid to.
    private var tailAt: CGFloat {
        let bird = perch.birdFrame
        guard !frame.isEmpty else { return side == .above || side == .below ? 23 : PerchStyle.bubbleMinHeight / 2 }
        switch side {
        case .above, .below: return bird.midX - frame.minX
        case .right: return bird.midY - frame.minY
        case .left: return bird.midY - frame.minY
        }
    }
}

// MARK: The surface

/// The outline of the surface. Lying flat it is a rounded rectangle. Docked at a side edge it is the
/// upright column joined to whatever has opened out of it: a flag out of the bird's row, or a pane the
/// full height of the surface. It is one shape throughout, so one piece of glass changes form.
struct PerchOutline: InsettableShape {
    /// How wide the upright column is; 0 when there is no column and the outline is a plain rounded rectangle.
    var column: CGFloat
    /// The column is on the right (docked at the right edge).
    var mirrored = false
    /// How far what has opened beside the column reaches down it: 0 is a flag as tall as the bird's row,
    /// 1 is the full height.
    var open: CGFloat = 1
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(column, AnimatablePair(open, radius)) }
        set {
            column = newValue.first
            open = newValue.second.first
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let corner = max(0, min(radius - insetAmount, min(r.width, r.height) / 2))
        let width = column - insetAmount * 2
        guard column > 0, open < 0.999, r.width > width + 0.5 else {
            return Path(roundedRect: r, cornerRadius: corner, style: .circular)
        }
        let flag = PerchStyle.barHeight - insetAmount * 2
        let reach = min(r.height, flag + (r.height - flag) * max(0, open))
        let col = CGRect(x: mirrored ? r.maxX - width : r.minX, y: r.minY, width: width, height: r.height)
        let wing = CGRect(x: r.minX, y: r.minY, width: r.width, height: reach)
        var path = Path(roundedRect: col, cornerRadius: min(corner, width / 2), style: .circular)
            .union(Path(roundedRect: wing, cornerRadius: min(corner, reach / 2), style: .circular))
        // The inside corner where the flag meets the column is eased, not sharp.
        let ease = min(10, max(0, r.height - reach), max(0, r.width - width))
        if ease > 0.5 {
            let side: CGFloat = mirrored ? -1 : 1
            let corner = CGPoint(x: mirrored ? col.minX : col.maxX, y: wing.maxY)
            var fillet = Path()
            fillet.move(to: CGPoint(x: corner.x + side * ease, y: corner.y))
            fillet.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x, y: corner.y + ease), radius: ease)
            fillet.addLine(to: corner)
            fillet.closeSubpath()
            path = path.union(fillet)
        }
        return path
    }

    func inset(by amount: CGFloat) -> PerchOutline {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// The glass shape and what is on it: the bar, and whatever the perch is holding or saying. Lying flat,
/// what it holds is above (or below) the bar row. Docked at a side edge the column stays as it is and
/// everything else opens beside it, toward the middle of the screen.
private struct PerchSurface: View {
    let perch: PerchController
    let bar: PerchBar
    let content: PerchContent?
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fade: AnyTransition { .opacity.animation(reduceMotion ? GlassMotion.reduced : GlassMotion.content) }
    /// The height of a pane that is as tall as its content, and of the upright surface, as last laid out.
    @State private var wingHeight: CGFloat = 0
    @State private var surfaceHeight: CGFloat = 0

    var body: some View {
        // Holding something beyond the taller bar.
        let grown = content != nil && content != .tiles
        let side = perch.upright
        let mirrored = perch.spot == .rightEdge
        let bare = bar == .wire && content == nil
        let radius: CGFloat = bare ? 7 : content != nil ? PerchStyle.radius : PerchStyle.barHeight / 2
        let columnWidth: CGFloat = content == .tiles ? PerchStyle.tallColumn : PerchStyle.barHeight
        // A file held over it: the bar gives way to one line that says what a drop does.
        let inviting = perch.invitesDrop && !bare
        let fitted = side && grown && !inviting && content.map(Self.fitsContent) == true
        let shape = PerchOutline(
            column: side && !bare ? columnWidth : 0, mirrored: mirrored,
            open: side && !(grown || inviting) ? 0 : fitted ? reach(columnHeight: surfaceHeight) : 1, radius: inviting && !side ? 28 : radius)
        let down = perch.opensDown
        GlassEffectContainer {
            Group {
                if side {
                    // The column never changes for what opens beside it; only the surface grows.
                    HStack(alignment: .top, spacing: 0) {
                        if mirrored {
                            wing(grown: grown)
                            if grown { divider }
                            if inviting { DropInvitePane(perch: perch).transition(fade) }
                        }
                        PerchBarRow(perch: perch, bar: bar, content: content == .tiles ? .tiles : nil)
                        if !mirrored {
                            if grown { divider }
                            wing(grown: grown)
                            if inviting { DropInvitePane(perch: perch).transition(fade) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        if grown, !down, let content { PerchHolding(perch: perch, kind: content).id(content).transition(fade) }
                        if inviting { DropInvite(perch: perch).transition(fade) } else { PerchBarRow(perch: perch, bar: bar, content: content) }
                        if grown, down, let content { PerchHolding(perch: perch, kind: content).id(content).transition(fade) }
                    }
                    .frame(width: grown ? content.map { perch.width(for: $0) } : nil)
                }
            }
            .foregroundStyle(GlassFill.ink)
            .font(.system(size: 13))
            .clipShape(shape)
            .contentShape(shape)
            .chirpGlass(in: shape, shown: !bare, wash: PerchStyle.wash)
            .glassEffectID("perch", in: namespace)
            // While a file is being dragged anywhere, the perch wears an amber ring: it will take it.
            .overlay { if perch.fileDrag.lit, !bare { DropRing(radius: inviting && !side ? 28 : radius, over: perch.fileDrag.over).transition(.opacity) } }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            surfaceHeight = frame.height
            perch.surfaceFrame = frame
            if perch.bubbleSurface != frame { perch.bubbleSurface = frame }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chirp")
    }

    /// The hairline between the column and what has opened beside it.
    private var divider: some View {
        Rectangle().fill(GlassFill.line).frame(width: 1).frame(maxHeight: .infinity).accessibilityHidden(true)
    }

    /// What opens beside the upright column: whatever the perch is holding, as tall as the surface.
    @ViewBuilder private func wing(grown: Bool) -> some View {
        if grown, let content {
            if Self.fitsContent(content) {
                // As tall as what is in it, beside the column.
                PerchHolding(perch: perch, kind: content).id(content)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: perch.width(for: content), alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wingHeight = $0 }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(fade)
            } else {
                PerchHolding(perch: perch, kind: content).id(content)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(width: perch.width(for: content), alignment: .leading)
                    .transition(fade)
            }
        }
    }

    /// What opens beside the upright column only as tall as it needs, not the column's full height.
    static func fitsContent(_ kind: PerchContent) -> Bool { kind == .sayItAs }

    /// How far down the column the pane reaches, 0 to 1 (`PerchOutline.open`), for one as tall as its content.
    private func reach(columnHeight: CGFloat) -> CGFloat {
        let flag = PerchStyle.barHeight
        guard wingHeight > flag, columnHeight > flag else { return 1 }
        return min(1, (wingHeight - flag) / (columnHeight - flag))
    }
}

/// What the perch is holding above its bar, by kind.
private struct PerchHolding: View {
    let perch: PerchController
    let kind: PerchContent

    var body: some View {
        switch kind {
        case .document: DocumentContent(perch: perch)
        case .fixes: FixesContent(perch: perch)
        case .rephrase: SelectionPanelView(controller: perch.selection, perch: perch)
        case .sayItAs: SayItAsContent(perch: perch)
        case .notes: NotesContent(perch: perch)
        case .meetingNotes: RecordingPanel(perch: perch)
        case .note: PerchNoteContent(perch: perch)
        case .tiles: EmptyView()
        }
    }
}

// MARK: The bar row

/// The bar: the bird first, then the actions or the one thing Chirp is doing. Dragging it by the bird
/// or any bare part moves the perch. At a side edge it stands upright and everything on it stacks.
private struct PerchBarRow: View {
    let perch: PerchController
    let bar: PerchBar
    let content: PerchContent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What replaces what on the bar: the old softens and fades as the new sharpens.
    private var swap: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace).combined(with: .opacity)
    }

    var body: some View {
        let grown = content != nil && content != .tiles
        let tall = content == .tiles
        let upright = perch.upright
        // Reading aloud upright is one grid of cells with no gaps between them.
        let layout = upright ? AnyLayout(VStackLayout(spacing: bar == .reading ? 0 : PerchStyle.gap)) : AnyLayout(HStackLayout(spacing: PerchStyle.gap))
        // A busy state gets the resting bar's own box, no more and no less, whatever it holds. (As the
        // bottom row of a wider surface the bar is as wide as that surface, as the actions are.)
        let rest = PerchStyle.busySize(upright: upright)
        // A job waiting its turn says all of what it waits for: lying flat, that bar is as wide as its words.
        // Reading aloud upright sets its controls on one grid of 40-point cells and is as tall as they need
        // to, since in the resting box the last one would be cut off.
        let boxed = bar.isBusy && !tall && !(bar == .working && !upright && perch.waitingLine != nil) && !(bar == .reading && upright)
        Group {
            if bar == .wire, content == nil {
                Capsule().fill(GlassFill.ink.opacity(0.4))
                    .frame(width: upright ? 4 : 56, height: upright ? 56 : 4)
                    .frame(width: upright ? 14 : 72, height: upright ? 72 : 14).contentShape(Rectangle())
                    .accessibilityLabel("Chirp").transition(.opacity)
            } else {
                layout {
                    PerchBird(perch: perch, bar: bar, tall: tall, upright: upright)
                        // Upright with a file held over it, the bird leans toward the file.
                        .rotationEffect(.degrees(upright && perch.invitesDrop ? (perch.spot == .rightEdge ? -18 : 18) : 0))
                    if bar != .bird {
                        BarRule(upright: upright, tall: tall)
                        switch bar {
                        case .actions: ActionButtons(perch: perch, tall: tall, upright: upright, grown: grown)
                        case .dictating: DictatingBar(perch: perch, upright: upright).transition(swap)
                        case .working:
                            // A job waiting its turn says what for, with Cancel.
                            // A file or link being transcribed, and notes being written, can be stopped from here;
                            // other work is only put out of sight.
                            if let waiting = perch.waitingLine {
                                WaitingBar(perch: perch, line: waiting, upright: upright).transition(swap)
                            } else if perch.dictation.importStatus != nil {
                                WorkingBar(perch: perch, line: perch.workingLine, upright: upright, closeLabel: "Cancel") { perch.dictation.cancelImport() }.transition(swap)
                            } else if perch.canStopNotes {
                                // Notes being written can be stopped too: the meeting keeps its transcript.
                                WorkingBar(perch: perch, line: perch.workingLine, upright: upright, closeLabel: "Stop") { perch.recorder.stopNotes() }.transition(swap)
                            } else {
                                WorkingBar(perch: perch, line: perch.workingLine, upright: upright) { perch.workHidden = true }.transition(swap)
                            }
                        case .preparing: WorkingBar(perch: perch, line: "Getting the voice ready", upright: upright) { perch.reader.dismiss() }.transition(swap)
                        case .meeting: MeetingBar(perch: perch, upright: upright).transition(swap)
                        case .reading: ReadingBar(perch: perch, upright: upright).transition(swap)
                        case .wire, .bird: EmptyView()
                        }
                    }
                }
                // The ends of the bar; across it, everything is centred in the bar's thickness.
                .padding(upright ? .vertical : .horizontal, PerchStyle.inset(tall: tall, upright: upright))
                .frame(
                    width: upright ? (tall ? PerchStyle.tallColumn : PerchStyle.barHeight) : boxed && !grown ? rest.width : nil,
                    height: upright ? (boxed ? rest.height : nil) : tall ? PerchStyle.tallBarHeight : boxed ? rest.height : nil,
                    alignment: upright ? .top : .leading)
                .frame(minHeight: upright ? nil : PerchStyle.barHeight)
                .frame(maxWidth: grown ? .infinity : nil, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in perch.dragMoved() }
                .onEnded { _ in perch.dragEnded() }
        )
    }
}

/// The bird, first on the bar in every state, centred across it. Dragging it moves the perch; a right
/// click opens its menu.
private struct PerchBird: View {
    let perch: PerchController
    let bar: PerchBar
    let tall: Bool
    let upright: Bool

    private var mood: BirdMood {
        // While the bird is saying something its beak moves, unless it is busy listening.
        if perch.saying != nil, bar != .dictating { return .speaking }
        switch bar {
        case .dictating: return .listening
        case .working, .preparing: return .thinking
        // A paused reading is quiet: the beak moves only while there is a voice.
        case .reading: return perch.reader.isPlaying ? .speaking : .idle
        default: return .idle
        }
    }

    /// What VoiceOver says for the bird. Its beak also moves while it shows a status or asks about a
    /// call, and that is not reading aloud.
    private var spoken: String {
        if perch.saying != nil, bar != .dictating, !(bar == .reading && perch.reader.isPlaying) { return "Chirp has a message" }
        switch mood {
        case .idle: return "Chirp is ready"
        case .listening: return "Chirp is listening"
        case .thinking: return "Chirp is working"
        case .speaking: return "Chirp is reading aloud"
        case .reading: return "Chirp is reading"
        case .asleep: return "Chirp is resting"
        }
    }

    /// A tucked perch shows the bird's head over the edge it is under.
    private var peek: CGSize {
        guard perch.tucked else { return .zero }
        switch perch.tuckEdge {
        case .leading: return CGSize(width: 11, height: 0)
        case .trailing: return CGSize(width: -11, height: 0)
        default: return CGSize(width: 0, height: -11)
        }
    }

    var body: some View {
        let size: CGFloat = tall ? 34 : PerchStyle.bird
        let box = PerchStyle.birdBox(tall: tall, upright: upright)
        // A Beta build says so under the bird, only while the perch is pointed at.
        let marked = Beta.isOn && tall
        VStack(spacing: 2) {
            Bird(mood: mood, level: bar == .dictating ? (perch.dictation.levels.last ?? 0) : 0, size: size)
                // The bird faces into the screen: docked at the right edge it is turned to face left, so
                // its beak is what shows when the perch is tucked away there.
                .scaleEffect(x: perch.spot == .rightEdge && !perch.dragging ? -1 : 1, y: 1)
                .offset(peek)
            if marked { BetaTag(onGlass: true).transition(.opacity) }
        }
            // Its room along the bar, with the bird in the middle of it.
            .frame(width: upright ? (marked ? 44 : size) : box, height: upright ? box : (marked ? 54 : size))
            .contentShape(Rectangle())
            .help("Drag to move Chirp. Right-click for more.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(marked ? spoken + ", Beta" : spoken)
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Hide for an Hour") { perch.hideForAnHour() }
            .accessibilityAction(named: "Hide Until I Use a Shortcut") { perch.hideUntilShortcut() }
            .accessibilityAction(named: "Move to Bottom Centre") { perch.setSpot(.bottomCentre) }
            .accessibilityAction(named: "Settings") { perch.openSettings() }
    }
}

/// The hairline between the bird and what follows it, and before More. The same length and the same
/// room either side wherever it is.
private struct BarRule: View {
    var upright = false
    var tall = false

    var body: some View {
        let length: CGFloat = tall ? (upright ? 56 : 34) : 20
        Rectangle().fill(GlassFill.line)
            .frame(width: upright ? length : 1, height: upright ? 1 : length)
            .frame(width: upright ? nil : PerchStyle.ruleBox, height: upright ? PerchStyle.ruleBox : nil)
            .accessibilityHidden(true)
    }
}

// MARK: Buttons

/// Whether the pointer is over a view. The perch never becomes the active window, so SwiftUI's own hover
/// does not fire; this reads the pointer the controller tracks.
private struct PointerOver<S: Shape>: ViewModifier {
    let perch: PerchController
    var shape: S
    var colour: Color
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        let over = perch.pointer.map { frame.contains($0) } ?? false
        content
            .background(shape.fill(colour).opacity(over ? 1 : 0))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .animation(.easeOut(duration: 0.12), value: over)
    }
}

extension View {
    /// Lights the view up while the pointer is over it.
    func lit(by perch: PerchController, radius: CGFloat = 9, colour: Color = GlassFill.hover) -> some View {
        modifier(PointerOver(perch: perch, shape: RoundedRectangle(cornerRadius: radius, style: .continuous), colour: colour))
    }

    /// The same, for a round or capsule button.
    func litCapsule(by perch: PerchController) -> some View {
        modifier(PointerOver(perch: perch, shape: Capsule(), colour: GlassFill.hover))
    }
}

/// Every button on the perch gives a little under the pointer when pressed.
struct PerchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A round icon button on the bar.
struct PerchIconButton: View {
    enum Tint { case none, amber, red }

    let perch: PerchController
    let symbol: String
    let label: String
    /// The icon's point size: 15 for an action, 12 for a small control such as × or skip.
    var size: CGFloat = 15
    var tint = Tint.none
    /// The button's own width and height. The close button in a head row is smaller.
    var side: CGFloat = PerchStyle.button
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(symbol).font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint == .amber ? PerchStyle.onAmber : tint == .red ? Color.white : GlassFill.ink)
                .frame(width: side, height: side)
                .background(tint == .amber ? PerchStyle.amber : tint == .red ? PerchStyle.red : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PerchPress())
        .litCapsule(by: perch)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A word button: in a foot row, or on the bar beside a line of status. The primary one is amber.
struct PerchAct: View {
    let perch: PerchController
    let title: String
    var symbol: String?
    var primary = false
    /// The key that does the same, shown only while the perch has the keyboard.
    var key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(symbol).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 12.5, weight: primary ? .semibold : .regular)).lineLimit(1).fixedSize()
                if let key { PerchKey(text: key, onAmber: primary) }
            }
            .foregroundStyle(primary ? PerchStyle.onAmber : GlassFill.ink)
            .padding(.horizontal, 9).frame(height: PerchStyle.act)
            .background(primary ? PerchStyle.amber : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PerchPress())
        .litCapsule(by: perch)
        .accessibilityLabel(title)
    }
}

/// A shortcut, or one key of it, drawn as a small key.
struct PerchKey: View {
    let text: String
    var onAmber = false

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(onAmber ? PerchStyle.onAmber : GlassFill.quiet)
            .padding(.horizontal, 4).frame(height: 17)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(onAmber ? PerchStyle.onAmber.opacity(0.3) : GlassFill.line))
            .accessibilityHidden(true)
    }
}

// MARK: At rest

/// The actions on the bar, then More. With the pointer resting on the bar each grows a name and its
/// shortcut; standing upright they stack.
private struct ActionButtons: View {
    let perch: PerchController
    let tall: Bool
    let upright: Bool
    /// The bar is the bottom row of a wider surface: More goes to the far end.
    let grown: Bool

    var body: some View {
        let active = perch.activeTool
        let along = PerchStyle.moreLength(tall: tall, upright: upright)
        let across = PerchStyle.itemBreadth(tall: tall, upright: upright)
        let tools = perch.tools
        ForEach(tools) { tool in
            ToolButton(perch: perch, tool: tool, tall: tall, upright: upright, on: tool.id == active)
        }
        // With every feature switched off there are no actions, and the hairline after the bird is enough.
        if grown { Spacer(minLength: 0) } else if !tools.isEmpty { BarRule(upright: upright, tall: tall) }
        let open = perch.extendedOpen && !grown
        // The perch ends in a chevron, not a "More" button. Only pressing it opens the
        // extended area, and only pressing it again closes it (no opening on hover).
        Button(action: perch.pressMore) {
            VStack(spacing: tall ? 4 : 0) {
                Image(upright ? "chirp.disclose" : "chirp.chevron").font(.system(size: 12.5, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .frame(height: tall ? 20 : 18)
            }
            .frame(width: upright ? across : along, height: upright ? along : across)
            .contentShape(Rectangle())
        }
        .buttonStyle(PerchPress())
        .lit(by: perch, radius: tall ? 14 : 17)
        .accessibilityLabel("More actions")
        .accessibilityValue(open ? "Open" : "")
        .accessibilityHint(open ? "Closes the extended actions" : "Shows the extended actions")
        .help(open ? "Fewer actions" : "More actions")
        if open {
            ExtendedArea(perch: perch, tall: tall, upright: upright)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: upright ? .top : .leading)))
        }
    }
}

/// The extended area that the chevron slides open: the actions the user put there,
/// on the same glass with no tint, then the small "…" for the one-off items.
private struct ExtendedArea: View {
    let perch: PerchController
    let tall: Bool
    let upright: Bool

    var body: some View {
        let layout = upright ? AnyLayout(VStackLayout(spacing: PerchStyle.gap)) : AnyLayout(HStackLayout(spacing: PerchStyle.gap))
        let across = PerchStyle.itemBreadth(tall: tall, upright: upright)
        let dots = PerchStyle.dotsLength(tall: tall, upright: upright)
        let active = perch.activeTool
        layout {
            ForEach(perch.extendedTools) { tool in
                ToolButton(perch: perch, tool: tool, tall: tall, upright: upright, on: tool.id == active)
            }
            Button(action: perch.showMoreMenu) {
                Image("chirp.more").font(.system(size: 12, weight: .regular)).foregroundStyle(GlassFill.quiet)
                    .frame(width: upright ? across : dots, height: upright ? dots : across)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PerchPress())
            .lit(by: perch, radius: 12)
            .accessibilityLabel("More items")
            .help("Save as a Snippet, the app's writing style, Library, Settings")
        }
        // No tint behind the extended actions: they sit on the same glass as the rest.
        .padding(upright ? .vertical : .horizontal, PerchStyle.areaGap)
        .padding(upright ? .top : .leading, PerchStyle.areaGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More actions")
    }
}

/// One action: an icon on the plain bar; an icon, its name and its shortcut on the taller one.
private struct ToolButton: View {
    let perch: PerchController
    let tool: PerchTool
    let tall: Bool
    let upright: Bool
    /// This is the action in use: the one tinted button.
    let on: Bool

    var body: some View {
        let fixes = tool.id == "Fix" ? perch.fixes : 0
        let along = PerchStyle.itemLength(tall: tall, upright: upright)
        let across = PerchStyle.itemBreadth(tall: tall, upright: upright)
        Button(action: tool.action) {
            VStack(spacing: tall ? (upright ? 3 : 4) : 0) {
                ZStack {
                    // With suggestions waiting, the pencil gives its place to how many there are: the
                    // same slot, so the bar keeps its shape.
                    if fixes > 0, !on {
                        Text(fixes > 99 ? "99+" : "\(fixes)").font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(PerchStyle.onAmber)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                            .background(PerchStyle.amber, in: Capsule())
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else {
                        Image(tool.symbol).font(.system(size: 14.5, weight: .regular))
                            .foregroundStyle(on ? PerchStyle.onAmber : GlassFill.ink)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .frame(width: tall ? 30 : PerchStyle.button, height: tall ? 20 : PerchStyle.button)
                .background(on && !tall ? PerchStyle.amber : Color.clear, in: Circle())
                .background(on && tall ? PerchStyle.amber : Color.clear, in: Capsule())
                .animation(PerchStyle.quick, value: fixes > 0)
                if tall {
                    Text(name(fixes)).font(.system(size: 11.5)).lineLimit(1).fixedSize()
                    // The same height whether it holds keys or a few words, so the row lines up.
                    Text(tool.key ?? (tool.id == "Meeting" ? perch.detector.currentOffer?.title ?? "" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(GlassFill.quiet).lineLimit(1).frame(maxWidth: 66).frame(height: 13)
                }
            }
            .frame(width: upright ? across : along, height: upright ? along : across)
            .contentShape(Rectangle())
        }
        .buttonStyle(PerchPress())
        .lit(by: perch, radius: tall ? 14 : 17)
        .accessibilityLabel(fixes > 0 ? "\(tool.label), \(fixes) \(fixes == 1 ? "suggestion" : "suggestions")" : tool.label)
        .accessibilityHint(tool.key.map { "Shortcut \($0)" } ?? "")
        .help(fixes > 0 ? "\(fixes) writing \(fixes == 1 ? "suggestion" : "suggestions")" : tool.label)
    }

    /// The name under the icon. Fix says how many suggestions are waiting, or that checks are off here.
    private func name(_ fixes: Int) -> String {
        guard tool.id == "Fix" else { return tool.id }
        return fixes > 0 ? "Fix \(fixes)" : perch.underlines.off != nil ? "Fix (off)" : "Fix"
    }
}

// MARK: While Chirp is busy

/// Sound levels as bars that fill the room they are given along the bar: side by side lying flat,
/// one under another standing upright. Never longer than 120 points.
private struct LevelMeter: View {
    /// Recent levels, oldest first, each 0…1.
    var levels: [Double]
    var colour: Color
    var upright: Bool

    var body: some View {
        GeometryReader { geo in
            let length = upright ? geo.size.height : geo.size.width
            let count = max(1, min(24, Int((length + 2.5) / 5)))
            let recent = Array(levels.suffix(count))
            let layout = upright ? AnyLayout(VStackLayout(spacing: 2.5)) : AnyLayout(HStackLayout(spacing: 2.5))
            layout {
                ForEach(0..<count, id: \.self) { i in
                    let level = i < recent.count ? max(0, min(1, recent[i])) : 0
                    Capsule().fill(colour).frame(width: upright ? 4 + 18 * level : 2.5, height: upright ? 2.5 : 4 + 18 * level)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.1), value: recent)
        }
        .frame(minWidth: upright ? 22 : 8, maxWidth: upright ? 22 : 120, minHeight: upright ? 8 : 22, maxHeight: upright ? 120 : 22)
        .padding(upright ? .vertical : .horizontal, 5)
        .layoutPriority(1)
        .accessibilityHidden(true)
    }
}

/// Three dots that take turns, for work with no measure of how far along it is.
private struct WorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { timeline in
            let step = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(GlassFill.quiet).frame(width: 4, height: 4)
                        .opacity([1, 0.6, 0.3][(i - step + 3) % 3])
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A clock that fits one slot on the bar: figures that do not jiggle as they change, and that shrink
/// to stay inside the slot once a recording has passed the hour.
private struct BarClock: View {
    let seconds: Double
    var strong = false

    var body: some View {
        // The figures change without rolling. With `.contentTransition(.numericText())` every change of
        // the clock left the figures it had drawn in memory for good: 20 MB over 100 reads aloud, and
        // 2.3 MB for each change when the time left moved by several figures.
        Text(seconds.clock).font(.system(size: 11.5, weight: strong ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(strong ? GlassFill.ink : GlassFill.quiet)
            .lineLimit(1).minimumScaleFactor(0.65)
            .frame(width: PerchStyle.button, height: 16)
    }
}

// Every busy bar below is laid out in the resting bar's box (PerchBarRow gives it that exact frame):
// after the bird and the hairline there is room for six slots, as at rest. The control that replaces
// the pressed action stands in that action's slot, the way out is in the last slot, and whatever is
// between stretches or is left empty. Lying flat and standing upright they hold the same things in
// the same order.

/// Listening: Finish where Dictate stood, the level, how long, and Cancel at the end.
private struct DictatingBar: View {
    let perch: PerchController
    var upright = false

    var body: some View {
        let d = perch.dictation
        PerchIconButton(perch: perch, symbol: "chirp.stop", label: "Finish dictating", size: 12, tint: .amber) { d.finish() }
        LevelMeter(levels: d.levels, colour: PerchStyle.amber, upright: upright)
            .accessibilityLabel("Listening")
        Spacer(minLength: 0)
        BarClock(seconds: d.elapsed)
        PerchIconButton(perch: perch, symbol: "chirp.close", label: "Cancel", size: 12) { d.cancel() }
    }
}

/// Working: what Chirp is doing, and a way to put it out of sight at the end. Upright there is no room
/// for the words: the bird thinks, the dots turn, and the words are there for VoiceOver and on pointing.
private struct WorkingBar: View {
    let perch: PerchController
    let line: String
    var upright = false
    /// What the × does, for its tip and for VoiceOver.
    var closeLabel = "Hide"
    let hide: () -> Void

    var body: some View {
        if !upright {
            Text(line).lineLimit(1).truncationMode(.tail).padding(.leading, 6).padding(.trailing, 4)
                .contentTransition(.opacity).layoutPriority(1)
        }
        WorkingDots()
            .frame(width: upright ? PerchStyle.button : nil, height: upright ? PerchStyle.button : nil)
            .accessibilityElement().accessibilityLabel(line).help(line)
        Spacer(minLength: 0)
        PerchIconButton(perch: perch, symbol: "chirp.close", label: closeLabel, size: 12, action: hide)
    }
}

/// A red light that breathes while a recording runs.
private struct RecordingLight: View {
    /// Something is wrong with the recording (no sound arriving, say): the light turns to the caution colour.
    var warning: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colour = warning ? Color.caution : PerchStyle.red
        ZStack {
            Circle().fill(colour.opacity(0.28)).frame(width: 16, height: 16).scaleEffect(breathing ? 1 : 0.55).opacity(breathing ? 0 : 1)
            Circle().fill(colour).frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathing = true }
        }
        .accessibilityLabel(warning ? "Recording, with a problem" : "Recording")
    }
}

/// Recording. Lying flat: the light, what it is ("Voice note" or "Meeting"), the
/// clock, the level, Notes, and Stop at the end. With the notes open the clock and Stop are in the
/// panel's head, and the bar says "Recording" with Notes lit. Upright: the light, the clock, Stop, the
/// level, and Notes at the foot of the column.
private struct MeetingBar: View {
    let perch: PerchController
    var upright = false

    var body: some View {
        let r = perch.recorder
        let open = perch.showMeetingNotes
        if upright {
            RecordingLight(warning: r.warning != nil).frame(height: 14).padding(.top, 4)
            BarClock(seconds: r.elapsed, strong: true)
            PerchIconButton(perch: perch, symbol: "chirp.stop", label: "Stop recording", size: 12, tint: .red) { r.stop() }
            LevelMeter(levels: r.levels, colour: GlassFill.quiet, upright: true)
            Spacer(minLength: 0)
            PerchIconButton(perch: perch, symbol: "chirp.note", label: "Notes", size: 13, tint: open ? .amber : .none) { perch.showMeetingNotes.toggle() }
                .help("Type a note, or keep a picture of the window in front")
        } else {
            RecordingLight(warning: r.warning != nil).frame(width: 8, height: 14).padding(.leading, 8).padding(.trailing, 6)
            Text(open ? (r.kind == .meeting ? "Recording" : "Note") : r.kind.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                .accessibilityIdentifier("perch.bar.kind")
            if !open {
                Text(r.elapsed.clock).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
                    .padding(.leading, 6)
                    .accessibilityLabel("Recording for \(r.elapsed.clock)")
            }
            LevelMeter(levels: r.levels, colour: GlassFill.quiet, upright: false)
            Spacer(minLength: 0)
            PerchAct(perch: perch, title: "Notes", symbol: open ? "chirp.note" : nil, primary: open) { perch.showMeetingNotes.toggle() }
                .help("Type a note, or keep a picture of the window in front")
            if !open {
                PerchIconButton(perch: perch, symbol: "chirp.stop", label: "Stop recording", size: 12, tint: .red) { r.stop() }
            }
        }
    }
}

/// Waiting its turn: what the job is waiting for, and Cancel.
private struct WaitingBar: View {
    let perch: PerchController
    let line: String
    var upright = false

    var body: some View {
        if upright {
            WorkingDots().frame(width: PerchStyle.button, height: PerchStyle.button)
                .accessibilityElement().accessibilityLabel(line).help(line)
            Spacer(minLength: 0)
            PerchIconButton(perch: perch, symbol: "chirp.close", label: "Cancel", size: 12) { Jobs.shared.cancelFirstWaiting() }
        } else {
            Text(line).lineLimit(1).fixedSize().padding(.leading, 6).padding(.trailing, 4)
                .accessibilityIdentifier("perch.bar.waiting")
            Spacer(minLength: 0)
            PerchAct(perch: perch, title: "Cancel") { Jobs.shared.cancelFirstWaiting() }
        }
    }
}

/// Reading aloud: how long is left with the speed (a menu for the voice and the speed), back, Play or
/// Pause where Read stood, forward, Summarize, and Stop at the end.
private struct ReadingBar: View {
    let perch: PerchController
    var upright = false

    /// One cell of the upright grid: every control has the same room, centred in the column.
    static let cell: CGFloat = 40

    /// The time left as the upright column shows it, on its own line: minutes and seconds, or hours and
    /// minutes past an hour ("5:07", "1:02"), so it fits the column without shrinking.
    static func shortLeft(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d", s / 3600, (s % 3600) / 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder var body: some View {
        if upright { column } else { row }
    }

    /// Upright: the time left with "left" under it, then speed as its own button, back, play, forward,
    /// Say it as, Summarize, and Stop last, each in its own 40-point cell. Nothing squeezes or clips.
    @ViewBuilder private var column: some View {
        let reader = perch.reader
        let remaining = reader.timeLeft
        let done = max(0, min(1, reader.progress))
        let voice = Voice.voices.first { $0.id == reader.voiceID }?.name ?? "Voice"
        let width = PerchStyle.barHeight
        Button(action: perch.showVoiceMenu) {
            VStack(spacing: 0) {
                Text(Self.shortLeft(remaining)).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
                Text(remaining >= 3600 ? "h left" : "left").font(.system(size: 10)).foregroundStyle(GlassFill.quiet).lineLimit(1).fixedSize()
            }
            .frame(width: width, height: Self.cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(PerchPress())
        .accessibilityLabel("Voice")
        .accessibilityValue("\(voice), \(remaining.clock) left, \(Int(done * 100)) percent read")
        .help("\(remaining.clock) left. Change the voice.")
        Button(action: perch.showVoiceMenu) {
            Text(reader.speed.speedLabel).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                .padding(.horizontal, 7).frame(height: 20)
                .background(GlassFill.row, in: Capsule())
                .frame(width: width, height: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(PerchPress())
        .accessibilityLabel("Speed")
        .accessibilityValue(reader.speed.speedLabel)
        .help("Change the speed or the voice")
        Group {
            PerchIconButton(perch: perch, symbol: "chirp.back", label: "Back a sentence", size: 12) { reader.skip(-1) }
            PerchIconButton(perch: perch, symbol: reader.isPlaying ? "chirp.pause" : "chirp.play", label: reader.isPlaying ? "Pause" : "Play", size: 13, tint: .amber) { reader.toggle() }
            PerchIconButton(perch: perch, symbol: "chirp.forward", label: "Forward a sentence", size: 12) { reader.skip(1) }
            PerchIconButton(perch: perch, symbol: "chirp.sayAs", label: "Say it as", size: 13) {
                if reader.sayItAs == nil { reader.openSayItAs(place: .perch) } else { reader.closeSayItAs() }
            }
            .help("Say it as: how a word just spoken should sound")
            if Features.on(.summarize) {
                PerchIconButton(perch: perch, symbol: "chirp.summarize", label: "Summarize this", size: 13) { perch.summarizeReading() }
            }
            PerchIconButton(perch: perch, symbol: "chirp.close", label: "Stop reading", size: 12) { reader.dismiss() }
        }
        .frame(width: width, height: Self.cell)
    }

    @ViewBuilder private var row: some View {
        let reader = perch.reader
        // Asked for once: working it out goes through the rest of the document.
        let remaining = reader.timeLeft
        let done = max(0, min(1, reader.progress))
        let voice = Voice.voices.first { $0.id == reader.voiceID }?.name ?? "Voice"
        Button(action: perch.showVoiceMenu) {
            VStack(spacing: 0) {
                BarClock(seconds: remaining)
                Text(reader.speed.speedLabel).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).frame(height: 13)
            }
            .frame(width: PerchStyle.button, height: PerchStyle.button)
            .background(GlassFill.row, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PerchPress())
        .accessibilityLabel("Voice and speed")
        .accessibilityValue("\(voice), \(reader.speed.speedLabel), \(remaining.clock) left, \(Int(done * 100)) percent read")
        .help("\(remaining.clock) left. Change the voice or the speed.")
        PerchIconButton(perch: perch, symbol: "chirp.back", label: "Back a sentence", size: 12) { reader.skip(-1) }
        PerchIconButton(perch: perch, symbol: reader.isPlaying ? "chirp.pause" : "chirp.play", label: reader.isPlaying ? "Pause" : "Play", size: 13, tint: .amber) { reader.toggle() }
        PerchIconButton(perch: perch, symbol: "chirp.forward", label: "Forward a sentence", size: 12) { reader.skip(1) }
        // A name read wrong is fixed where it is heard.
        PerchIconButton(perch: perch, symbol: "chirp.sayAs", label: "Say it as", size: 13) {
            if reader.sayItAs == nil { reader.openSayItAs(place: .perch) } else { reader.closeSayItAs() }
        }
        .help("Say it as: how a word just spoken should sound")
        if Features.on(.summarize) {
            PerchIconButton(perch: perch, symbol: "chirp.summarize", label: "Summarize this", size: 13) { perch.summarizeReading() }
        }
        Spacer(minLength: 0)
        PerchIconButton(perch: perch, symbol: "chirp.close", label: "Stop reading", size: 12) { reader.dismiss() }
    }
}
