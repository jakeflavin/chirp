import AppKit
import Combine
import ChirpCore
import SwiftUI
import UniformTypeIdentifiers

/// What the window can show. The raw values are used by links and scripts, so a case is never renamed.
enum LibrarySection: String, CaseIterable, Identifiable {
    case home
    /// Every saved item together: "All", first under Library in the sidebar, and "See all" on Home.
    case everything
    /// `notes` is the Voice notes page (it keeps the name it had when voice notes and typed notes shared a page).
    case meetings, notes, dictations, documents
    case dictionary, snippets, style
    /// Chirp's own checked editor. Not a page of the app: it is there only in a test copy, for the
    /// end-to-end checks of the writing engine.
    case draft
    /// One folder: everything in it, of any kind. Which folder is `AppModel.folderID`.
    case folder
    case settings

    /// The Voice notes page, under the name it reads as.
    static let voiceNotes = LibrarySection.notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .everything: "All"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .dictations: "Dictations"
        case .documents: "Documents"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Writing style"
        case .draft: "Check a draft"
        case .folder: "Folder"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "chirp.home"
        case .everything: "chirp.all"
        case .meetings: "chirp.meeting"
        case .notes: "chirp.note"
        case .dictations: "chirp.dictate"
        case .documents: "chirp.documents"
        case .dictionary: "chirp.dictionary"
        case .snippets: "chirp.snippets"
        case .style: "chirp.style"
        case .draft: "chirp.drafts"
        case .folder: "chirp.folder"
        case .settings: "chirp.settings"
        }
    }

    /// The kinds of saved item a section lists; nil for the sections that are not lists of items.
    var kinds: [ItemKind]? {
        switch self {
        case .everything, .folder: ItemKind.allCases
        case .meetings: [.meeting]
        case .notes: [.voiceNote]
        case .dictations: [.dictation]
        // A draft saved from the old "Check a draft" page is kept, and listed here.
        case .documents: [.document, .note]
        default: nil
        }
    }

    /// True for a page with a list column and a detail column.
    var isListPage: Bool { kinds != nil && self != .dictations && self != .folder }

    /// The sections under "Library", in sidebar order.
    static let saved: [LibrarySection] = [.meetings, .notes, .dictations, .documents]
    /// The sections under "Your language", in sidebar order.
    static let language: [LibrarySection] = [.dictionary, .snippets, .style]

    /// The feature page a section is, if it belongs to features; Home, Everything and Settings do not.
    var featurePage: FeaturePage? {
        switch self {
        case .meetings: .meetings
        case .notes: .voiceNotes
        case .dictations: .dictations
        case .documents: .documents
        case .dictionary: .dictionary
        case .snippets: .snippets
        case .style: .style
        case .home, .everything, .settings, .draft, .folder: nil
        }
    }

    /// Whether the section is there now: a page whose features are all switched off (Settings ›
    /// General) leaves the sidebar, and what is saved in it is kept.
    @MainActor var isShown: Bool {
        if self == .draft { return LinkHandler.debugEnabled && Features.on(.write) }
        return featurePage.map(Features.shared.set.shows) ?? true
    }

    /// The section a saved item of this kind is listed in.
    static func holding(_ kind: ItemKind) -> LibrarySection {
        switch kind {
        case .meeting: .meetings
        case .dictation: .dictations
        case .document: .documents
        case .voiceNote: .notes
        case .note: .documents
        }
    }
}

