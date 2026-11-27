import ChirpCore
import SwiftUI

/// A folder: everything in it, of any kind, newest first. A row opens its item on the page that kind
/// lives on; its menu pins it, moves it to another folder, takes it out of this one, or deletes it. The
/// folder's own actions are in its header: Rename, New Folder, Delete Folder….
struct FolderPage: View {
    @Environment(AppModel.self) private var app
    let folder: Folder?
    let items: [SavedItem]
    let folders: [Folder]
    let pin: (SavedItem) -> Void
    let move: (SavedItem, Int64?) -> Void
    let newFolder: (SavedItem) -> Void
    let askDelete: (SavedItem) -> Void
    /// Rename, New Folder and Delete Folder….
    var actions: [HeaderAction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceLine(symbol: "chirp.folder", text: "Folder")
                .padding(.leading, PageLayout.gutter).padding(.top, 6)
            PageHeader(title: folder?.name ?? "Folder", subtitle: Self.subtitle(items))
                .padding(.top, -4)
            if !actions.isEmpty {
                ItemActionBar(actions: actions, more: [])
                    .padding(.leading, PageLayout.gutter - 9).padding(.trailing, PageLayout.gutter).padding(.top, 8)
                    .accessibilityIdentifier("folder.actions")
            }
            if items.isEmpty {
                EmptyPage("This folder is empty", line: "Drag items here, or use Move to Folder on any item.", look: .down)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.groups(items), id: \.title) { group in
                            SectionHeading(group.title, count: group.items.count)
                            ForEach(group.items, id: \.listID) { item in row(item) }
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, PageLayout.gutter).padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paper)
        .accessibilityIdentifier("folder.page")
    }

    private func row(_ item: SavedItem) -> some View {
        ItemRow(
            symbol: LibrarySection.holding(item.kind).symbol, title: LibraryRows.title(item),
            meta: LibraryRows.meta(item, kind: true) + (item.starred ? " · pinned" : "")
        ) {
            HStack(spacing: 2) {
                IconButton(symbol: "chirp.open", label: "Open") { app.open(item) }
                Menu {
                    Button(item.starred ? "Unpin" : "Pin") { pin(item) }
                    Menu("Move to Folder") {
                        ForEach(folders) { other in
                            Button {
                                move(item, other.id)
                            } label: {
                                if item.folderID == other.id { Label(other.name, image: "chirp.check") } else { Text(other.name) }
                            }
                        }
                        Divider()
                        Button("New Folder…") { newFolder(item) }
                    }
                    Button("Remove from Folder") { move(item, nil) }
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
    }

    /// "5 items · 2 meetings, 2 documents, 1 note"; "Folder · empty" for an empty one.
    static func subtitle(_ items: [SavedItem]) -> String {
        guard !items.isEmpty else { return "Folder · empty" }
        func counted(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? "1 \(one)" : "\(n) \(many)" }
        func count(_ kinds: ItemKind...) -> Int { items.filter { kinds.contains($0.kind) }.count }
        let kinds = [
            counted(count(.meeting), "meeting", "meetings"), counted(count(.document, .note), "document", "documents"),
            counted(count(.voiceNote), "note", "notes"), counted(count(.dictation), "dictation", "dictations"),
        ].compactMap { $0 }
        return (items.count == 1 ? "1 item" : "\(items.count) items") + " · " + kinds.joined(separator: ", ")
    }

    /// The last seven days, then everything before.
    static func groups(_ items: [SavedItem]) -> [(title: String, items: [SavedItem])] {
        let weekAgo = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400)
        let week = items.filter { $0.createdAt >= weekAgo }
        let earlier = items.filter { $0.createdAt < weekAgo }
        return [("This week", week), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }
}
