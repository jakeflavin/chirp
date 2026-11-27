import SwiftUI

// The open item's actions, in its header under the title. The window's toolbar holds only what acts on the app:
// the sidebar button, Add and Search. Like Mail and Notes, what acts on one item sits with that item.
//
// In order: the view switch (Notes | Transcript, or Reading view | Original), the item's own actions,
// then "…" for the rest. When the pane is narrow the actions lose their names first (each keeps a
// tooltip), then fold into "…"; nothing is cut to "…" in the middle of a word.

/// One entry of a menu in an item's header: the "…" menu, or a button's own menu (Export).
struct HeaderMenuItem: Identifiable {
    var id: String
    var title: String
    var symbol: String?
    var destructive = false
    var disabled = false
    /// A line above it in the menu.
    var dividerBefore = false
    /// A tick beside it (the folder an item is in).
    var checked = false
    /// A menu of its own (Move to Folder, Export once folded).
    var children: [HeaderMenuItem]?
    var run: () -> Void = {}
}

/// A button in an item's header. With `menu` it opens that menu (Export).
struct HeaderAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    /// The tooltip when it shows its name; with only its icon the tooltip is its name.
    var help: String = ""
    /// Red and bold: "Stop recording".
    var stop = false
    /// Kept out of the "…" menu however narrow the pane is (Stop recording).
    var staysOut = false
    var disabled = false
    var menu: [HeaderMenuItem]?
    var run: () -> Void = {}

    /// The same action as an entry of the "…" menu, once the header has folded.
    var asMenuItem: HeaderMenuItem {
        HeaderMenuItem(id: id, title: title, symbol: symbol, disabled: disabled, children: menu, run: run)
    }
}

/// The parts of an item's header that every kind shares, made by the Library window, which owns copying,
/// exporting, pinning, folders and deleting. Each detail page adds its own (Summarize, Save as Audio…).
struct ItemHeaderParts {
    /// Copy, Export and, where it applies, Read aloud.
    var actions: [HeaderAction] = []
    /// Pin, Move to Folder, Attach a File… where it applies, then Delete… last.
    var more: [HeaderMenuItem] = []

    /// These parts with a page's own actions after the shared ones, and its own menu entries before Delete.
    func adding(actions extra: [HeaderAction] = [], more extraMore: [HeaderMenuItem] = [], first: [HeaderAction] = []) -> ItemHeaderParts {
        var out = self
        out.actions = first + actions + extra
        if let delete = more.lastIndex(where: { $0.destructive }) {
            out.more.insert(contentsOf: extraMore, at: delete)
        } else {
            out.more += extraMore
        }
        return out
    }
}

/// Two views of one item side by side, the shown one raised: Notes | Transcript, Reading view | Original.
/// A view that cannot be shown stays in its place, greyed, and says why on hover and to VoiceOver.
struct ViewSwitch: View {
    struct Option {
        var title: String
        /// Why this view cannot be shown, when it cannot.
        var unavailable: String?
    }

    /// What the switch is, for VoiceOver ("View", "Show").
    let label: String
    let options: [Option]
    @Binding var selection: Int
    var identifier: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                segment(index, option)
            }
        }
        .padding(2)
        .frame(height: 28)
        .background(Color.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func segment(_ index: Int, _ option: Option) -> some View {
        let on = selection == index
        let off = option.unavailable != nil
        return Button {
            if !off { selection = index }
        } label: {
            Text(option.title)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(off ? Color.quiet.opacity(0.7) : Color.ink.opacity(0.9))
                .padding(.horizontal, 11).frame(height: 24)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.card)
                            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ink.opacity(0.1), lineWidth: 0.5))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(off)
        // A disabled control shows no tooltip of its own, so the reason sits on a clear layer over it.
        .overlay {
            if let why = option.unavailable { Color.clear.contentShape(Rectangle()).help(why) }
        }
        .accessibilityLabel(option.title)
        .accessibilityHint(option.unavailable ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(index)")
    }
}

/// An item's actions in its header. As wide as there is room for: with names, then as icons with
/// tooltips, then folded into "…" (those marked `staysOut` stay out, as icons).
struct ItemActionBar<Leading: View>: View {
    let actions: [HeaderAction]
    let more: [HeaderMenuItem]
    @ViewBuilder var leading: () -> Leading