/// The one window: Home, everything Chirp has saved, what it knows about the user's language, and Settings.
/// A floating glass sidebar, glass toolbar groups, and paper for everything that is read.
struct LibraryWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation
    @Environment(ReadController.self) private var reader
    @Environment(SearchController.self) private var search
    @Environment(PerchController.self) private var perch

    /// The saved items in the section being shown, newest first.
    @State private var items: [SavedItem] = []
    /// How many things each section holds, for the numbers in the sidebar.
    @State private var counts: [LibrarySection: Int] = [:]
    /// The row picked in the list.
    @State private var selectedID: Int64?
    @State private var folders: [Folder] = []
    /// True while "Add a Link" is asking for one, with what has been typed into it.
    @State private var askingAddress = false
    @State private var address = ""
    /// How many items each folder holds, for the numbers in the sidebar.
    @State private var folderCounts: [Int64: Int] = [:]
    /// The folder being named in the sidebar: a new one (`id` nil) or one being renamed.
    private var editingFolder: FolderEdit? {
        get { app.folderEdit }
        nonmutating set { app.folderEdit = newValue }
    }
    /// The folder waiting for "Delete?" to be answered.
    @State private var deletingFolder: Folder?
    /// The item a folder made from its menu will hold.
    @State private var folderFor: SavedItem?
    /// Fetches and transcribes a link to a video or a podcast; it also holds what is being asked for one.
    private var links: LinkImporter { LinkImporter.shared }
    /// True while a file is being dragged over the window.
    @State private var dropTargeted = false
    /// The row the list picked by itself when it loaded, until the user picks one.
    @State private var autoSelectedID: Int64?
    /// The item another screen last asked for and the section it is in, so a section change that
    /// arrives just after it was selected does not unselect it.
    @State private var justFocused: (section: LibrarySection, id: Int64?)?
    /// The app whose dictations are shown; nil shows them all.
    @State private var appFilter: String?
    /// True for a moment after Copy is pressed, so the button can say so.
    @State private var copied = false
    /// The item waiting for "Delete?" to be answered.
    @State private var deleting: SavedItem?
    /// True while a new folder is being named, with the item that will go in it.
    @State private var namingFolder = false
    @State private var folderName = ""
    /// Bumped at midnight so "Today" is worked out again.
    @State private var day = 0
    @FocusState private var searchFocused: Bool
    /// The window's width, read as it changes.
    @State private var windowWidth: CGFloat = 0
    /// True while Search, shown as its icon in a narrow window, has been opened into its field.
    @State private var searchExpanded = false

    /// True while there is something in the search field: results take the place of the page.
    private var searching: Bool { !search.query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True while the reader is reading aloud, getting ready to, or holding text from another app.
    private var readerBusy: Bool { reader.isPlaying || reader.isPreparing || reader.isReadingSelection }

    /// True while a recording is being made (or finished) and the page is one that shows it, until the
    /// user picks something else in the list: the Library never holds them on the recording.
    private var showingLive: Bool {
        !pickedDuringRecording && NowRows.showsRecording(recorder, in: app.section)
    }
    /// True once a row was picked by hand while a recording was showing. Opening the page again, or the
    /// next recording, shows the recording again.
    @State private var pickedDuringRecording = false

    /// The item open in the detail column, when the page has one.
    private var selectedItem: SavedItem? {
        guard app.section.isListPage, !searching, !showingLive, let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    // The body is built in three steps, which the compiler can check one at a time.

    /// The sidebar, the page and the toolbar.
    private var split: some View {
        @Bindable var search = search
        return HStack(spacing: 0) {
            // The sidebar is a glass panel of its own, inset from the window's edge and running up
            // under the window's buttons. Its button sits beside those buttons, and hides it.
            if app.sidebarVisible {
                sidebar
                    .frame(width: 208)
                    .chirpGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) { sidebarButton.padding(.top, 7).padding(.trailing, 8) }
                    .padding(.leading, 8).padding(.vertical, 8)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if let banner = app.banner {
                    HStack {
                        Image("chirp.warning").foregroundStyle(Color.caution)
                        Text(banner).font(.callout)
                        Spacer()
                        Button("Dismiss") { app.banner = nil }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, PageLayout.gutter).padding(.vertical, 8)
                    .background(Color.caution.opacity(0.12))
                    .accessibilityIdentifier("banner")
                }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.paper.ignoresSafeArea())
        // How wide the window is decides the sidebar below 900, the list's width and the search field.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowWidth = width
            if app.windowNarrow != (width < 900) {
                withAnimation(.easeInOut(duration: 0.2)) { app.windowNarrow = width < 900 }
            }
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: search.query) { if app.section != .settings { search.search() } }
    }

    /// The search field, last in the toolbar on every page. On Settings it looks through the settings' names.
    private var searchField: some View {
        @Bindable var search = search
        return HStack(spacing: 6) {
            Image("chirp.search").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.quiet)
            TextField(app.section == .settings ? "Search settings" : "Search", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    guard app.section != .settings else { return }
                    search.search()
                }
                .onKeyPress(.escape) {
                    guard !search.query.isEmpty else { return .ignored }
                    search.query = ""
                    return .handled
                }
                .accessibilityLabel(app.section == .settings ? "Search settings" : "Search")
                .accessibilityIdentifier("search.field")
            if search.searching { ProgressView().controlSize(.small) }
            if searching {
                Button {
                    search.query = ""
                } label: {
                    Image("chirp.clear").foregroundStyle(Color.quiet)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: searchCompact ? 170 : 208)
        .onChange(of: searchFocused) { _, focused in
            if !focused, search.query.isEmpty { searchExpanded = false }
        }
    }

    /// The window, kept in step with what changes elsewhere.
    private var observed: some View {
        split
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in day += 1 }
        .onAppear {
            reload()
            takeFocus()
        }
        .onChange(of: app.section) { old, new in
            // The search field means something else in Settings; what was typed for one is not carried to the other.
            if (old == .settings) != (new == .settings) { search.query = "" }
            // An item another screen asked for stays selected, whichever of this and `takeFocus` runs first.
            var asked = app.focus?.id
            if asked == nil, let last = justFocused, last.section == app.section { asked = last.id }
            justFocused = nil
            if asked == nil { selectedID = nil }
            pickedDuringRecording = false
            reload(select: asked)
        }
        .onChange(of: app.focus) { takeFocus() }
        .onChange(of: recorder.version) { reload(select: recorder.lastSavedID) }
        .onChange(of: recorder.phase) { old, phase in
            if phase == .idle {
                // Finished: the saved recording is picked, unless the user had moved on to something else.
                if pickedDuringRecording { reload() } else { reload(select: recorder.lastSavedID) }
                pickedDuringRecording = false
            } else if old == .idle {
                pickedDuringRecording = false
            }
        }
        // The recording's own row under "Now" was pressed: it opens, whatever was picked before.
        .onChange(of: recorder.openLiveAsked) { pickedDuringRecording = false }
        .onChange(of: showingLive, initial: true) { _, showing in recorder.liveOpen = showing }
        .onChange(of: dictation.historyVersion) { reload() }
        .onChange(of: reader.version) { reload(select: reader.item?.id) }
        .onChange(of: app.libraryVersion) { reload() }
        .onChange(of: Features.shared.set) { reload() }
        .onChange(of: selectedID) {
            // A row picked by hand (not the first row picking itself) while a recording is showing: show the row.
            if selectedID != nil, selectedID != autoSelectedID, recorder.phase != .idle { pickedDuringRecording = true }
            if selectedID != autoSelectedID { autoSelectedID = nil }
            openSelected()
        }
        // When the reader lets go of what it was reading (it holds nothing any more), the picked document
        // gets it back. A pause is not letting go: the paused document stays where it is.
        .onChange(of: reader.item == nil) { _, free in if free { openSelected() } }
    }

    var body: some View {
        observed
        .background {
            // Command-F puts the cursor in the search field.
            Button("Search") {
                searchExpanded = true
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command).hidden()
            // ⌃⌘S shows or hides the sidebar, as in Finder, Mail and Notes.
            Button("Sidebar") { withAnimation(.easeInOut(duration: 0.2)) { app.toggleSidebar() } }
                .keyboardShortcut("s", modifiers: [.command, .control]).hidden()
        }
        .onFileDrop(isTargeted: $dropTargeted) { url in add(url) }
        // Edit › Paste on the Documents page keeps the clipboard's text as a document.
        .onPasteCommand(of: [.plainText]) { _ in
            guard app.section == .documents, let text = NSPasteboard.general.string(forType: .string) else { return }
            reader.importText(text)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(10)
                    .overlay(Text(dropWords).font(.system(size: 15, weight: .semibold)))
                    .background(Color.paper.opacity(0.85))
            }
        }
        .alert("Add a link", isPresented: Binding(get: { askingAddress || links.asking }, set: { if !$0 { askingAddress = false; links.asking = false } })) {
            TextField("Link", text: $address)
            Button("Add") {
                let typed = address
                address = ""
                addLink(typed)
            }
            Button("Cancel", role: .cancel) { address = "" }
        } message: {
            Text("A web page is saved to read. A video, a podcast or a sound file is transcribed on this Mac.")
        }
        .confirmationDialog(
            deletingFolder.map { "Delete the folder “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = deletingFolder { delete(folder) }
                deletingFolder = nil
            }
        } message: {
            Text("What is in it is kept, and goes back to having no folder.")
        }
        // A podcast feed: which of its latest episodes.
        .confirmationDialog(
            links.choice.map { $0.podcast.isEmpty ? "Which episode?" : "Which episode of \($0.podcast)?" } ?? "",
            isPresented: Binding(get: { links.choice != nil }, set: { if !$0 { links.choice = nil } }), titleVisibility: .visible
        ) {
            ForEach(links.choice?.episodes ?? []) { episode in
                Button(episode.title) { links.choose(episode) }
            }
            Button("Cancel", role: .cancel) { links.choice = nil }
        }
        .alert("New folder", isPresented: $namingFolder) {
            TextField("Name", text: $folderName)
            Button("Add") {
                let name = folderName.trimmingCharacters(in: .whitespaces)
                folderName = ""
                guard !name.isEmpty, let item = folderFor ?? selectedItem, let folder = try? recorder.library.addFolder(name) else { return }
                folderFor = nil
                move(item, to: folder.id)
            }
            Button("Cancel", role: .cancel) {
                folderName = ""
                folderFor = nil
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = deleting { delete(item) }
                deleting = nil
            }
        } message: {
            Text(deleteWarning)
        }
    }

    /// What the window says while a file is dragged over it: only what is switched on.
    private var dropWords: String {
        switch (LibrarySection.documents.isShown, Features.shared.set.records) {
        case (true, true): "Drop a document to read, or audio to transcribe"
        case (true, false): "Drop a document"
        case (false, true): "Drop audio to transcribe"
        case (false, false): "Nothing that is switched on can take a file"
        }
    }

    private var deleteQuestion: String {
        guard let item = deleting else { return "" }
        return "Delete this \(item.kind.label.lowercased())?"
    }

    private var deleteWarning: String {
        deleting?.deleteWarning ?? ""
    }

    // MARK: Sidebar

    /// The sections in the order the sidebar lists them, for the arrow keys.
    private var sidebarOrder: [LibrarySection] {
        ([.home] + (LibrarySection.saved.contains(where: \.isShown) ? [.everything] : []) + LibrarySection.saved + LibrarySection.language + [.settings]).filter(\.isShown)
    }

    private var sidebar: some View {
        // Only the pages of features that are switched on; a heading with nothing under it goes too.
        let saved = LibrarySection.saved.filter(\.isShown)
        let language = LibrarySection.language.filter(\.isShown)
        return VStack(alignment: .leading, spacing: 1) {
            if Beta.isOn { BetaSidebarHeader() }
            row(.home)
            if !saved.isEmpty {
                sidebarHeading("Library")
                // Everything together comes first.
                row(.everything)
                ForEach(saved) { row($0) }
            }
            // Folders hold what the Library pages hold, so they are there while any of those is.
            if !saved.isEmpty { folderRows }
            if !language.isEmpty {
                sidebarHeading("Your language")
                ForEach(language) { row($0) }
            }
            Spacer(minLength: 8)
            row(.settings)
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.top, 46).padding(.horizontal, 10).padding(.bottom, 12)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let order = sidebarOrder
            guard let at = order.firstIndex(of: app.section) else { return app.section = .home }
            let next = direction == .down ? at + 1 : direction == .up ? at - 1 : at
            if order.indices.contains(next) { app.section = order[next] }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    /// The Folders part of the sidebar: a heading with a button that adds one, then a row for each.
    /// A new folder, or one being renamed, is a field in the list.
    @ViewBuilder private var folderRows: some View {
        HStack(spacing: 0) {
            Text("Folders").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.quiet)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Button {
                editingFolder = FolderEdit(id: nil, name: "New folder")
            } label: {
                Image("chirp.add").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.quiet)
                    .frame(width: 20, height: 20).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New folder")
            .accessibilityLabel("New folder")
            .accessibilityIdentifier("sidebar.newFolder")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.top, 10).padding(.bottom, 2)
        ForEach(folders) { folder in
            if let edit = editingFolder, edit.id == folder.id {
                FolderField(name: edit.name) { name in finishFolderEdit(name) }
            } else {
                FolderRow(
                    name: folder.name, count: folderCounts[folder.id ?? -1] ?? 0,
                    selected: app.section == .folder && app.folderID == folder.id && !searching,
                    pick: {
                        if searching { search.query = "" }
                        app.folderID = folder.id
                        app.section = .folder
                        reload()
                    },
                    drop: { itemID in
                        guard let item = try? recorder.library.item(itemID) else { return }
                        move(item, to: folder.id)
                    },
                    // Double-click the name to rename it, as in Notes; "…" on hover has the rest.
                    rename: { editingFolder = FolderEdit(id: folder.id, name: folder.name) },
                    menu: folderMenu(folder)
                )
                .contextMenu { MenuEntries(items: folderMenu(folder)) }
                .accessibilityIdentifier("sidebar.folder.\(folder.name)")
            }
        }
        if let edit = editingFolder, edit.id == nil {
            FolderField(name: edit.name) { name in finishFolderEdit(name) }
        }
    }

    /// What can be done to a folder: in its "…" on hover, its right-click menu and its page's header.
    private func folderMenu(_ folder: Folder) -> [HeaderMenuItem] {
        [
            HeaderMenuItem(id: "rename", title: "Rename") { renameFolder(folder) },
            HeaderMenuItem(id: "new", title: "New Folder") { newFolder() },
            HeaderMenuItem(id: "delete", title: "Delete Folder…", destructive: true, dividerBefore: true) { deletingFolder = folder },
        ]
    }

    /// Puts a folder's name into a field in the sidebar, showing the sidebar if it is hidden.
    private func renameFolder(_ folder: Folder) {
        withAnimation(.easeInOut(duration: 0.2)) { app.showSidebar() }
        editingFolder = FolderEdit(id: folder.id, name: folder.name)
    }

    /// A new folder, named in a field at the foot of the sidebar's folders.
    private func newFolder() {
        withAnimation(.easeInOut(duration: 0.2)) { app.showSidebar() }
        editingFolder = FolderEdit(id: nil, name: "New folder")
    }

    /// Takes the name typed for a new folder or a renamed one; nil or an empty name leaves things as they were.
    private func finishFolderEdit(_ name: String?) {
        defer { editingFolder = nil }
        guard let edit = editingFolder, let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        if let id = edit.id, let folder = folders.first(where: { $0.id == id }) {
            try? recorder.library.rename(folder, to: name)
        } else {
            _ = try? recorder.library.addFolder(name)
        }
        app.libraryVersion += 1
        reload()
    }

    /// Deletes a folder. What was in it is kept and no longer belongs to any folder.
    private func delete(_ folder: Folder) {
        try? recorder.library.delete(folder)
        if app.section == .folder, app.folderID == folder.id { app.section = .home }
        app.libraryVersion += 1
        reload()
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.quiet)
            .padding(.leading, 8).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// One sidebar row: the section's icon and name, and how many things are in it when that is known.
    private func row(_ section: LibrarySection) -> some View {
        // While search results are showing, no library page is the one open, and picking any page
        // (the one that was open included) leaves the search for it.
        let overSearch = searching && app.section != .settings
        let count = section == .everything ? LibrarySection.saved.filter(\.isShown).reduce(0) { $0 + (counts[$1] ?? 0) }
            : LibrarySection.saved.contains(section) ? counts[section] ?? 0 : 0
        return SidebarRow(section: section, count: count, selected: app.section == section && !overSearch) {
            if overSearch { search.query = "" }
            app.section = section
        }
    }

    // MARK: Toolbar

    /// The window's toolbar holds what acts on the app, the same on every page: the sidebar button while
    /// the sidebar is hidden, Add, and Search last. What acts
    /// on the open item is in that item's header. Dictations keep their "By app" filter beside Add.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !app.sidebarVisible {
            ToolbarItem(placement: .navigation) { sidebarButton }
        }
        ToolbarSpacer(.flexible)
        if app.section == .dictations, !searching {
            ToolbarItem {
                Menu {
                    Picker("By app", selection: $appFilter) {
                        Text("All apps").tag(String?.none)
                        ForEach(dictationApps, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(appFilter.flatMap { LibraryRows.appName($0) } ?? "By app")
                }
                .help("Show the dictations made in one app")
                .accessibilityLabel("By app")
                .accessibilityIdentifier("dictations.byApp")
            }
            ToolbarSpacer(.fixed)
        }
        // Add lists what the features that are switched on can take; with none of those it is not there.
        let documents = LibrarySection.documents.isShown
        if app.section != .settings, documents || Features.shared.set.records || Features.on(.write) {
            ToolbarItem {
                Menu {
                    // A note to type into, and a voice note for talking at length.
                    if Features.on(.notes) {
                        Button {
                            newNote()
                        } label: {
                            Label("New Note", image: "chirp.note")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        Button {
                            perch.record()
                        } label: {
                            Label("Record a Voice Note", image: "chirp.voiceNote")
                        }
                        Divider()
                    }
                    // A file is a document to read, or sound to transcribe; a link is a page, a video or a podcast.
                    Button {
                        pickFile()
                    } label: {
                        Label("Add a File…", image: "chirp.file")
                    }
                    Button {
                        askingAddress = true
                    } label: {
                        Label("Add a Link…", image: "chirp.link")
                        Text(addLinkWords)
                    }
                    .disabled(!documents && (dictation.phase != .idle || links.isBusy))
                } label: {
                    ToolbarWords("Add", symbol: "chirp.add")
                }
                .labelStyle(.titleAndIcon)
                .menuIndicator(.hidden)
                .help("Add something to Chirp")
                .accessibilityIdentifier("library.add")
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            // Where the window is short of room, Search is its icon until it is pressed (or ⌘F).
            if searchCompact, !searchExpanded, !searching {
                Button {
                    searchExpanded = true
                    searchFocused = true
                } label: {
                    Label { Text("Search") } icon: { Image.toolbarIcon("chirp.search") }
                }
                .labelStyle(.iconOnly)
                .help("Search")
                .accessibilityIdentifier("search.button")
            } else {
                searchField
            }
        }
    }

    /// The sidebar button: beside the window's controls, on the sidebar while it shows and in the toolbar while it is hidden.
    private var sidebarButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { app.toggleSidebar() }
        } label: {
            Image("chirp.sidebar").font(.system(size: 14, weight: .regular)).foregroundStyle(Color.ink.opacity(0.62))
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
        .accessibilityLabel(app.sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
        .accessibilityIdentifier("sidebar.toggle")
    }

    /// True where the window is short of room for the search field: Search shows as its icon.
    private var searchCompact: Bool { contentWidth < 600 }

    /// The width of the page beside the sidebar.
    private var contentWidth: CGFloat { windowWidth - (app.sidebarVisible ? 216 : 0) }

    /// The list column of a list page: 300 points with room to spare, down to 210 in the smallest window
    /// with the sidebar showing.
    private var listWidth: CGFloat {
        guard windowWidth > 0 else { return PageLayout.listWidth }
        return max(210, min(PageLayout.listWidth, 210 + (contentWidth - 544) * 0.16))
    }

    /// The apps the listed dictations were typed into, by name.
    private var dictationApps: [(id: String, name: String)] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let id = item.appBundleID, seen.insert(id).inserted, let name = LibraryRows.appName(id) else { return nil }
            return (id, name)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if searching, app.section != .settings {
            let found = search.results.filter { Features.shared.set.shows($0.item.kind) }.count
            Page("Search", subtitle: found == 0 ? "" : found == 1 ? "1 result" : "\(found) results") {
                SearchView(showField: false)
            }
        } else {
            switch app.section {
            case .home:
                HomePage(pickDocument: pickDocument, pickAudio: pickAudio, askAddress: { askingAddress = true }, askLink: { links.asking = true }, askDelete: { deleting = $0 })
                    .id(day)
            case .dictations:
                DictationsPage(items: items, appFilter: appFilter)
                    .id(day)
            case .dictionary:
                Page("Dictionary", subtitle: "Names and words Chirp spells, accepts and says your way") { DictionaryView() }
            case .snippets:
                Page("Snippets", subtitle: "Say the cue and Chirp types the text. Type the cue and Chirp offers it.") { SnippetsView() }
            case .style: WritingStylePage()
            case .draft: WritePage()
            case .folder:
                FolderPage(
                    folder: folders.first { $0.id == app.folderID }, items: items, folders: folders,
                    pin: pin, move: move, newFolder: { folderFor = $0; namingFolder = true }, askDelete: { deleting = $0 },
                    actions: folderActions(folders.first { $0.id == app.folderID })
                )
                .id(day)
            case .settings: SettingsPage()
            default: listPage.id(day)
            }
        }
    }

    /// A list page: the shared header, then a list column and a detail column.
    private var listPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: app.section.title, subtitle: LibraryRows.subtitle(for: app.section, items: items))
            Rectangle().fill(PageLayout.line).frame(height: 1).padding(.top, 16)
            if items.isEmpty, !NowRows.hasRows(recorder, dictation, section: app.section, items: items) {
                if app.section == .documents {
                    // The bird, one line, and the one button that fills the page.
                    EmptyPage("No documents yet", line: "Add a file or a link, or drop a file on the perch.") {
                        Menu {
                            Button("Add a File…") { pickFile() }
                            Button("Add a Link…") { askingAddress = true }
                        } label: {
                            // The page's one amber action.
                            HStack(spacing: 6) {
                                Image("chirp.add").font(.system(size: 11, weight: .semibold))
                                Text("Add").font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.onAmber)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Color.amber, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityIdentifier("empty.action")
                    }
                } else if app.section == .meetings {
                    EmptyPage("No meetings yet", line: "Chirp offers to take notes when a call starts. You can also start one yourself.") {
                        EmptyPageButton(title: "Record a meeting", symbol: "chirp.meeting") { perch.recordMeeting() }
                    }
                } else if app.section == .notes {
                    EmptyPage("No notes yet", line: "Type or say an idea. Notes are saved here as you write.") {
                        EmptyPageButton(title: "New Note", symbol: "chirp.note") { newNote() }
                    }
                } else {
                    emptyList.padding(.horizontal, PageLayout.gutter).padding(.top, 8)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    LibraryList(
                        section: app.section, items: items, folders: folders, selectedID: $selectedID, askDelete: { deleting = $0 },
                        pin: pin, move: move, newFolder: { folderFor = $0; namingFolder = true }
                    )
                        .frame(width: listWidth)
                    Rectangle().fill(PageLayout.line).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// An empty list page: one plain line, and the action that makes the first one.
    @ViewBuilder private var emptyList: some View {
        switch app.section {
        case .meetings:
            EmptyLine("No meetings yet.") { Button("Record a meeting") { perch.recordMeeting() }.accessibilityIdentifier("empty.action") }
        case .notes:
            EmptyLine("No notes yet.") { Button("New Note") { newNote() }.accessibilityIdentifier("empty.action") }
        case .documents:
            EmptyLine("Nothing to read yet.") { Button("Add a document…", action: pickDocument).accessibilityIdentifier("empty.action") }
        default:
            EmptyLine("Nothing saved yet.") {
                if Features.on(.notes) { Button("New Note") { newNote() }.accessibilityIdentifier("empty.action") }
            }
        }
    }

    // MARK: Detail

    /// The right-hand side: the recording in progress, or the picked item.
    @ViewBuilder private var detail: some View {
        if showingLive {
            LiveMeetingView()
        } else if let id = selectedID, let item = items.first(where: { $0.id == id }) {
            switch item.kind {
            case .meeting: MeetingDetail(item: item, folders: folders, header: headerParts(for: item)).id(id)
            // A note, typed or spoken, is an editable note; its header has Copy, Export…, Share.
            case .voiceNote: NoteDetail(item: item, folders: folders, header: headerParts(for: item)).id(id)
            case .document:
                DocumentDetail(item: item, folder: item.folderID.flatMap { f in folders.first { $0.id == f }?.name }, header: headerParts(for: item))
            default: ItemDetail(item: item, header: headerParts(for: item)).id("\(id)-\(item.updatedAt.timeIntervalSince1970)")
            }
        } else {
            Color.clear
        }
    }

    // MARK: Data

    /// Reads the sidebar counts and the current section's items again. `select` picks that item if it
    /// is in the list; otherwise the selection is kept, or falls to the first row.
    private func reload(select: Int64? = nil) {
        let library = recorder.library
        for section in LibrarySection.saved {
            counts[section] = (section.kinds ?? []).reduce(0) { $0 + ((try? library.count(kind: $1)) ?? 0) }
        }
        LibraryRows.refresh(library)
        folders = (try? library.folders()) ?? []
        folderCounts = (try? library.folderCounts(kinds: Features.shared.set.shownKinds)) ?? [:]
        // Everything lists what the features that are switched on saved; the rest is kept, out of sight.
        guard let kinds = app.section.kinds?.filter(Features.shared.set.shows) else { return }
        if app.section == .folder {
            // A folder that has gone (deleted elsewhere) has no page.
            guard let id = app.folderID, folders.contains(where: { $0.id == id }) else { return app.section = .home }
            items = (try? library.items(kinds: kinds, folderID: id, limit: 400)) ?? []
            return
        }
        // A note opened here and left without words is not kept (the one being looked at stays).
        if app.section == .notes, (try? library.deleteEmptyNotes(keeping: select ?? selectedID)) ?? 0 > 0 {
            counts[.notes] = (try? library.count(kind: .voiceNote)) ?? 0
        }
        items = (try? library.items(kinds: kinds, limit: 400)) ?? []
        guard app.section.isListPage else { return }
        if let select, items.contains(where: { $0.id == select }) { selectedID = select }
        if let id = selectedID, !items.contains(where: { $0.id == id }) { selectedID = nil }
        if selectedID == nil {
            // The first row as the list shows it: pinned items lead.
            let first = LibraryRows.groups(items, section: app.section).first?.items.first?.id
            autoSelectedID = first
            selectedID = first
        }
    }

    /// A picked document is opened in the reader, which is what the detail side shows for it.
    private func openSelected() {
        guard let id = selectedID, let item = items.first(where: { $0.id == id }), item.kind == .document else { return }
        guard reader.item?.id != id else { return }
        // The first row picks itself when the list loads. That must not cut off what is being read
        // aloud; the document is opened once the reader holds nothing.
        if id == autoSelectedID, readerBusy { return }
        reader.open(item)
    }

    /// Shows the item another screen asked for (a search result, say): leaves search, goes to its
    /// section and selects it.
    private func takeFocus() {
        guard let item = app.focus else { return }
        search.query = ""
        let section = LibrarySection.holding(item.kind)
        justFocused = (section: section, id: item.id)
        autoSelectedID = nil
        app.section = section
        reload(select: item.id)
        app.focus = nil
    }

    /// New Note: an empty note, open full size on the Notes page with the cursor in it.
    private func newNote() {
        guard Features.on(.notes), let note = try? recorder.library.saveNote(id: nil, markdown: "") else { return }
        search.query = ""
        app.section = .notes
        app.libraryVersion += 1
        reload(select: note.id)
    }

    /// Deletes through the controller that owns that kind of item, so its files go with it.
    private func delete(_ item: SavedItem) {
        switch item.kind {
        case .document: reader.delete(item)
        case .meeting, .voiceNote: recorder.delete(item)
        default: dictation.delete(item)
        }
        app.libraryVersion += 1
        reload()
    }

    // MARK: Item actions

    /// The actions every kind of item shares, for its header: Copy, Export and Read aloud, then in
    /// "…" Pin, Move to Folder, Attach a File… for a recording, and Delete….
    private func headerParts(for item: SavedItem) -> ItemHeaderParts {
        let recording = item.kind == .meeting || item.kind == .voiceNote
        var export: [HeaderMenuItem] = [
            HeaderMenuItem(id: "markdown", title: "Markdown…") { export(item, markdown: true) },
            HeaderMenuItem(id: "plain", title: "Plain text…") { export(item, markdown: false) },
        ]
        if item.kind != .document, item.audioFile != nil {
            export.append(HeaderMenuItem(id: "audio", title: "Audio…") { exportAudio(item) })
        }
        var actions = [
            HeaderAction(id: "copy", title: copied ? "Copied" : "Copy", symbol: copied ? "chirp.check" : "chirp.copy",
                         help: recording ? "Copy the notes" : "Copy the text") { copy(item) },
            HeaderAction(id: "export", title: "Export", symbol: "chirp.export", help: "Save it as a file", menu: export),
        ]
        // A document is read from its bar at the foot of the page; its header has Summarize instead.
        if item.kind != .document, Features.on(.read) {
            actions.append(HeaderAction(id: "readAloud", title: "Read aloud", symbol: "chirp.read",
                                        help: recording ? "Read the notes aloud" : "Read it aloud") { readAloud(item) })
        }
        var folderItems = folders.map { folder in
            HeaderMenuItem(id: "folder.\(folder.id ?? -1)", title: folder.name, checked: item.folderID == folder.id) { move(item, to: folder.id) }
        }
        folderItems.append(HeaderMenuItem(id: "folder.new", title: "New Folder…", dividerBefore: !folders.isEmpty) {
            folderFor = item
            namingFolder = true
        })
        if item.folderID != nil {
            folderItems.append(HeaderMenuItem(id: "folder.none", title: "Remove from Folder") { move(item, to: nil) })
        }
        var more = [
            HeaderMenuItem(id: "pin", title: item.starred ? "Unpin" : "Pin", symbol: item.starred ? "chirp.unpin" : "chirp.pin") { pin(item) },
            HeaderMenuItem(id: "move", title: "Move to Folder", symbol: "chirp.folder", children: folderItems),
        ]
        if recording {
            more.append(HeaderMenuItem(id: "attach", title: "Attach a File…", symbol: "chirp.attach") { attachFiles(to: item) })
        }
        more.append(HeaderMenuItem(id: "delete", title: "Delete…", symbol: "chirp.trash", destructive: true, dividerBefore: true) { deleting = item })
        return ItemHeaderParts(actions: actions, more: more)
    }

    /// A folder's page header: Rename, New Folder and Delete Folder….
    private func folderActions(_ folder: Folder?) -> [HeaderAction] {
        guard let folder else { return [] }
        return [
            HeaderAction(id: "folder.rename", title: "Rename", symbol: "chirp.edit", help: "Rename this folder") { renameFolder(folder) },
            HeaderAction(id: "folder.new", title: "New Folder", symbol: "chirp.add", help: "Make a new folder") { newFolder() },
            HeaderAction(id: "folder.delete", title: "Delete Folder…", symbol: "chirp.trash", help: "Delete this folder; what is in it is kept") { deletingFolder = folder },
        ]
    }

    /// The item as it is saved now: the list's copy may be behind (notes written since, a new title).
    private func fresh(_ item: SavedItem) -> SavedItem {
        item.id.flatMap { try? recorder.library.item($0) } ?? item
    }

    /// Copies the notes of a recording, or the text of anything else.
    private func copy(_ item: SavedItem) {
        let item = fresh(item)
        switch item.kind {
        case .voiceNote:
            RichCopy.copy(markdown: perch.notes.markdown(of: item))
        case .meeting:
            // The notes when there are some; a recording without notes is its own words.
            let notes = [item.summary, item.body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let words = MeetingText.script((try? recorder.library.segments(itemID: item.id ?? -1)) ?? [])
            // Rich text, with Markdown as its plain form: the notes keep their headings and points when pasted.
            if notes.isEmpty { TextInserter.copy(words) } else { RichCopy.copy(markdown: notes.joined(separator: "\n\n")) }
        case .document: RichCopy.copy(markdown: documentMarkdown(item))
        default: TextInserter.copy(item.body)
        }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// A document's text as Markdown, with the headings, lists, bold and links its layout keeps.
    private func documentMarkdown(_ item: SavedItem) -> String {
        guard let id = item.id, let extra = try? recorder.library.documentExtra(itemID: id), !extra.isTranscript,
            let layout = DocLayout(json: extra.layout), layout.fits(length: item.body.utf16.count)
        else { return item.body }
        return layout.markdown(item.body)
    }

    /// The whole item as one text: notes and transcript for a recording, the summary and text of a document.
    private func text(of item: SavedItem, markdown: Bool) -> String {
        switch item.kind {
        case .meeting, .voiceNote:
            let all = MeetingText.markdown(item: item, segments: (try? recorder.library.segments(itemID: item.id ?? -1)) ?? [])
            return markdown ? all : MarkdownLines.plain(all)
        case .document:
            guard markdown else { return item.body }
            return "# \(item.title)\n\n" + (item.summary.isEmpty ? "" : "## Summary\n\n\(item.summary)\n\n") + documentMarkdown(item)
        default: return item.body
        }
    }

    /// Saves the item as a Markdown or plain text file where the user chooses.
    private func export(_ item: SavedItem, markdown: Bool) {
        let item = fresh(item)
        let panel = NSSavePanel()
        let name = TextStats.fileName(LibraryRows.title(item), limit: 60)
        panel.nameFieldStringValue = name + (markdown ? ".md" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text(of: item, markdown: markdown).write(to: url, atomically: true, encoding: .utf8) } catch {
            app.report(error, doing: "export it")
        }
    }

    /// Saves a copy of the recording's sound where the user chooses.
    private func exportAudio(_ item: SavedItem) {
        guard let file = item.audioFile else { return }
        let source = ChirpStore.audioDirectory.appendingPathComponent(file)
        let panel = NSSavePanel()
        let name = TextStats.fileName(LibraryRows.title(item), limit: 60)
        panel.nameFieldStringValue = name + "." + source.pathExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: source, to: url)
        } catch { app.report(error, doing: "export the audio") }
    }

    /// Reads the notes of a recording aloud, or the text of a note or dictation. It is read once and not kept as a document.
    private func readAloud(_ item: SavedItem) {
        let item = fresh(item)
        var text = item.body
        if item.kind == .meeting || item.kind == .voiceNote {
            let notes = [item.summary, item.body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            text = notes.isEmpty
                ? ((try? recorder.library.segments(itemID: item.id ?? -1)) ?? []).map(\.text).joined(separator: " ")
                : MarkdownLines.plain(notes.joined(separator: "\n\n"))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        reader.readOnce(DocumentImporter.Imported(title: LibraryRows.title(item), text: text, source: item.kind.label))
    }

    /// Pins the item to the top of its list, or takes the pin off.
    private func pin(_ item: SavedItem) {
        var item = fresh(item)
        item.starred.toggle()
        save(item)
    }

    /// Puts the item in a folder, or in none.
    private func move(_ item: SavedItem, to folder: Int64?) {
        var item = fresh(item)
        item.folderID = folder
        save(item)
    }

    /// Saves a change to an item and tells the pages to reload.
    private func save(_ item: SavedItem) {
        if item.kind == .meeting || item.kind == .voiceNote {
            recorder.update(item)
        } else {
            _ = try? recorder.library.save(item)
            app.libraryVersion += 1
        }
    }

    // MARK: Adding

    /// Takes a file dropped on the window or picked from the Add menu: audio and video are
    /// transcribed into a voice note, anything else joins the documents.
    private func add(_ url: URL) {
        // Sound is transcribed by Record; a document goes to Documents, which Read aloud and Summarize share.
        guard url.isAudioOrVideo ? Features.shared.set.records : LibrarySection.documents.isShown else {
            Toast.show(url.isAudioOrVideo ? "Record is switched off in Settings." : "Read aloud and Summarize are switched off in Settings.", seconds: 4)
            return
        }
        if url.isAudioOrVideo {
            // What is transcribed from a file is a document.
            app.section = LibrarySection.documents.isShown ? .documents : .notes
            Task { await dictation.transcribe(file: url) }
        } else {
            app.section = .documents
            reader.importFile(url)
        }
    }

    /// Asks for files to keep with a recording.
    private func attachFiles(to item: SavedItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, let id = item.id else { return }
        for url in panel.urls where !recorder.attach(url, to: id) { Toast.show("Chirp could not keep \(url.lastPathComponent)", seconds: 5) }
    }

    /// What "Add a Link…" takes, by what is switched on.
    private var addLinkWords: String {
        switch (LibrarySection.documents.isShown, Features.shared.set.records) {
        case (true, true): "YouTube, a podcast, a web page"
        case (true, false): "A web page"
        default: "YouTube, a podcast"
        }
    }

    /// Asks for a file of any kind Chirp takes: a document to read, or sound to transcribe.
    private func pickFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        if LibrarySection.documents.isShown { types += DocumentImporter.supportedTypes }
        if Features.shared.set.records { types += [.audio, .movie] }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    /// Takes a link: a video, a podcast or a sound file is transcribed; anything else is a page to read.
    private func addLink(_ typed: String) {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let documents = LibrarySection.documents.isShown
        let media = Features.shared.set.records && (LinkKind.isMedia(typed) || !documents)
        if documents { app.section = .documents }
        if media {
            // Asked for while something else is being transcribed or written, it waits its turn and says so.
            links.start(typed, dictation: dictation)
        } else if documents {
            Task { await reader.importWebPage(typed) }
        } else {
            Toast.show("Read aloud and Summarize are switched off in Settings.", seconds: 4)
        }
    }

    private func pickDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentImporter.supportedTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    private func pickAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }
}

/// A dictation or a note, opened large enough to read, fix and reuse. Its actions are in its header,
/// under the title: Edit, Copy, Export, Read aloud, and "…" for the rest.
struct ItemDetail: View {
    @Environment(DictationController.self) private var dictation
    let item: SavedItem
    var header = ItemHeaderParts()
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(meta).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.quiet).lineLimit(1)
                Text(item.kind == .note && !item.title.isEmpty ? item.title : item.kind.label)
                    .font(.detailTitle).tracking(-0.2).lineLimit(2).padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ItemActionBar(actions: parts.actions, more: parts.more)
                    .padding(.top, 10)
                Text(item.body).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30).padding(.trailing, 40).padding(.top, 18).padding(.bottom, 24)
        }
        .sheet(isPresented: $editing) {
            DictationEditor(item: item) { newText in
                dictation.lastLearned = dictation.saveEdit(of: item, newText: newText)
            }
        }
    }

    /// Edit first; playing, transcribing again and the words as heard go in "…".
    private var parts: ItemHeaderParts {
        var extra: [HeaderMenuItem] = []
        if let file = item.audioFile {
            extra.append(HeaderMenuItem(id: "play", title: "Play", symbol: "chirp.play") { AudioPlayback.shared.toggle(ChirpStore.audioDirectory.appendingPathComponent(file)) })
            extra.append(HeaderMenuItem(id: "again", title: "Transcribe Again", symbol: "chirp.again", disabled: dictation.phase != .idle) {
                Task { await dictation.retranscribe(item) }
            })
        }
        if item.rawText != item.body, !item.rawText.isEmpty {
            extra.append(HeaderMenuItem(id: "raw", title: "Copy the Original Words") { TextInserter.copy(item.rawText) })
        }
        var out = header.adding(first: [HeaderAction(id: "edit", title: "Edit", symbol: "chirp.edit", help: "Fix the words") { editing = true }])
        // Its own entries after Pin and Move to Folder, before Delete.
        if !extra.isEmpty {
            extra[0].dividerBefore = true
            out = out.adding(more: extra)
        }
        return out
    }

    /// The line above the title: what it is, when, how long, and which app it was typed into.
    private var meta: String {
        var parts = [item.kind.label, item.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide)), item.createdAt.formatted(date: .omitted, time: .shortened)]
        if item.duration > 0 { parts.append(item.duration.clock) }
        if let id = item.appBundleID, let name = LibraryRows.appName(id) { parts.append("typed into \(name)") }
        return parts.joined(separator: " · ")
    }
}

