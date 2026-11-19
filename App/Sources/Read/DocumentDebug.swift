import AppKit
import ChirpCore
import SwiftUI

/// Test links for the Documents page, folders and pins (`chirp://debug/…`, only with `--debug-hooks`),
/// and what they report under `documents` in `state`. They do what the window's own controls do,
/// through the same library calls, so a test copy can be driven and photographed without a pointer.
@MainActor
enum DocumentDebug {
    static func register(app: AppModel, reader: ReadController) {
        let library = Library(store: app.store)
        func item(_ q: [String: String]) -> SavedItem? {
            guard let title = q["title"] else { return nil }
            // The oldest of that name, so a later import of the same file does not take its place.
            return ((try? library.items()) ?? []).last { $0.title == title }
        }
        func changed() { app.libraryVersion += 1 }

        // `folder?add=Name`, `folder?rename=Old&to=New`, `folder?delete=Name`, `folder?open=Name`.
        LinkHandler.commands["folder"] = { q in
            let folders = (try? library.folders()) ?? []
            if let name = q["add"] { _ = try? library.addFolder(name) }
            if let name = q["rename"], let folder = folders.first(where: { $0.name == name }) { try? library.rename(folder, to: q["to"] ?? "") }
            if let name = q["delete"], let folder = folders.first(where: { $0.name == name }) {
                try? library.delete(folder)
                if app.section == .folder, app.folderID == folder.id { app.section = .home }
            }
            // `folder?edit=new` shows the field a new folder is named in; `folder?edit=Name` the one for renaming.
            if let name = q["edit"] {
                app.folderEdit = name == "new" ? FolderEdit(id: nil, name: "New folder") : folders.first { $0.name == name }.map { FolderEdit(id: $0.id, name: $0.name) }
            }
            if let name = q["open"], let folder = folders.first(where: { $0.name == name }) {
                app.folderID = folder.id
                app.section = .folder
            }
            changed()
        }
        // `item?title=…` with `pin=1|0`, `folder=Name` (empty for none), `open=1`, `position=<sentence>`, `age=<days>`.
        LinkHandler.commands["item"] = { q in
            guard let found = item(q), let id = found.id else { return }
            if let pin = q["pin"] { try? library.setPinned(id: id, pin == "1") }
            if let name = q["folder"] {
                try? library.setFolder(id: id, ((try? library.folders()) ?? []).first { $0.name == name }?.id)
            }
            // `age=<days>` makes it that many days old, for looking at the dated groups.
            if let days = q["age"].flatMap({ Double($0) }) {
                try? library.setCreated(id: id, Date().addingTimeInterval(-days * 86_400))
            }
            if let n = q["position"].flatMap({ Int($0) }) {
                // Closed first: closing keeps the place the reader was at, which would undo this one.
                if reader.item?.id == id { reader.close() }
                let sentences = ReadingText.sentences(found.body)
                if sentences.indices.contains(n) { try? library.setPosition(id: id, position: sentences[n].offset) }
            }
            changed()
            if q["open"] == "1", let fresh = try? library.item(id) {
                app.open(fresh)
                // The window does this when it is open; a test copy may be driven without it.
                if fresh.kind == .document { reader.open(fresh) }
            }
        }
        // `doc-view?original=1|0`: the toolbar's Reading view / Original switch.
        LinkHandler.commands["doc-view"] = { q in reader.showOriginal = q["original"] == "1" }
        // `summary-seed?title=…&file=<markdown file>` (or `text=`) gives a document a summary without the model;
        // `summary-fold?title=…&folded=1|0` folds its panel.
        LinkHandler.commands["summary-seed"] = { q in
            guard var found = item(q) else { return }
            found.summary = q["file"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? q["text"] ?? ""
            _ = try? library.save(found)
            if reader.item?.id == found.id { reader.close() }
            changed()
        }
        LinkHandler.commands["summary-fold"] = { q in
            guard let id = item(q)?.id else { return }
            try? library.setSummaryCollapsed(itemID: id, q["folded"] != "0")
            changed()
        }
        // `copy-check?title=…&what=summary|document` copies as the buttons do, onto a clipboard of its own
        // (the real one is left alone), and reports the kinds put there.
        LinkHandler.commands["copy-check"] = { q in
            guard let found = item(q), let id = found.id else { return }
            var markdown = found.summary
            if q["what"] == "document" {
                markdown = found.body
                if let extra = try? library.documentExtra(itemID: id), let layout = DocLayout(json: extra.layout), layout.fits(length: found.body.utf16.count) {
                    markdown = layout.markdown(found.body)
                }
            }
            let board = NSPasteboard(name: NSPasteboard.Name("chirp-debug-\(ProcessInfo.processInfo.processIdentifier)"))
            RichCopy.copy(markdown: markdown, to: board)
            copied = ["types": (board.types ?? []).map(\.rawValue), "plain": board.string(forType: .string) ?? "",
                      "html": board.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                      "rtfBytes": board.data(forType: .rtf)?.count ?? 0]
            board.releaseGlobally()
        }
        // `read-page?file=<text file>&link=…&title=…&keep=1`: text read off a web page in another app, as
        // Read aloud and Summarize gather it, opened without being kept; with `keep` it is kept.
        LinkHandler.commands["read-page"] = { q in
            guard let text = q["file"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }),
                var imported = try? DocumentImporter.importText(text, title: q["title"])
            else { return }
            if let link = q["link"] { imported.source = link }
            reader.openOnce(imported)
            if q["keep"] == "1", let saved = reader.keepCurrent() { app.open(saved) }
        }
        // `doc-transcript?title=…&link=…&audio=<file>&speakers=2`: a transcribed link as it is filed, without
        // the speech model: a few lines, the sound copied into the library.
        LinkHandler.commands["doc-transcript"] = { q in
            let lines = [
                ("A", 0.0, "So when you say calm, what does the software actually do differently?"),
                ("B", 7.0, "It waits. Most apps treat every event as a reason to interrupt you. A calm one keeps things at the edge until you turn toward them."),
                ("A", 25.0, "Give me an example from something you shipped."),
                ("B", 29.0, "We took the badge count off the icon. People opened it less often, and finished more of what they started when they did."),
                ("A", 49.0, "Did anyone complain that they missed things?"),
                ("B", 53.0, "A few, in the first week. Then we added one summary a day, at a time they chose, and the complaints stopped."),
            ]
            let two = q["speakers"] != "1"
            var audio: String?
            if let path = q["audio"] {
                let name = "debug-\(UUID().uuidString).\((path as NSString).pathExtension)"
                try? FileManager.default.createDirectory(at: ChirpStore.audioDirectory, withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(atPath: path, toPath: ChirpStore.audioDirectory.appendingPathComponent(name).path)) != nil { audio = name }
            }
            guard let saved = try? library.save(SavedItem(kind: .voiceNote, title: q["title"] ?? "Designing calm software", audioFile: audio, duration: Double(q["duration"] ?? "") ?? 2530)),
                let id = saved.id
            else { return }
            try? library.replaceSegments(itemID: id, with: lines.enumerated().map { n, line in
                TranscriptSegment(itemID: id, speaker: two ? (line.0 == "A" ? "Them" : "Speaker 2") : "Me", start: line.1, end: lines[safe: n + 1]?.1 ?? line.1 + 8, text: line.2)
            })
            TranscribedDocument.file(id, link: q["link"], file: URL(fileURLWithPath: q["audio"] ?? "/tmp/sound.m4a"), in: library)
            changed()
            if let fresh = try? library.item(id) {
                app.open(fresh)
                reader.open(fresh)
            }
        }
        // `doc-keep?original=0|1&images=0|1`: the two switches under "What is saved for documents".
        LinkHandler.commands["doc-keep"] = { q in
            if let v = q["original"] { UserDefaults.standard.set(v == "1", forKey: DocumentImporter.Keep.originalKey) }
            if let v = q["images"] { UserDefaults.standard.set(v == "1", forKey: DocumentImporter.Keep.imagesKey) }
        }
        // `link-kind?url=…` says which way "Add a Link" would take it.
        LinkHandler.commands["link-kind"] = { q in linkKind = LinkKind.isMedia(q["url"] ?? "") ? "media" : "page" }

        LinkHandler.stateProviders["documents"] = {
            let folders = (try? library.folders()) ?? []
            let counts = (try? library.folderCounts()) ?? [:]
            let all = (try? library.items(kinds: [.document, .note])) ?? []
            LibraryRows.refresh(library)
            var state: [String: Any] = [
                "folders": folders.map { ["name": $0.name, "count": counts[$0.id ?? -1] ?? 0] as [String: Any] },
                "openFolder": app.section == .folder ? folders.first { $0.id == app.folderID }?.name ?? "" : "",
                "folderItems": app.section == .folder ? ((try? library.items(folderID: app.folderID)) ?? []).map(\.title) : [],
                "groups": DocumentRows.groups(all).map { ["title": $0.title, "items": $0.items.map(\.title)] as [String: Any] },
                "rows": all.map { item in
                    ["title": item.title, "meta": LibraryRows.meta(item) + (item.folderID.flatMap { f in folders.first { $0.id == f }?.name }.map { " · \($0)" } ?? "")]
                },
                "subtitle": DocumentRows.subtitle(all),
                // What was transcribed from a file or a link: filed as documents, with their words.
                "transcribed": all.filter { LibraryRows.extra($0)?.isTranscript == true }.map { item in
                    ["title": item.title, "format": LibraryRows.extra(item)?.format ?? "", "text": String(item.body.prefix(400)),
                     "summary": item.summary, "lines": (try? library.segments(itemID: item.id ?? -1))?.count ?? 0] as [String: Any]
                },
                "pinnedOnHome": ((try? library.pinned(kinds: Features.shared.set.shownKinds, limit: 12)) ?? []).map(\.title),
                "showOriginal": reader.showOriginal,
                "copied": copied,
                "linkKind": linkKind,
                "keepOriginal": DocumentImporter.Keep.original, "keepImages": DocumentImporter.Keep.images,
            ]
            // The document the reader holds, as the detail side shows it.
            if let open = reader.item, let id = open.id {
                let extra = try? library.documentExtra(itemID: id)
                let layout = extra.flatMap { DocLayout(json: $0.layout) } ?? DocLayout.plain(open.body)
                let source = DocumentRows.source(
                    open, extra: extra, readSeconds: LibraryRows.measure(open).seconds, speakers: (try? library.speakerCount(itemID: id)) ?? 0,
                    folder: open.folderID.flatMap { f in folders.first { $0.id == f }?.name })
                let folder = extra?.folderURL
                let images = layout.blocks.filter { $0.kind == .image }
                let playing = reader.isPlaying || reader.wordRange != nil
                state["open"] = [
                    "title": open.title, "kind": open.kind.rawValue,
                    "sourceLink": source.link?.absoluteString ?? "", "sourceTitle": source.linkTitle, "sourceRest": source.rest,
                    "format": extra?.format ?? "", "site": extra?.site ?? "", "pages": extra?.pages ?? 0, "transcript": extra?.isTranscript ?? false,
                    "layoutKept": !(extra?.layout.isEmpty ?? true), "layoutFits": layout.fits(length: open.body.utf16.count),
                    "blocks": Dictionary(layout.blocks.map { ($0.kind.rawValue, 1) }, uniquingKeysWith: +),
                    "spans": Dictionary(layout.blocks.flatMap(\.spans).map { ($0.style.rawValue, 1) }, uniquingKeysWith: +),
                    "images": images.count,
                    "imagesOnDisk": images.filter { b in b.image.map { folder?.appendingPathComponent($0) }.flatMap { $0 }.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }.count,
                    "original": extra?.original ?? "",
                    "originalOnDisk": extra?.originalURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                    "summary": open.summary, "summaryFolded": extra?.summaryCollapsed ?? false, "summaryLine": DocumentRows.summaryLine(open.summary),
                    // The place it was left: the marker and Continue show when it is past the start and nothing is being read.
                    "sentence": reader.index, "position": open.position,
                    "leftOff": !playing && reader.index > 0, "continueShown": !reader.isPlaying && reader.index > 0 && !reader.isPreparing,
                    "speakers": (try? library.segments(itemID: id))?.reduce(into: [String]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } } ?? [],
                    "lines": (try? library.segments(itemID: id))?.count ?? 0,
                    "audio": open.audioFile.map { FileManager.default.fileExists(atPath: ChirpStore.audioDirectory.appendingPathComponent($0).path) } ?? false,
                ] as [String: Any]
            }
            return state
        }
    }

    private static var copied: [String: Any] = [:]
    private static var linkKind = ""
}
