import AppKit
import ChirpCore
import SwiftUI

/// A note full size on the Notes page: the same editor as the
/// perch's, with what can be done with it above (Copy, Export…, Share, Read aloud). A voice note is the
/// same editable note, with its audio to play at the foot.
struct NoteDetail: View {
    @Environment(PerchController.self) private var perch
    @Environment(ReadController.self) private var reader
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(AppModel.self) private var app
    let item: SavedItem
    let folders: [Folder]
    /// The shared header's "…" menu (Pin, Move to Folder, Attach a File…, Delete…); its own actions here
    /// are a note's (Copy, Export…, Share, Read aloud).
    var header = ItemHeaderParts()
    @State private var markdown = ""
    @State private var facts: NoteExtra?
    @State private var loadedFor: Int64?
    @State private var saving: Task<Void, Never>?
    @State private var typed = false
    @State private var dictated = false
    @State private var copied = false
    @State private var context = RecordingContext()
    @State private var shareAnchor = NSView()

    private var audio: URL? { item.audioFile.map { ChirpStore.audioDirectory.appendingPathComponent($0) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                top
                NoteEditor(
                    text: $markdown, look: .page, checks: NoteController.checksWriting,
                    listening: perch.dictation.phase == .recording && NoteTextView.focused?.accessibilityIdentifier() == "library.note",
                    level: perch.dictation.levels.last ?? 0,
                    // A new note opens with the cursor in it.
                    focusOnAppear: item.body.isEmpty, identifier: "library.note",
                    onEdit: { wasDictated in edited(dictated: wasDictated) }
                )
                .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 10)
                .padding(.bottom, audio == nil ? 12 : 84)
                if !context.notes.isEmpty, audio != nil {
                    // Notes typed during the recording, with their moments, as on a meeting.
                    MyNotesList(notes: context.notes) { note in if let audio { AudioPlayback.shared.play(audio, at: note.at) } }
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.bottom, 90)
                }
            }
            .padding(.leading, 30).padding(.trailing, 40).padding(.top, 16)
            if let audio {
                PlaybackDock(url: audio, fallbackDuration: item.duration, marks: context.notes.map(\.at))
                    .padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .onAppear(perform: load)
        .onChange(of: item.id) { _, _ in
            saveNow()
            load()
        }
        .onChange(of: perch.notes.version) { _, _ in reloadIfUntouched() }
        .onDisappear(perform: saveNow)
        .accessibilityIdentifier("note.detail")
    }

    // MARK: Head

    /// "Note · typed and dictated · edited 9:14", or "Note · 2 min · audio kept · today 8:32" for a voice note (a voice note is a Note).
    private var meta: String {
        var parts: [String] = []
        if item.audioFile != nil || item.duration > 0 {
            parts.append("Note")
            if item.duration > 0 { parts.append(LibraryRows.length(item.duration)) }
            if item.audioFile != nil { parts.append("audio kept") }
            parts.append(NoteRows.when(item.createdAt))
        } else {
            parts.append("Note")
            switch (facts?.typed ?? false, facts?.dictated ?? false) {
            case (true, true): parts.append("typed and dictated")
            case (false, true): parts.append("dictated")
            default: break
            }
            parts.append(facts?.editedAt.map { "edited " + NoteRows.when($0, lower: true) } ?? NoteRows.when(item.createdAt))
        }
        if let folder = item.folderID.flatMap({ id in folders.first { $0.id == id }?.name }) { parts.append(folder) }
        if let exported = facts?.exportedAt { parts.append("exported " + exported.formatted(.dateTime.day().month(.abbreviated))) }
        return parts.joined(separator: " · ")
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(item.audioFile != nil ? "chirp.voiceNote" : "chirp.note").font(.system(size: 11)).accessibilityHidden(true)
                Text(meta).lineLimit(1)
            }
            .font(.system(size: 12)).foregroundStyle(Color.quiet)
            .accessibilityIdentifier("note.meta")
            // The shared header (ItemHeader.swift): a note's own actions, then "…" for the rest.
            ItemActionBar(actions: noteActions, more: header.more)
                .background(ShareAnchor(view: shareAnchor).frame(width: 1, height: 1), alignment: .leading)
        }
    }

    /// Copy, Export…, Share and Read aloud, greyed while the note has no words.
    private var noteActions: [HeaderAction] {
        let empty = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var out = [
            HeaderAction(id: "copy", title: copied ? "Copied" : "Copy", symbol: copied ? "chirp.check" : "chirp.copy",
                         help: "Copy as Markdown and as rich text", disabled: empty) { copy() },
            HeaderAction(id: "export", title: "Export…", symbol: "chirp.export",
                         help: "Save it as a Markdown, plain text or rich text file", disabled: empty) { export() },
            HeaderAction(id: "share", title: "Share", symbol: "chirp.share", help: "Mail, Messages, Notes, AirDrop", disabled: empty) { share() },
        ]
        if Features.on(.read) {
            out.append(HeaderAction(id: "readAloud", title: "Read aloud", symbol: "chirp.read", help: "Read the note aloud", disabled: empty) { readAloud() })
        }
        return out
    }

    // MARK: Saving

    private func load() {
        guard let id = item.id else { return }
        saving?.cancel()
        markdown = perch.notes.markdown(of: item)
        facts = (try? recorder.library.note(itemID: id)) ?? nil
        context = RecordingContext(json: item.context)
        loadedFor = id
    }

    /// Saved elsewhere (the same note in the perch): read again, unless something is waiting to be saved here.
    private func reloadIfUntouched() {
        guard saving == nil, let id = item.id, perch.notes.itemID == id else { return }
        load()
    }

    private func edited(dictated wasDictated: Bool) {
        if wasDictated { dictated = true } else { typed = true }
        saving?.cancel()
        saving = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saving?.cancel()
        saving = nil
        guard let id = loadedFor, typed || dictated else { return }
        _ = try? recorder.library.saveNote(id: id, markdown: markdown, typed: typed, dictated: dictated)
        typed = false
        dictated = false
        facts = (try? recorder.library.note(itemID: id)) ?? nil
        app.libraryVersion += 1
    }

    // MARK: Getting it out

    private func copy() {
        saveNow()
        NoteController.copy(markdown: markdown)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export() {
        saveNow()
        guard let id = item.id, let fresh = try? recorder.library.item(id) else { return }
        perch.notes.export(fresh)
        facts = (try? recorder.library.note(itemID: id)) ?? nil
        app.libraryVersion += 1
    }

    private func share() {
        saveNow()
        guard let id = item.id, let fresh = try? recorder.library.item(id) else { return }
        perch.notes.share(fresh, from: shareAnchor, at: shareAnchor.bounds)
    }

    private func readAloud() {
        reader.readOnce(DocumentImporter.Imported(title: item.title, text: NoteMarkdown.plain(markdown), source: "Notes"))
    }
}

/// Holds an AppKit view under the Share button, for the share menu to open from.
private struct ShareAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// How a note's times are said in the list and its head row.
@MainActor
enum NoteRows {
    /// "9:14" today, "Sat 14 Nov" before.
    static func when(_ date: Date, lower: Bool = false) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return lower ? "yesterday" : "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// A row's line under the title in the Notes list: "Note · edited 9:14 · Launch",
    /// "Note · 2 min · audio kept" (a voice note), "Note · Sat 14 Nov · exported 15 Nov".
    static func line(_ item: SavedItem, facts: NoteExtra?, folder: String?) -> String {
        var parts: [String] = []
        if item.audioFile != nil || item.duration > 0 {
            parts.append("Note")
            if item.duration > 0 { parts.append(LibraryRows.length(item.duration)) }
            if item.audioFile != nil { parts.append("audio kept") }
        } else {
            parts.append("Note")
            if let edited = facts?.editedAt, Calendar.current.isDateInToday(edited) {
                parts.append("edited " + when(edited, lower: true))
            } else {
                parts.append(when(item.createdAt))
            }
        }
        if let exported = facts?.exportedAt { parts.append("exported " + exported.formatted(.dateTime.day().month(.abbreviated))) }
        if let folder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }
}
