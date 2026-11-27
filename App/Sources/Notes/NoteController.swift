import AVFoundation
import AppKit
import ChirpCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Notes: the note open in the perch, saving as it is typed, and getting a note out of Chirp (Copy,
/// Export…, Share). The same note opens full size on the Notes page with the same editor.
@MainActor
@Observable
final class NoteController {
    /// The writing checker the note editor uses (the one the underlines in other apps use).
    nonisolated(unsafe) static var checker: GrammarChecker?
    /// For the checker's cards: the Dictionary, dismissed suggestions, corrections.
    nonisolated(unsafe) static var engine: PersonalLanguage?

    // MARK: Settings (Settings › Notes)

    /// Writing checks run in notes.
    static var checksWriting: Bool {
        get { UserDefaults.standard.object(forKey: "notes.checkWriting") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notes.checkWriting") }
    }

    let library: Library
    /// A note is open in the perch.
    private(set) var isOpen = false
    /// The open note's Markdown.
    var draft = ""
    /// The open note, once it has been saved; nil while it has no words yet.
    private(set) var itemID: Int64?
    /// The last time the open note was saved, for "Saved" in its head row.
    private(set) var savedAt: Date?
    /// Bumped when a note is saved, so pages showing notes read them again.
    private(set) var version = 0
    /// What the perch does when a note opens or closes: take the keyboard, give it back, say "Saved".
    @ObservationIgnored var onOpen: (() -> Void)?
    @ObservationIgnored var onClose: ((_ saved: SavedItem?, _ announce: Bool) -> Void)?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var typed = false
    @ObservationIgnored private var dictated = false

    // MARK: Listening (a new note starts listening at once)

    /// The dictation a new note listens with. Set by the perch.
    @ObservationIgnored weak var dictation: DictationController?
    /// The editor of the note in the perch, where heard words go (never the Notes page's editor).
    @ObservationIgnored private weak var editor: NoteTextView?
    /// The open note is listening: what is said goes in as it is heard.
    private(set) var listening = false
    /// The open note has stopped listening and its last words are on their way.
    private(set) var finishing = false
    /// Why the open note did not start listening, in a few words for its head row; nil when it did.
    private(set) var listenProblem: String?
    /// Each time a note starts listening it gets a number, so words that arrive late never land in a
    /// note opened since. `openSession` is the open note's; `lateSession` a closed one still finishing.
    @ObservationIgnored private var sessions = 0
    @ObservationIgnored private var openSession = 0
    @ObservationIgnored private var lateSession = 0
    /// The open note closes once its last words are in (Escape or the shortcut while it listened).
    @ObservationIgnored private var closeWhenDone = false
    /// The closed note the late words are added to, whether the late words made it, and whether its
    /// closing is announced.
    @ObservationIgnored private var lateItemID: Int64?
    @ObservationIgnored private var lateMadeNote = false
    @ObservationIgnored private var lateAnnounce = true

    init(library: Library) {
        self.library = library
        registerLinks()
    }

    // MARK: The note in the perch

    /// Opens a new, empty note in the perch, with the keyboard in it. With `listen` it starts listening
    /// at once (when Dictate is on and the microphone is allowed): the words go in as they are heard,
    /// and the first key typed stops listening. Nothing is saved until it has words.
    func openNew(listen: Bool = true) {
        draft = ""
        itemID = nil
        savedAt = nil
        typed = false
        dictated = false
        listenProblem = nil
        closeWhenDone = false
        // The editor is made for this note when the perch shows it (`attach`).
        editor = nil
        isOpen = true
        Log.write("notes", "a note was opened in the perch")
        onOpen?()
        if listen { startListening() }
    }

    /// Puts the keyboard in the open note's editor, if it is not there already.
    func focusEditor() {
        guard isOpen, let editor, !editor.hasKeyboard else { return }
        editor.takeKeyboard()
    }

    /// The perch's note editor was made: heard words go here, starting at its end.
    func attach(_ view: NoteTextView) {
        editor = view
        if listening || finishing { view.beginLive(at: (view.string as NSString).length) }
    }

    /// Starts the open note listening, or says plainly why it cannot. Without Dictate it is a note to type in.
    func startListening() {
        guard isOpen, !listening, !finishing, Features.on(.dictate), let dictation else { return }
        sessions += 1
        let session = sessions
        let result = dictation.listenForNote(
            words: { [weak self] words in self?.heard(words, session: session) },
            done: { [weak self] in self?.listeningEnded(session: session) })
        switch result {
        case .started:
            openSession = session
            listening = true
            editor?.beginLive(at: nil)
            Log.write("notes", "the new note is listening")
        case .microphoneNotAsked:
            listenProblem = "Allow the microphone to dictate"
            Task { [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self, self.isOpen, self.listenProblem != nil else { return }
                // Allowed while the note is still untouched: it starts listening, as it would have.
                self.listenProblem = allowed ? nil : "Microphone not allowed"
                if allowed, self.draft.isEmpty { self.startListening() }
            }
        case .microphoneDenied:
            listenProblem = "Microphone not allowed"
        case .busy, .off, .failed:
            break
        }
        if result != .started { Log.write("notes", "the new note opened for typing only: \(result)") }
    }

    /// Stops listening, keeping what was heard; the last words still go in.
    func stopListening() {
        guard listening else { return }
        listening = false
        finishing = true
        dictation?.finish()
    }

    /// A key was typed into the note in the perch. While it listens, typing takes over.
    func typedWhileListening() {
        guard listening else { return }
        Log.write("notes", "typing stopped the note listening")
        stopListening()
    }

    /// Words heard for a note, already cleaned up as Dictate cleans them. In the open note they go where
    /// the user was talking, even if typing has begun since. A note closed before they came has them
    /// added to its end, or, closed empty, they make a note of their own.
    private func heard(_ words: String, session: Int) {
        if isOpen, session == openSession {
            if let editor, editor.window != nil {
                editor.insertLive(words)
            } else {
                draft = Self.appending(words, to: draft)
                edited(dictated: true)
            }
        } else if session == lateSession {
            let old = lateItemID.flatMap { try? library.note(itemID: $0) }?.markdown ?? ""
            guard let item = try? library.saveNote(id: lateItemID, markdown: Self.appending(words, to: old), typed: false, dictated: true) else { return }
            if lateItemID == nil { lateMadeNote = true }
            lateItemID = item.id
            version += 1
            AppDelegate.app?.libraryVersion += 1
            Log.write("notes", "words that came after the note closed were added to it")
        }
    }

    /// A note's dictation is over: its last words are in.
    private func listeningEnded(session: Int) {
        if isOpen, session == openSession {
            listening = false
            finishing = false
            openSession = 0
            editor?.endLive()
            saveNow()
            if closeWhenDone { close(announce: lateAnnounce) }
        } else if session == lateSession {
            lateSession = 0
            // The bird said where the note went when it closed; a note made only of late words is said now.
            if lateMadeNote, lateAnnounce, let id = lateItemID, let item = try? library.item(id) { onClose?(item, true) }
            lateItemID = nil
            lateMadeNote = false
        }
    }

    /// `words` added at the end of a note, spaced as Dictate spaces them.
    static func appending(_ words: String, to markdown: String) -> String {
        markdown + Insertion.adapt(words, before: String(markdown.suffix(200)), after: "")
    }

    /// The open note changed: it is saved a moment after typing pauses.
    func edited(dictated wasDictated: Bool) {
        if wasDictated { dictated = true } else { typed = true }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves the open note now. A note with no words is not kept.
    @discardableResult
    func saveNow() -> SavedItem? {
        saving?.cancel()
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty {
            if let id = itemID, let item = try? library.item(id) {
                try? library.delete(item)
                itemID = nil
                savedAt = nil
                version += 1
            }
            return nil
        }
        do {
            let item = try library.saveNote(id: itemID, markdown: draft, typed: typed, dictated: dictated)
            itemID = item.id
            savedAt = Date()
            typed = false
            dictated = false
            version += 1
            AppDelegate.app?.libraryVersion += 1
            return item
        } catch {
            Log.write("notes", "a note could not be saved: \(error.localizedDescription)")
            return nil
        }
    }

    /// Closes the note in the perch, saved. The bird says so, with Open, unless `announce` is false.
    /// While it listens, listening stops first and the note closes once the last words are in. Asked
    /// again meanwhile, it closes at once, and the last words are added to the saved note when they come.
    func close(announce: Bool = true) {
        guard isOpen else { return }
        if listening || finishing, !closeWhenDone {
            closeWhenDone = true
            lateAnnounce = announce
            if listening { stopListening() }
            return
        }
        closeWhenDone = false
        // Closed straight after Return in a list: the empty point is not kept as a stray "-".
        let tidied = NoteLists.droppingEmptyLastPoint(draft)
        if tidied != draft { draft = tidied }
        let saved = saveNow()
        if listening || finishing {
            // Closed again before the last words came: they go to this note, saved, when they do.
            lateSession = openSession
            lateItemID = saved?.id
            lateMadeNote = false
            lateAnnounce = announce
            if listening { stopListening() }
        }
        listening = false
        finishing = false
        openSession = 0
        editor?.endLive()
        editor = nil
        isOpen = false
        Log.write("notes", saved == nil ? "the note was closed empty and not kept" : "the note was closed and saved")
        onClose?(saved, announce)
        draft = ""
        itemID = nil
    }

    // MARK: Getting a note out

    /// The note's Markdown, as saved.
    func markdown(of item: SavedItem) -> String {
        item.id.flatMap { try? library.note(itemID: $0)?.markdown } ?? item.body
    }

    /// Copy: the Markdown as plain text, and as rich text, so it pastes formatted in Mail and as marks in
    /// a code editor.
    static func copy(markdown: String, to board: NSPasteboard = .general) {
        RichCopy.copy(markdown: markdown, to: board)
    }

    /// A pasteboard of its own for test links, so a test run never touches the clipboard in use.
    static let testBoard = NSPasteboard(name: NSPasteboard.Name("com.jakeflavin.chirp.e2e-notes"))

    /// The formats Export… offers.
    enum Format: String, CaseIterable, Identifiable {
        case markdown, text, rtf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .markdown: "Markdown (.md)"
            case .text: "Plain text (.txt)"
            case .rtf: "Rich text (.rtf)"
            }
        }
        var ext: String {
            switch self {
            case .markdown: "md"
            case .text: "txt"
            case .rtf: "rtf"
            }
        }
        var type: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .text: .plainText
            case .rtf: .rtf
            }
        }
    }

    /// The note in a format, as the bytes of a file.
    static func data(markdown: String, as format: Format) -> Data? {
        switch format {
        case .markdown: return (markdown.hasSuffix("\n") ? markdown : markdown + "\n").data(using: .utf8)
        case .text: return (NoteMarkdown.plain(markdown) + "\n").data(using: .utf8)
        case .rtf:
            let html = "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, Helvetica, sans-serif; font-size: 13px\">"
                + RichText.html(fromMarkdown: markdown) + "</body></html>"
            guard let data = html.data(using: .utf8),
                let attributed = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            else { return nil }
            return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
    }

    /// The last format chosen in Export…, so the next export offers it first.
    static var lastFormat: Format {
        get { Format(rawValue: UserDefaults.standard.string(forKey: "notes.exportFormat") ?? "") ?? .markdown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "notes.exportFormat") }
    }

    /// A file name from a note's title.
    static func fileName(_ title: String) -> String { TextStats.fileName(title, fallback: "Note") }

    /// Writes a note to `url` in a format. The note itself is not changed; the list says when it was exported.
    func write(_ item: SavedItem, as format: Format, to url: URL) throws {
        guard let data = Self.data(markdown: markdown(of: item), as: format) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        if let id = item.id { try? library.setNoteExported(itemID: id) }
        version += 1
        Log.write("notes", "a note was exported as .\(format.ext)")
    }

    /// Export…: asks where and in which format (Markdown, plain text or rich text), then writes the file.
    func export(_ item: SavedItem) {
        let panel = NSSavePanel()
        panel.title = "Export Note"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        var format = Self.lastFormat
        panel.nameFieldStringValue = Self.fileName(item.title) + "." + format.ext
        panel.allowedContentTypes = [format.type]
        panel.allowsOtherFileTypes = false
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in Format.allCases { picker.addItem(withTitle: f.title) }
        picker.selectItem(at: Format.allCases.firstIndex(of: format) ?? 0)
        let changer = FormatChanger { index in
            format = Format.allCases[index]
            panel.allowedContentTypes = [format.type]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + format.ext
        }
        picker.target = changer
        picker.action = #selector(FormatChanger.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, picker])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = changer
        Self.lastFormat = format
        do { try write(item, as: format, to: url) } catch { AppDelegate.app?.report(error, doing: "export the note") }
    }

    /// Share: the Mac's own share menu, with the note's Markdown. Choosing a way to share counts as exporting.
    func share(_ item: SavedItem, from view: NSView, at rect: NSRect) {
        let picker = NSSharingServicePicker(items: [markdown(of: item) as NSString])
        let watcher = ShareWatcher { [weak self] in
            if let id = item.id { try? self?.library.setNoteExported(itemID: id) }
            self?.version += 1
        }
        picker.delegate = watcher
        ShareWatcher.current = watcher
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // MARK: Test links

    private func registerLinks() {
        guard LinkHandler.debugEnabled else { return }
        // `note?do=open|close|type&text=…|dictate&text=…|caret=N|save`: the note in the perch, as the
        // keyboard, Escape and right ⌥ would drive it. `open` is the New Note shortcut's own path (it
        // starts listening); `press&text=…` sends real key presses, `stop` and `listen` stop and start
        // listening. `state` has `notes` (with `listening`, `finishing`, `perchEditorKey`).
        LinkHandler.commands["note"] = { [weak self] q in
            guard let self else { return }
            switch q["do"] {
            case "open": PerchController.shared?.note()
            case "close": self.close()
            case "type":
                if let words = q["text"] {
                    // Typing, as far as a listening note is concerned.
                    self.typedWhileListening()
                    if let view = NoteTextView.focused ?? NoteEditor.Coordinator.current?.textView {
                        view.insertText(words, replacementRange: view.selectedRange())
                    } else {
                        self.draft += words
                        self.edited(dictated: false)
                    }
                }
            case "keys":
                // Typed one key at a time, as the keyboard does: "\n" is Return (lists continue and end).
                if let words = q["text"], let view = NoteTextView.focused ?? NoteEditor.Coordinator.current?.textView {
                    self.typedWhileListening()
                    for ch in words {
                        if ch == "\n" { view.insertNewline(nil) } else { view.insertText(String(ch), replacementRange: view.selectedRange()) }
                    }
                }
            case "press":
                // Real key presses into the perch's note, as the keyboard sends them: the first one stops
                // listening, and each still goes in.
                if let words = q["text"], let view = self.editor {
                    for ch in words {
                        let text = ch == "\n" ? "\r" : String(ch)
                        guard let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: text,
                            charactersIgnoringModifiers: text, isARepeat: false, keyCode: ch == "\n" ? 36 : 0)
                        else { continue }
                        view.keyDown(with: event)
                    }
                }
            case "stop": self.stopListening()
            case "listen": self.startListening()
            case "dictate":
                if let words = q["text"], let view = NoteEditor.Coordinator.current?.textView { view.insertDictated(words) }
            case "caret":
                if let at = Int(q["at"] ?? ""), let view = NoteEditor.Coordinator.current?.textView {
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: min(at, (view.string as NSString).length), length: 0))
                }
            case "save": self.saveNow()
            default: break
            }
        }
        // `note-export?n=0&format=md&path=/tmp/x.md`: the nth note, newest first, written without the panel.
        // `note-copy?n=0`: Copy, as the button does.
        LinkHandler.commands["note-export"] = { [weak self] q in
            guard let self, let path = q["path"], let item = self.nth(q) else { return }
            let format = Format.allCases.first { $0.ext == (q["format"] ?? "md") } ?? .markdown
            try? self.write(item, as: format, to: URL(fileURLWithPath: path))
        }
        LinkHandler.commands["note-copy"] = { [weak self] q in
            guard let self, let item = self.nth(q) else { return }
            Self.copy(markdown: self.markdown(of: item), to: Self.testBoard)
        }
        LinkHandler.stateProviders["notes"] = { [weak self] in
            guard let self else { return [:] }
            let view = NoteEditor.Coordinator.current?.textView
            let board = Self.testBoard
            let saved = ((try? self.library.items(kinds: [.voiceNote], limit: 5)) ?? []).map { item -> [String: Any] in
                let extra = item.id.flatMap { try? self.library.note(itemID: $0) }
                return ["title": item.title, "body": item.body, "markdown": extra?.markdown ?? "", "typed": extra?.typed ?? false,
                        "dictated": extra?.dictated ?? false, "exported": extra?.exportedAt != nil, "audio": item.audioFile ?? ""]
            }
            return ["open": self.isOpen, "draft": self.draft, "itemID": self.itemID ?? -1, "saved": self.savedAt != nil,
                    "editor": view?.string ?? "", "editorKey": view?.hasKeyboard ?? false, "focused": NoteTextView.focused != nil,
                    "issues": NoteEditor.Coordinator.current?.issues.count ?? 0,
                    "count": ((try? self.library.items(kinds: [.voiceNote])) ?? []).count,
                    "listening": self.listening, "finishing": self.finishing, "listenProblem": self.listenProblem ?? "",
                    "perchEditor": self.editor?.string ?? "", "perchEditorKey": self.editor?.hasKeyboard ?? false,
                    "panelKey": self.editor?.window?.isKeyWindow ?? false, "chirpActive": NSApp.isActive,
                    "clipboardText": board.string(forType: .string) ?? "", "clipboardRTF": board.data(forType: .rtf) != nil,
                    "clipboardHTML": board.data(forType: .html) != nil, "items": saved] as [String: Any]
        }
    }

    private func nth(_ q: [String: String]) -> SavedItem? {
        let items = (try? library.items(kinds: [.voiceNote])) ?? []
        return items[safe: Int(q["n"] ?? "0") ?? 0]
    }
}

/// Follows the format picker in Export…'s panel.
private final class FormatChanger: NSObject {
    let onChange: (Int) -> Void
    init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}

/// Tells the note when the share menu was used.
private final class ShareWatcher: NSObject, NSSharingServicePickerDelegate {
    nonisolated(unsafe) static var current: ShareWatcher?
    let chose: () -> Void
    init(_ chose: @escaping () -> Void) { self.chose = chose }
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service != nil { chose() }
        Self.current = nil
    }
}