/// How the user writes: their profile, per-app tone, and what Chirp has learned.
struct WritingStylePage: View {
    @State private var tab = 0

    var body: some View {
        Page("Writing style", subtitle: "How you like to write. Chirp follows it when it tidies a dictation or suggests a rewrite") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(Array(["Your style", "By app", "Learned"].enumerated()), id: \.offset) { index, name in
                        Button { tab = index } label: { ChipLabel(title: name, selected: tab == index) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(tab == index ? .isSelected : [])
                    }
                }
                .padding(.leading, PageLayout.gutter).padding(.top, 14)
                switch tab {
                case 0: ProfileView()
                case 1: AppStylesView()
                default: LearnedView()
                }
            }
        }
    }
}

extension SavedItem {
    /// A non-optional identity for list rows (saved items always have an id).
    var listID: Int64 { id ?? -1 }
}

/// A toolbar item that shows its name: the same weight and size whether it is a button or opens a
/// menu. Left to the system, a button's name was drawn bolder and a point higher than a menu's.
private struct ToolbarWords: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title).font(.system(size: 13, weight: .regular))
        } icon: {
            Image.toolbarIcon(symbol)
        }
    }
}

/// A row of the sidebar. It sits on glass, so it is drawn with a fill: stronger for the page that is open.
private struct SidebarRow: View {
    let section: LibrarySection
    let count: Int
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(section.symbol).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(Color.ink.opacity(0.8))
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Color.ink.opacity(0.92))
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet)
                }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? Color.ink.opacity(0.09) : hovering ? Color.ink.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(count > 0 ? "\(section.title), \(count)" : section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
    }
}

