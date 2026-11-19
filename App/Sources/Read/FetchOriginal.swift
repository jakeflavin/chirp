import ChirpCore
import Foundation

/// "Fetch the original again", for a web page saved before originals were kept. The page at its known address is saved now as the browser's web archive (or as the
/// page as sent, when that cannot be made) and kept as its original. The reading view, the place and the
/// summary are left as they are. This is a fetch the user asked for, of an address they gave before.
@MainActor
enum OriginalFetch {
    /// The web address a document was saved from, when it has one.
    static func address(of item: SavedItem) -> URL? {
        guard let source = item.source, let url = URL(string: source), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// True when the document is a web page with no original on this Mac, and the page's address is known.
    static func canFetch(_ item: SavedItem, extra: DocumentExtra?) -> Bool {
        guard address(of: item) != nil, extra?.isTranscript != true else { return false }
        return !hasOriginal(extra)
    }

    /// True when an original was kept and is still on this Mac.
    static func hasOriginal(_ extra: DocumentExtra?) -> Bool {
        guard let url = extra?.originalURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Fetches the page and keeps the copy as the document's original. Returns why it failed, or nil.
    static func fetch(_ item: SavedItem, library: Library) async -> String? {
        guard let id = item.id, let url = address(of: item) else { return "There is no address for this page." }
        var extra = (try? library.documentExtra(itemID: id)) ?? DocumentExtra(itemID: id, format: "Web page")
        let name = extra.files ?? UUID().uuidString
        let made = extra.files == nil
        let dir = ChirpStore.documentsDirectory.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return "Chirp could not make a folder for it." }
        if let archive = await PageSaver.archive(of: url), (try? archive.write(to: dir.appendingPathComponent("page.webarchive"))) != nil {
            extra.original = "page.webarchive"
        } else {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Mozilla/5.0 (Macintosh) Chirp reader", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                (try? data.write(to: dir.appendingPathComponent("page.html"))) != nil
            else {
                if made { try? FileManager.default.removeItem(at: dir) }
                return "The page could not be reached."
            }
            extra.original = "page.html"
        }
        extra.files = name
        do { try library.save(extra) } catch { return "Chirp could not keep the copy." }
        Log.write("read", "the original of a kept page was fetched again: \(extra.original ?? "")")
        return nil
    }
}
