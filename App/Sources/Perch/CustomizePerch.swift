import ChirpCore
import SwiftUI

/// Customize Perch, like Finder's and Safari's Customize Toolbar: drag actions
/// onto the perch (five at most) or into the extended area that More opens, drag to change the order, drag
/// off to remove; Default Set puts it back. The perch on screen follows as you drag; order and places are
/// saved. It hangs from the Settings window at Perch, from either place it is opened.
struct CustomizePerchSheet: View {
    @Environment(PerchController.self) private var perch
    /// The place a drag is over, to show where it will land.
    @State private var over: String?
    /// Goes up with every change to the arrangement while the sheet is open. A drag carries the version it
    /// began in, and a drop from an older one is ignored: a drop arriving after Default Set would
    /// otherwise put back the order from before it.
    @State private var version = 0

    private var on: FeatureSet { Features.shared.set }

    var body: some View {
        let shown = perch.shownActions
        VStack(alignment: .leading, spacing: 0) {
            Text("Customize Perch").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Drag actions onto the perch or into the extended area. Drag to change the order; drag off to remove.")
                .font(.system(size: 12.5)).foregroundStyle(Color.quiet).padding(.top, 4)

            label("On the perch · up to five")
            HStack(spacing: 2) {
                Bird(mood: .idle, level: 0, size: 26).padding(.horizontal, 8).accessibilityHidden(true)
                Rectangle().fill(Color.ink.opacity(0.12)).frame(width: 1, height: 22).padding(.horizontal, 4)
                ForEach(Array(shown.bar.enumerated()), id: \.element) { index, action in
                    tile(action).dropDestination(for: String.self) { items, _ in drop(items, in: .bar, before: action) } isTargeted: { over = $0 ? "bar.\(index)" : (over == "bar.\(index)" ? nil : over) }
                        .overlay(alignment: .leading) { if over == "bar.\(index)" { insertionMark } }
                }
                endSlot(.bar, count: shown.bar.count, full: shown.bar.count >= PerchArrangement.barLimit)
                Rectangle().fill(Color.ink.opacity(0.12)).frame(width: 1, height: 22).padding(.horizontal, 4)
                fixedTile("chirp.chevron", "")
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.ink.opacity(0.12)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("On the perch")

            label("In the extended area · opens from the chevron")
            HStack(spacing: 2) {
                ForEach(Array(shown.extended.enumerated()), id: \.element) { index, action in
                    tile(action).dropDestination(for: String.self) { items, _ in drop(items, in: .extended, before: action) } isTargeted: { over = $0 ? "ext.\(index)" : (over == "ext.\(index)" ? nil : over) }
                        .overlay(alignment: .leading) { if over == "ext.\(index)" { insertionMark } }
                }
                endSlot(.extended, count: shown.extended.count, full: false)
                fixedTile("chirp.more", "")
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.ink.opacity(0.1)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("In the extended area")

            label("All actions")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 6) {
                ForEach(PerchAction.allCases.filter { $0.isOn(on) }) { action in
                    tile(action, inAll: true)
                }
            }
            .padding(8)
            .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Dragged off the perch onto the list of all actions: taken off.
            .dropDestination(for: String.self) { items, _ in
                over = nil
                for item in items { if let drag = PerchDrag(payload: item), drag.applies(in: version) { perch.arrangement.remove(drag.action) } }
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("All actions")

            label("Or drag the default set")
            HStack(spacing: 2) {
                Bird(mood: .idle, level: 0, size: 20).padding(.horizontal, 6)
                ForEach(PerchArrangement.standard.bar.filter { $0.isOn(on) }) { Image(perch.tool($0).symbol).font(.system(size: 11)).frame(width: 22) }
                Image("chirp.chevron").font(.system(size: 10, weight: .semibold)).frame(width: 22)
                ForEach(PerchArrangement.standard.extended.filter { $0.isOn(on) }) { Image(perch.tool($0).symbol).font(.system(size: 11)).frame(width: 22) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.ink.opacity(0.12)))
            .draggable("default") { Text("Default Set").padding(6) }
            .accessibilityHidden(true)
            .padding(.bottom, 2)

            HStack(alignment: .center) {
                Text("Fewer than five is fine. An action whose feature is off is not shown here or on the perch.")
                    .font(.system(size: 12)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Default Set") { perch.arrangement = .standard }
                    .accessibilityIdentifier("customize.default")
                Button("Done") { perch.customizing = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("customize.done")
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 640)
        // The default set dropped onto either row puts it back.
        .dropDestination(for: String.self) { items, _ in
            guard items.contains("default") else { return false }
            perch.arrangement = .standard
            return true
        }
        .onExitCommand { perch.customizing = false }
        .onChange(of: perch.arrangement) { version += 1 }
        .accessibilityIdentifier("customize.sheet")
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4).foregroundStyle(Color.quiet)
            .padding(.top, 16).padding(.bottom, 6)
    }

    /// Where a dragged action will land: a line before the tile it is over.
    private var insertionMark: some View {
        Capsule().fill(Color.amber).frame(width: 3, height: 34).offset(x: -2).accessibilityHidden(true)
    }

    /// One action, to drag. Its menu does the same without a drag, for the keyboard and VoiceOver.
    private func tile(_ action: PerchAction, inAll: Bool = false) -> some View {
        let tool = perch.tool(action)
        let place = perch.arrangement.place(of: action)
        return VStack(spacing: 3) {
            Image(tool.symbol).font(.system(size: 13)).frame(height: 18)
            Text(action.title).font(.system(size: 10.5)).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 66, height: 46)
        .foregroundStyle(inAll && place != nil ? Color.quiet : Color.ink)
        .contentShape(Rectangle())
        .draggable(PerchDrag(action: action, version: version).payload) {
            VStack(spacing: 2) {
                Image(tool.symbol)
                Text(action.title).font(.system(size: 10.5))
            }
            .padding(6)
        }
        .contextMenu {
            Button("Put on the Perch") { perch.arrangement.put(action, in: .bar, at: perch.arrangement.bar.count) }
                .disabled(place == .bar)
            Button("Put in the Extended Area") { perch.arrangement.put(action, in: .extended, at: perch.arrangement.extended.count) }
                .disabled(place == .extended)
            if let place {
                Divider()
                Button("Move Left") { move(action, in: place, by: -1) }
                Button("Move Right") { move(action, in: place, by: 1) }
                Divider()
                Button("Remove") { perch.arrangement.remove(action) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityValue(place == .bar ? "On the perch" : place == .extended ? "In the extended area" : "Not placed")
        .accessibilityAction(named: "Put on the Perch") { perch.arrangement.put(action, in: .bar, at: perch.arrangement.bar.count) }
        .accessibilityAction(named: "Put in the Extended Area") { perch.arrangement.put(action, in: .extended, at: perch.arrangement.extended.count) }
        .accessibilityAction(named: "Remove") { perch.arrangement.remove(action) }
        .accessibilityIdentifier("customize.\(inAll ? "all" : "placed").\(action.rawValue)")
    }

    /// The end of a row: dropping there puts the action last. In the extended area it says "Drop here".
    private func endSlot(_ place: PerchArrangement.Place, count: Int, full: Bool) -> some View {
        Group {
            if place == .extended {
                Text("Drop here").font(.system(size: 11)).foregroundStyle(Color.quiet)
                    .frame(width: 66, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.ink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                Color.clear.frame(width: full ? 8 : 40, height: 40)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in drop(items, in: place, before: nil) } isTargeted: { over = $0 ? "\(place.rawValue).end" : (over == "\(place.rawValue).end" ? nil : over) }
        .accessibilityHidden(true)
    }

    private func fixedTile(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(symbol).font(.system(size: 13)).frame(height: 18)
            if !title.isEmpty { Text(title).font(.system(size: 10.5)) }
        }
        .frame(width: title.isEmpty ? 30 : 50, height: 46)
        .foregroundStyle(Color.quiet)
        .accessibilityHidden(true)
    }

    private func drop(_ items: [String], in place: PerchArrangement.Place, before anchor: PerchAction?) -> Bool {
        over = nil
        if items.contains("default") {
            perch.arrangement = .standard
            return true
        }
        // Lands next to the tile it was let go over; a drag that began before the last change is ignored.
        guard let drag = items.first.flatMap(PerchDrag.init(payload:)), drag.applies(in: version) else { return false }
        var arranged = perch.arrangement
        arranged.drop(drag.action, in: place, before: anchor)
        perch.arrangement = arranged
        return true
    }

    private func move(_ action: PerchAction, in place: PerchArrangement.Place, by step: Int) {
        let all = place == .bar ? perch.arrangement.bar : perch.arrangement.extended
        guard let at = all.firstIndex(of: action) else { return }
        perch.arrangement.put(action, in: place, at: max(0, at + step))
    }
}

/// Settings › Perch › Actions: what is on the perch and in More, and the button that
/// opens Customize Perch.
struct PerchActionsRow: View {
    @Environment(PerchController.self) private var perch

    var body: some View {
        let shown = perch.shownActions
        LabeledContent {
            Button("Customize Perch…") { perch.customizing = true }
                .accessibilityIdentifier("settings.customizePerch")
        } label: {
            Text("On the perch and in the extended area")
            Text(summary(shown))
        }
    }

    private func summary(_ shown: (bar: [PerchAction], extended: [PerchAction])) -> String {
        let bar = shown.bar.isEmpty ? "None on the perch" : "\(shown.bar.count == 1 ? "One" : ["Two", "Three", "Four", "Five"][shown.bar.count - 2]) on the perch: " + shown.bar.map(\.title).joined(separator: ", ")
        let more = shown.extended.isEmpty ? "" : ". The chevron opens " + ListFormatter.localizedString(byJoining: shown.extended.map(\.title))
        return bar + more
    }
}