    init(actions: [HeaderAction], more: [HeaderMenuItem], @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self.actions = actions
        self.more = more
        self.leading = leading
    }

    enum Fit { case names, icons, folded }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.names)
            row(.icons)
            row(.folded)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
        .accessibilityIdentifier("item.actions")
    }

    private func row(_ fit: Fit) -> some View {
        let shown = fit == .folded ? actions.filter(\.staysOut) : actions
        let folded = fit == .folded ? actions.filter { !$0.staysOut }.map(\.asMenuItem) : []
        var menu = folded
        if !folded.isEmpty, var first = more.first {
            first.dividerBefore = true
            menu += [first] + more.dropFirst()
        } else {
            menu += more
        }
        return HStack(spacing: 2) {
            leading().padding(.trailing, 6)
            ForEach(shown) { action in
                HeaderButton(action: action, showsName: fit == .names)
            }
            if !menu.isEmpty { MoreMenu(items: menu) }
        }
        .fixedSize()
    }
}

/// One button in an item's header: its icon and name, or its icon alone with its name as the tooltip.
private struct HeaderButton: View {
    let action: HeaderAction
    let showsName: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if let menu = action.menu {
                Menu {
                    MenuEntries(items: menu)
                } label: {
                    face
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            } else {
                Button(action: action.run) { face }.buttonStyle(.plain)
            }
        }
        .disabled(action.disabled)
        .opacity(action.disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(showsName ? action.help : action.title.replacingOccurrences(of: "…", with: ""))
        .accessibilityLabel(action.title.replacingOccurrences(of: "…", with: ""))
        .accessibilityIdentifier("item.\(action.id)")
    }

    private var face: some View {
        HStack(spacing: 6) {
            Image(action.symbol).font(.system(size: 11.5, weight: action.stop ? .bold : .medium))
                .frame(width: 14)
            if showsName {
                Text(action.title).font(.system(size: 12.5, weight: action.stop ? .semibold : .regular)).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(action.stop ? Color.spelling : Color.ink.opacity(0.88))
        .padding(.horizontal, showsName ? 9 : 0)
        .frame(width: showsName ? nil : 28, height: 28)
        .background(hovering ? Color.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// "…": the rest of what can be done to the item.
struct MoreMenu: View {
    let items: [HeaderMenuItem]
    var label = "More actions"
    @State private var hovering = false

    var body: some View {
        Menu {
            MenuEntries(items: items)
        } label: {
            Image("chirp.more").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(hovering ? Color.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
        .help("More")
        .accessibilityLabel(label)
        .accessibilityIdentifier("item.more")
    }
}

/// The entries of a menu, with their dividers and menus inside menus.
struct MenuEntries: View {
    let items: [HeaderMenuItem]

    var body: some View {
        ForEach(items) { item in
            if item.dividerBefore { Divider() }
            if let children = item.children {
                Menu {
                    MenuEntries(items: children)
                } label: {
                    entryLabel(item)
                }
                .disabled(item.disabled)
            } else {
                Button(role: item.destructive ? .destructive : nil, action: item.run) {
                    entryLabel(item)
                }
                .disabled(item.disabled)
            }
        }
    }

    @ViewBuilder private func entryLabel(_ item: HeaderMenuItem) -> some View {
        if item.checked {
            Label(item.title, image: "chirp.check")
        } else if let symbol = item.symbol {
            Label(item.title, image: symbol)
        } else {
            Text(item.title)
        }
    }
}

/// A line under an item's header offering to put something right ("No copy of this page was kept…").
struct HeaderOffer: View {
    let lead: String
    let rest: String
    let button: String
    var symbol: String?
    var busy = false
    let action: () -> Void

    var body: some View {
        // Side by side where there is room; in a narrow pane the button goes under the words, never cut.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                words.fixedSize()
                Spacer(minLength: 8)
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                words.fixedSize(horizontal: false, vertical: true)
                controls
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var words: some View {
        Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(Color.ink))\(Text(rest).foregroundStyle(Color.quiet))")
            .font(.system(size: 12.5))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Button(action: action) {
                HStack(spacing: 6) {
                    if let symbol { Image(symbol).font(.system(size: 11, weight: .medium)) }
                    Text(button).font(.system(size: 12.5)).lineLimit(1)
                }
                .foregroundStyle(Color.ink.opacity(0.9))
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.ink.opacity(0.16), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .fixedSize()
        }
    }
}