/// A folder's name being typed in the sidebar: a new folder (`id` nil) or one being renamed.
struct FolderEdit: Equatable {
    var id: Int64?
    var name: String
}

/// A folder in the sidebar: its name and how many things are in it. A Library row dropped on it goes into
/// it. A double-click on it renames it; pointed at, "…" takes the place of its count.
private struct FolderRow: View {
    let name: String
    let count: Int
    let selected: Bool
    let pick: () -> Void
    let drop: (Int64) -> Void
    let rename: () -> Void
    let menu: [HeaderMenuItem]
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image("chirp.folder").font(.system(size: 13)).frame(width: 18).foregroundStyle(Color.ink.opacity(0.8))
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Color.ink.opacity(0.92)).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0, !hovering { Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.quiet) }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(targeted ? Color.amber.opacity(0.3) : selected ? Color.ink.opacity(0.09) : hovering ? Color.ink.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
        .overlay(alignment: .trailing) {
            if hovering {
                Menu {
                    MenuEntries(items: menu)
                } label: {
                    Image("chirp.more").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(Color.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 4)
                .help("Folder actions")
                .accessibilityLabel("Actions for \(name)")
                .accessibilityIdentifier("sidebar.folderMore")
            }
        }
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { texts, _ in
            let ids = texts.compactMap(LibraryDrag.id(from:))
            ids.forEach(drop)
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityLabel(count > 0 ? "\(name), folder, \(count)" : "\(name), folder")
        .accessibilityHint("Double-click to rename")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Rename") { rename() }
    }
}

/// The field a folder is named in, in the sidebar's list. Return keeps the name; Escape, or clicking
/// away with nothing typed, leaves things as they were.
private struct FolderField: View {
    @State var name: String
    let done: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("chirp.folder").font(.system(size: 13)).frame(width: 18).foregroundStyle(Color.ink.opacity(0.8))
            TextField("Folder name", text: $name)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onSubmit { done(name) }
                .onKeyPress(.escape) {
                    done(nil)
                    return .handled
                }
                .accessibilityLabel("Folder name")
                .accessibilityIdentifier("sidebar.folderField")
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(Color.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ink.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: -2).strokeBorder(Color.amber.opacity(0.4), lineWidth: 3))
        .onAppear { focused = true }
        .onChange(of: focused) { _, has in if !has { done(name) } }
    }
}

/// Tells a link that is sound to transcribe from one that is a page to read, by its address alone.
enum LinkKind {
    /// Sites whose pages are a video or a recording.
    static let mediaHosts = [
        "youtube.com", "youtu.be", "vimeo.com", "soundcloud.com", "podcasts.apple.com", "open.spotify.com", "twitch.tv", "dailymotion.com",
        "ted.com", "bandcamp.com", "mixcloud.com", "loom.com", "overcast.fm", "pca.st", "castro.fm", "anchor.fm", "buzzsprout.com", "simplecast.com",
        "libsyn.com", "podbean.com", "transistor.fm", "captivate.fm", "megaphone.fm", "rumble.com", "tiktok.com",
    ]

    static func isMedia(_ text: String) -> Bool {
        guard let url = MediaLink.url(from: text) else { return false }
        if MediaLink.soundEndings.contains(url.pathExtension.lowercased()) { return true }
        let path = url.path.lowercased()
        if path.hasSuffix(".rss") || path.hasSuffix(".xml") || path.contains("/feed") { return true }
        guard let host = url.host?.lowercased() else { return false }
        return mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
