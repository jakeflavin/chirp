import AppKit
import ChirpCore
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Turns files, web pages and pasted text into plain reading text.
enum DocumentImporter {
    /// Why something could not be imported, worded for the user.
    enum ImportError: LocalizedError {
        case unsupported(String)
        case empty
        case scanned
        case locked
        case fetch(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "Chirp cannot read .\(ext) files yet. Try PDF, EPUB, Word, text or a web page."
            case .empty: "No readable text was found."
            case .scanned: "This PDF is made of scanned images, with no text to read. Chirp cannot read scans yet."
            case .locked: "This PDF is locked with a password. Chirp cannot open it."
            case .fetch(let why): "The page could not be loaded: \(why)"
            }
        }
    }

    /// Text ready for the reader: tidied for listening, with a title and where it came from, and what
    /// goes with it when it is kept: how it is laid out, the original, its pictures.
    struct Imported {
        var title: String
        var text: String
        /// The file's path, the page's address, or a few words such as "Pasted text".
        var source: String
        /// How the text is laid out; nil for plain text, which is laid out from how its lines are written.
        var layout: DocLayout?
        /// The site's own name for a page.
        var site = ""
        /// "PDF", "EPUB", "Word", "Web page" and so on.
        var format = ""
        var pages = 0
        /// A folder of files waiting to be kept with the document (the original, pictures). It is in the
        /// temporary folder until the document is saved; nothing reaches the library before that.
        var staging: URL?
        /// The original's name in that folder.
        var original: String?
        /// Who wrote a book and how it is divided, as the file itself says: "Cal Newport. 4 parts, 15
        /// chapters. Starts at the introduction." Empty when the file says neither. Shown when a file is
        /// dropped on the perch; not kept with the document.
        var about = ""
    }

    /// What is saved with a document (Settings › Models). Both are on unless switched off.
    enum Keep {
        static let originalKey = "documentsKeepOriginal"
        static let imagesKey = "documentsKeepImages"
        static var original: Bool { UserDefaults.standard.object(forKey: originalKey) as? Bool ?? true }
        static var images: Bool { UserDefaults.standard.object(forKey: imagesKey) as? Bool ?? true }
    }

    /// The most pictures kept with one document, and the largest one kept.
    static let imageLimit = 120
    static let imageBytes = 12_000_000

    /// A new folder for one import's files, in the temporary folder.
    static func newStaging() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-import-\(UUID().uuidString)", isDirectory: true)
        return (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) == nil ? nil : dir
    }

    /// Removes import folders left in the temporary folder by documents that were opened and never kept.
    static func clearStaging() {
        let tmp = FileManager.default.temporaryDirectory
        // Only ones a day old: a newer one may belong to a document that is open now, here or in another copy of Chirp.
        let old = Date().addingTimeInterval(-86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("chirp-import-") {
            let url = tmp.appendingPathComponent(name)
            if let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, made < old { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Keeps a copy of the original file with the import, when the setting says to.
    private static func stageOriginal(_ url: URL, into imported: inout Imported) {
        guard Keep.original, let dir = imported.staging ?? newStaging() else { return }
        imported.staging = dir
        let ending = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
        let name = "original" + ending
        if (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))) != nil { imported.original = name }
    }

    /// Copies the pictures a document names, from files beside it, into the import's folder, and points
    /// the layout at the copies. `allowed` says which files may be read (a book may only name its own).
    private static func stageLocalImages(_ builder: inout DocBuilder, into imported: inout Imported, allowed: (URL) -> Bool) {
        guard Keep.images, builder.layout.blocks.contains(where: { $0.kind == .image }), let dir = imported.staging ?? newStaging() else {
            builder.mapImages { _ in nil }
            return
        }
        imported.staging = dir
        var n = 0
        var known: [String: String] = [:]
        builder.mapImages { source in
            if let done = known[source] { return done }
            guard n < imageLimit, let url = source.hasPrefix("file:") ? URL(string: source) : nil, allowed(url),
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= imageBytes
            else { return nil }
            n += 1
            let name = "img-\(n)." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
            guard (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))) != nil else { return nil }
            known[source] = name
            return name
        }
    }

    /// The kinds of file the open panel offers. `importFile` decides by file extension.
    static let supportedTypes: [UTType] = [
        .pdf, .epub, .plainText, .rtf, .html, UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
        UTType("net.daringfireball.markdown") ?? .plainText,
    ]

    /// Reads a file's text, choosing how by its extension. Throws when the kind is not supported, the
    /// file has no text (a scanned PDF, say) or it cannot be read.
    static func importFile(_ url: URL) throws -> Imported {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        var title = name
        var text: String
        var out = Imported(title: "", text: "", source: url.path, format: DocumentRows.format(ofFileEnding: ext))
        // A folder made for this import goes again if the import fails.
        var done = false
        defer { if !done, let dir = out.staging { try? FileManager.default.removeItem(at: dir) } }
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ImportError.empty }
            // A locked PDF gives no text either, but it is not a scan: say what it is.
            if pdf.isLocked { throw ImportError.locked }
            let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
            text = ReadingText.clean(pages.joined(separator: "\n"), pages: pages)
            if text.count < 20, pdf.pageCount > 0 { throw ImportError.scanned }
            if let t = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { title = t }
            out.pages = pdf.pageCount
            out.about = pdfAbout(pdf)
        case "epub":
            var builder: DocBuilder
            (title, builder) = try epub(url, fallbackTitle: name, into: &out)
            text = builder.text
            out.layout = builder.layout
        case "docx", "doc", "rtf", "rtfd", "odt":
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            var builder = AttributedDocument.blocks(from: attributed, into: &out)
            if builder.isEmpty {
                text = ReadingText.clean(attributed.string)
            } else {
                if !Keep.images { builder.mapImages { _ in nil } }
                text = builder.text
                out.layout = builder.layout
            }
        case "html", "htm", "xhtml":
            let article = HTMLDocument.article(from: try readText(url), base: url)
            var builder = article.builder
            // A page saved to disk may name pictures in the folder it sits in, and nowhere else.
            let root = url.deletingLastPathComponent().standardizedFileURL.path + "/"
            stageLocalImages(&builder, into: &out) { $0.standardizedFileURL.path.hasPrefix(root) }
            text = builder.text
            out.layout = builder.layout
            out.site = article.site
            if !article.title.isEmpty { title = article.title }
        case "md", "markdown":
            var builder = MarkdownDocument.blocks(from: try readText(url))
            // Pictures named beside the file are kept; ones on the web are left out (nothing is fetched for a file).
            let folder = url.deletingLastPathComponent()
            let root = folder.standardizedFileURL.path + "/"
            builder.mapImages { source in source.contains("://") ? nil : URL(fileURLWithPath: source, relativeTo: folder).absoluteURL.absoluteString }
            stageLocalImages(&builder, into: &out) { $0.standardizedFileURL.path.hasPrefix(root) }
            text = builder.text
            out.layout = builder.layout
        case "txt", "text", "":
            text = ReadingText.clean(try readText(url))
        default:
            throw ImportError.unsupported(ext)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        stageOriginal(url, into: &out)
        out.title = title
        out.text = text
        done = true
        return out
    }

    /// The text of a file attached to a recording, or nothing when Chirp cannot read that kind (the file is
    /// still kept and opens). Everything `importFile` reads, and PowerPoint, Excel and comma-separated
    /// files, which are for looking things up in rather than reading aloud.
    static func attachmentText(_ url: URL) -> String {
        if let read = try? importFile(url) {
            // Only the words are wanted here: the copies made for a document are not kept.
            if let made = read.staging { try? FileManager.default.removeItem(at: made) }
            return read.text
        }
        switch url.pathExtension.lowercased() {
        case "pptx":
            return unzipped(url) { folder in
                let slides = folder.appendingPathComponent("ppt/slides")
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: slides.path)) ?? []).filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
                return OfficeText.inOrder(names).compactMap { try? readText(slides.appendingPathComponent($0)) }
                    .map(OfficeText.slide).filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        case "xlsx":
            return unzipped(url) { folder in
                let strings = (try? readText(folder.appendingPathComponent("xl/sharedStrings.xml"))).map(OfficeText.sharedStrings) ?? []
                let sheets = folder.appendingPathComponent("xl/worksheets")
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: sheets.path)) ?? []).filter { $0.hasPrefix("sheet") && $0.hasSuffix(".xml") }
                return OfficeText.inOrder(names).compactMap { try? readText(sheets.appendingPathComponent($0)) }
                    .map { OfficeText.sheet($0, strings: strings) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        case "csv", "tsv":
            return (try? readText(url)).map(OfficeText.csv) ?? ""
        default:
            return ""
        }
    }

    /// Unpacks a zipped document into a folder of its own, reads it with `read`, and removes the folder.
    private static func unzipped(_ url: URL, _ read: (URL) -> String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-office-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return "" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", dir.path]
        unzip.standardOutput = nil
        unzip.standardError = nil
        guard (try? unzip.run()) != nil else { return "" }
        unzip.waitUntilExit()
        return read(dir)
    }

    /// Tidies pasted or selected text for reading. Without a title, one is made from its first words.
    static func importText(_ raw: String, title: String? = nil) throws -> Imported {
        let text = ReadingText.clean(raw)
        guard !text.isEmpty else { throw ImportError.empty }
        return Imported(title: title ?? Library.title(from: text), text: text, source: "Pasted text")
    }

    /// Loads a web page and keeps its article text. This is the one place Chirp uses the network
    /// for content, and only for an address the user typed.
    static func importWebPage(_ address: String) async throws -> Imported {
        var string = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), url.host != nil else { throw ImportError.fetch("that is not a web address") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh) Chirp reader", forHTTPHeaderField: "User-Agent")
        let loaded: (Data, URLResponse)
        do { loaded = try await URLSession.shared.data(for: request) } catch {
            throw ImportError.fetch(error.localizedDescription)
        }
        let (data, response) = loaded
        // An error page ("not found", "sign in") is not the article that was asked for.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.fetch("the site answered with error \(http.statusCode)")
        }
        // The encoding the site says the page is in, for pages that are not UTF-8.
        var named: String.Encoding?
        if let name = response.textEncodingName {
            let known = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if known != kCFStringEncodingInvalidId {
                named = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(known))
            }
        }
        let html = decodeText(data, named: named)
        let page = response.url ?? url
        let article = HTMLDocument.article(from: html, base: page)
        var builder = article.builder
        guard builder.text.count > 80 else { throw ImportError.empty }
        var out = Imported(title: article.title.isEmpty ? (url.host ?? "Web page") : article.title, text: "", source: url.absoluteString, site: article.site, format: "Web page")
        await stageWebImages(&builder, into: &out)
        out.text = builder.text
        out.layout = builder.layout
        // The original of a page is a copy of it, saved now, so it opens even if the site changes.
        if Keep.original, let dir = out.staging ?? newStaging() {
            out.staging = dir
            if let archive = await PageSaver.archive(of: page), (try? archive.write(to: dir.appendingPathComponent("page.webarchive"))) != nil {
                out.original = "page.webarchive"
            } else if (try? data.write(to: dir.appendingPathComponent("page.html"))) != nil {
                // The page as it was sent, when the full copy could not be made.
                out.original = "page.html"
            }
        }
        return out
    }

    /// Fetches the pictures a page's article names and points the layout at the copies. Each is asked
    /// for once, from the address the page gives, and only pictures are kept.
    private static func stageWebImages(_ builder: inout DocBuilder, into imported: inout Imported) async {
        let sources = builder.layout.blocks.compactMap { $0.kind == .image ? $0.image : nil }
        guard Keep.images, !sources.isEmpty, let dir = imported.staging ?? newStaging() else {
            builder.mapImages { _ in nil }
            return
        }
        imported.staging = dir
        var saved: [String: String] = [:]
        var n = 0
        for source in sources.prefix(imageLimit) where saved[source] == nil {
            guard let (data, ending) = await imageData(source), data.count <= imageBytes, data.count > 200 else { continue }
            n += 1
            let name = "img-\(n).\(ending)"
            if (try? data.write(to: dir.appendingPathComponent(name))) != nil { saved[source] = name }
        }
        builder.mapImages { saved[$0] }
    }

    /// One picture's bytes and file ending, from a web address or from the page itself ("data:image/…").
    private static func imageData(_ source: String) async -> (Data, String)? {
        if source.hasPrefix("data:image/") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
            else { return nil }
            let kind = source.dropFirst("data:image/".count).prefix { $0.isLetter }
            return (data, kind == "jpeg" ? "jpg" : String(kind.prefix(4)))
        }
        guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh) Chirp reader", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let type = http.mimeType?.lowercased(), type.hasPrefix("image/")
        else { return nil }
        let endings = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg", "image/avif": "avif", "image/heic": "heic"]
        guard let ending = endings[type] else { return nil }
        return (data, ending)
    }

    /// Saves what goes with a document once the document itself is in the library: its layout, where it
    /// came from, and its files, moved out of the temporary folder into the library's own.
    static func keep(_ imported: Imported, as item: SavedItem, in library: Library) {
        guard let id = item.id else { return }
        var extra = DocumentExtra(itemID: id, layout: imported.layout?.json ?? "", site: imported.site, format: imported.format, pages: imported.pages)
        if let staging = imported.staging, FileManager.default.fileExists(atPath: staging.path) {
            let name = UUID().uuidString
            let root = ChirpStore.documentsDirectory
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(name, isDirectory: true))) != nil {
                extra.files = name
                extra.original = imported.original
            }
        }
        guard !extra.layout.isEmpty || extra.files != nil || !extra.site.isEmpty || !extra.format.isEmpty || extra.pages > 0 else { return }
        try? library.save(extra)
    }

    /// A PDF's author and chapters, where the file carries them: the author from its properties, the
    /// chapters from its outline (the bookmarks in the sidebar). Most PDFs carry neither.
    private static func pdfAbout(_ pdf: PDFDocument) -> String {
        let author = BookContents.joined(
            ((pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? "")
                .components(separatedBy: CharacterSet(charactersIn: ";&")).map(BookContents.person).filter { !$0.isEmpty })
        var entries: [BookContents.Entry] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            for i in 0..<outline.numberOfChildren {
                guard entries.count < 2000, let child = outline.child(at: i) else { return }
                if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { entries.append(BookContents.Entry(label, depth: depth)) }
                if depth < 2 { walk(child, depth: depth + 1) }
            }
        }
        if let root = pdf.outlineRoot { walk(root, depth: 0) }
        return BookContents.facts(author: author, entries: entries).line
    }

    /// The text of a file, whatever encoding it was saved in.
    static func readText(_ url: URL) throws -> String {
        decodeText(try Data(contentsOf: url))
    }

    /// Turns bytes into text: as UTF-8 when they are valid UTF-8 (nearly everything is), else in the
    /// encoding the source named, else in whatever the bytes look like, else as Latin-1, which can read
    /// any bytes. So an older file or page opens with a few odd letters at worst, and is not refused.
    static func decodeText(_ data: Data, named: String.Encoding? = nil) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let named, let text = String(data: data, encoding: named) { return text }
        var converted: NSString?
        let guessed = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if guessed != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// An EPUB is a zip of XHTML chapters; unpack it and read the chapters in spine order.
    private static func epub(_ url: URL, fallbackTitle: String, into imported: inout Imported) throws -> (String, DocBuilder) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", dir.path]
        unzip.standardOutput = nil
        unzip.standardError = nil
        try unzip.run()
        unzip.waitUntilExit()
        // Only files inside the unpacked book are read: a book must not be able to name, with "../", a
        // file somewhere else on the Mac and have it pulled into the text.
        let root = dir.standardizedFileURL.path + "/"
        func inside(_ file: URL) -> Bool { file.standardizedFileURL.path.hasPrefix(root) }
        guard let container = try? readText(dir.appendingPathComponent("META-INF/container.xml")),
            let packagePath = HTMLText.epubPackagePath(container: container),
            inside(dir.appendingPathComponent(packagePath)),
            let package = try? readText(dir.appendingPathComponent(packagePath))
        else { throw ImportError.empty }
        let spine = HTMLText.epubSpine(package: package)
        let base = dir.appendingPathComponent(packagePath).deletingLastPathComponent()
        var book = DocBuilder()
        for href in spine.chapters {
            let file = base.appendingPathComponent(href.components(separatedBy: "#")[0])
            guard inside(file), let html = try? readText(file) else { continue }
            // Addresses in a chapter are made whole against the chapter's own file.
            let chapter = HTMLDocument.blocks(from: HTMLText.firstMatch(#"<body[^>]*>(.*)</body>"#, in: html) ?? html, base: file)
            if !chapter.isEmpty { book.append(chapter) }
        }
        // Who wrote it and how it is divided, from the book's own table of contents: the navigation page
        // of a newer book, or the older toc.ncx. Only files inside the unpacked book are read.
        var contents: [BookContents.Entry] = []
        if let found = BookContents.epubContentsPath(package: package) {
            let file = base.appendingPathComponent(found.path.components(separatedBy: "#")[0])
            if inside(file), let text = try? readText(file) { contents = found.isNCX ? BookContents.entries(ncx: text) : BookContents.entries(nav: text) }
        }
        imported.about = BookContents.facts(author: BookContents.epubAuthor(package: package), entries: contents).line
        // The book's pictures are copied out before the unpacked book is removed.
        stageLocalImages(&book, into: &imported, allowed: inside)
        return (spine.title.isEmpty ? fallbackTitle : spine.title, book)
    }
}
