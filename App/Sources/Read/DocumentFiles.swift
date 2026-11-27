import AppKit
import ChirpCore
import Foundation
import WebKit

/// Reads a Word or rich-text document, as macOS opens it, into a document that keeps its structure:
/// headings (told from the size of their type), bold, italic, links, lists, tables and pictures.
enum AttributedDocument {
    static func blocks(from attributed: NSAttributedString, into imported: inout DocumentImporter.Imported) -> DocBuilder {
        var out = DocBuilder()
        let ns = attributed.string as NSString
        guard ns.length > 0 else { return out }
        // The size most of the words are set in is the body's; larger lines are headings.
        var sizes: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            sizes[(value as? NSFont)?.pointSize ?? 12, default: 0] += range.length
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        // A table row being gathered: its table, its row number and its cells so far.
        var row: (table: NSTextTable, index: Int, cells: [[DocBuilder.Run]])?
        var rowsDone = 0
        func endRow() {
            guard let open = row else { return }
            row = nil
            // The first row of a table is its heading row when every word in it is bold.
            let allBold = open.cells.allSatisfy { $0.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
            out.addRow(open.cells.map { $0.map { var r = $0; r.bold = false; return r } }, head: rowsDone == 0 && allBold)
            rowsDone += 1
        }
        var images = 0
        var at = 0
        while at < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(para)
            var runs: [DocBuilder.Run] = []
            var largest: CGFloat = 0
            var pictures: [Data] = []
            attributed.enumerateAttributes(in: para) { attributes, range, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents, NSImage(data: data) != nil { pictures.append(data) }
                    return
                }
                let font = attributes[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let words = ns.substring(with: range).replacingOccurrences(of: "\u{2028}", with: " ")
                if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { largest = max(largest, font?.pointSize ?? body) }
                var link: String?
                if let url = attributes[.link] as? URL { link = url.absoluteString } else if let s = attributes[.link] as? String { link = s }
                if let l = link, !(l.hasPrefix("http") || l.hasPrefix("mailto:")) { link = nil }
                runs.append(DocBuilder.Run(words, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask), link: link))
            }
            let style = attributed.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            let words = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            // A cell of a table: paragraphs of one row are gathered and written as a row.
            if let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if let open = row, open.table !== block.table || open.index != block.startingRow { endRow() }
                if row == nil {
                    if rowsDone > 0, out.layout.blocks.last.map({ $0.kind != .tableRow && $0.kind != .tableHead }) ?? true { rowsDone = 0 }
                    row = (block.table, block.startingRow, [])
                }
                // Two paragraphs in one cell are one cell's words.
                if let open = row, block.startingColumn < open.cells.count {
                    row?.cells[block.startingColumn] += [DocBuilder.Run(" ")] + runs
                } else {
                    while let open = row, open.cells.count < block.startingColumn { row?.cells.append([]) }
                    row?.cells.append(runs)
                }
                continue
            }
            endRow()
            rowsDone = 0
            for data in pictures where DocumentImporter.Keep.images && images < DocumentImporter.imageLimit && data.count <= DocumentImporter.imageBytes {
                guard let dir = imported.staging ?? DocumentImporter.newStaging() else { break }
                imported.staging = dir
                images += 1
                let name = "img-\(images).png"
                // Kept as PNG whatever it was, so it opens anywhere.
                guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: dir.appendingPathComponent(name))) != nil
                else { continue }
                out.addImage(name)
            }
            guard !words.isEmpty else { continue }
            let plain = { runs.map { var r = $0; r.bold = false; return r } }
            let allBold = runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let list = style?.textLists.last {
                // The list's mark is written into the words ("\t•\t", "\t1.\t"): it is taken off and drawn again.
                let numbered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                let (mark, rest) = stripMark(runs)
                out.add(numbered ? .numbered : .bullet, rest, marker: numbered ? (mark ?? "1.") : nil)
            } else if largest >= body * 1.4 {
                out.add(.heading, plain())
            } else if largest >= body * 1.12 || (allBold && words.count <= 80 && !(words.last.map { ".!?,;:".contains($0) } ?? false)) {
                out.add(.subheading, plain())
            } else {
                out.add(.paragraph, runs)
            }
        }
        endRow()
        return out
    }

    /// Takes a list mark off the front of a paragraph's runs ("•", "1.", "a)").
    private static func stripMark(_ runs: [DocBuilder.Run]) -> (String?, [DocBuilder.Run]) {
        var runs = runs
        var lead = ""
        // The mark sits in the first run or two, between tabs.
        while let first = runs.first, lead.split(separator: "\t", omittingEmptySubsequences: true).isEmpty || !lead.hasSuffix("\t") {
            guard let tab = first.text.lastIndex(of: "\t"), first.text[...tab].count <= 12 else { break }
            lead += first.text[...tab]
            runs[0].text = String(first.text[first.text.index(after: tab)...])
            if runs[0].text.isEmpty { runs.removeFirst() } else { break }
        }
        let mark = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mark.isEmpty else { return (nil, runs) }
        return (mark.first?.isNumber == true || mark.first?.isLetter == true ? mark : nil, runs)
    }
}

/// Makes a saved copy of a web page: its text, layout and pictures in one file, as the browser's own
/// "web archive". The page is loaded once, off screen, with its scripts off, to make it.
@MainActor
final class PageSaver: NSObject, WKNavigationDelegate {
    private var done: ((Data?) -> Void)?
    private var view: WKWebView?

    /// The page at `url` as a web archive, or nil if it could not be loaded in time.
    static func archive(of url: URL, timeout: Double = 25) async -> Data? {
        // A test run names no real site, and must not wait on one.
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let saver = PageSaver()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            var resumed = false
            saver.done = { data in
                guard !resumed else { return }
                resumed = true
                saver.view?.navigationDelegate = nil
                saver.view = nil
                continuation.resume(returning: data)
            }
            let configuration = WKWebViewConfiguration()
            // Nothing the page stores is kept after the copy is made.
            configuration.websiteDataStore = .nonPersistent()
            // The page's own scripts do not run, so its analytics and trackers cannot run during the copy.
            // The copy is the page as the site sent it; one that draws itself with scripts saves less.
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 1400), configuration: configuration)
            view.navigationDelegate = saver
            saver.view = view
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("Mozilla/5.0 (Macintosh) Chirp reader", forHTTPHeaderField: "User-Agent")
            view.load(request)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                saver.done?(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for pictures that load after the page says it is done.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let view = self.view else { return }
            view.createWebArchiveData { result in
                Task { @MainActor in self.done?(try? result.get()) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done?(nil) }
}
