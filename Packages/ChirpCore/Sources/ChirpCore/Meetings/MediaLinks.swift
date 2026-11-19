import Foundation

/// A link to something with sound in it that Chirp can fetch and transcribe: a video page, a podcast
/// episode, an audio or video file, a podcast feed. Everything here is plain text work; the fetching is
/// in the app (`LinkImporter`).
public enum MediaLink {
    /// The link as typed, when it is a plain web address. Only http and https links ever reach the
    /// download tool: anything else (`--exec=…`, `-a file`, `file://…`) could be read as an option or a
    /// local file.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// File endings Chirp can read the sound of without any other tool.
    public static let soundEndings: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4", "m4v", "mov"]

    /// What a link turned out to be, from what the server says about it.
    public enum Kind: Equatable, Sendable {
        /// A sound or video file: fetched as it is.
        case file
        /// A podcast feed: its episodes are offered.
        case feed
        /// A page (a video site, an episode's page): the download tool is needed.
        case page
    }

    /// Works out the kind from the address, the type the server names and the first bytes it sends.
    public static func kind(of url: URL, contentType: String?, firstBytes: Data) -> Kind {
        let type = (contentType ?? "").lowercased()
        if type.hasPrefix("audio/") || type.hasPrefix("video/") { return .file }
        let start = String(decoding: firstBytes.prefix(600), as: UTF8.self).lowercased()
        if type.contains("rss") || type.contains("atom") || start.contains("<rss") || start.contains("<feed") { return .feed }
        if type.contains("xml"), !start.contains("<html") { return .feed }
        if type.contains("html") || start.contains("<html") || start.contains("<!doctype html") { return .page }
        // A server that names no useful type (`application/octet-stream`): the ending decides.
        return soundEndings.contains(url.pathExtension.lowercased()) ? .file : .page
    }

    /// The name to save a fetched file under before its real title is known: the last part of the address.
    public static func fileTitle(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        return name.isEmpty || name == "/" ? (url.host ?? "Link") : name
    }
}

/// One episode of a podcast feed.
public struct PodcastEpisode: Sendable, Equatable, Identifiable {
    public var title: String
    /// The episode's sound file.
    public var audio: URL
    public var id: String { audio.absoluteString }
}

/// A podcast's RSS feed, read for its name and its episodes' sound files.
public enum PodcastFeed {
    /// The episodes that have a sound file, in the feed's own order (newest first, by custom), with the
    /// podcast's name. Nil when the text is not a feed.
    public static func parse(_ data: Data) -> (podcast: String, episodes: [PodcastEpisode])? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || !reader.episodes.isEmpty, reader.sawFeed else { return nil }
        return (reader.podcast.trimmingCharacters(in: .whitespacesAndNewlines), reader.episodes)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var podcast = ""
        var episodes: [PodcastEpisode] = []
        var sawFeed = false
        private var path: [String] = []
        private var text = ""
        private var title = ""
        private var audio: URL?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = name.lowercased()
            path.append(name)
            text = ""
            if name == "rss" || name == "feed" { sawFeed = true }
            if name == "item" || name == "entry" {
                title = ""
                audio = nil
            }
            // RSS: <enclosure url type>. Atom: <link rel="enclosure" href type>.
            let isEnclosure = name == "enclosure" || (name == "link" && attributes["rel"] == "enclosure")
            if isEnclosure, audio == nil, let link = attributes["url"] ?? attributes["href"], let url = MediaLink.url(from: link) {
                let type = (attributes["type"] ?? "").lowercased()
                if type.isEmpty || type.hasPrefix("audio/") || type.hasPrefix("video/") { audio = url }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let name = name.lowercased()
            let inEpisode = path.contains("item") || path.contains("entry")
            if name == "title" {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // The feed's own title sits straight under <channel> or <feed>, not in <image> or an episode.
                if inEpisode { if title.isEmpty { title = value } } else if podcast.isEmpty, path.dropLast().last == "channel" || path.dropLast().last == "feed" { podcast = value }
            }
            if name == "item" || name == "entry", let audio {
                episodes.append(PodcastEpisode(title: title.isEmpty ? MediaLink.fileTitle(audio) : title, audio: audio))
            }
            if !path.isEmpty { path.removeLast() }
            text = ""
        }
    }
}

/// The download tool Chirp fetches for links that are pages: yt-dlp, from its own releases on GitHub.
/// Before it is installed, the release tag must have the shape of a date,
/// and the file is only installed when it matches the release's own list of checksums.
public enum LinkTool {
    /// The file in each release that runs on a Mac.
    public static let asset = "yt-dlp_macos"

    /// Release tags are dates, `2025.01.15`, sometimes with one more number.
    public static func isReleaseTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false)
        func digits(_ part: Substring, _ range: ClosedRange<Int>) -> Bool { range.contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } }
        guard parts.count == 3 || parts.count == 4 else { return false }
        return digits(parts[0], 4...4) && digits(parts[1], 2...2) && digits(parts[2], 2...2) && (parts.count == 3 || digits(parts[3], 1...10))
    }

    /// The checksum a release's `SHA2-256SUMS` gives for one of its files (`<hex>  <name>` on each line).
    /// Nil when it is missing, malformed, or listed twice with different values: the file is then not installed.
    public static func checksum(in sums: String, for asset: String) -> String? {
        var found: String?
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            var name = fields[1]
            if name.hasPrefix("*") { name = name.dropFirst() }
            guard name == asset else { continue }
            let hash = fields[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            if let found, found != hash { return nil }
            found = hash
        }
        return found
    }

    /// What the tool is run with, for one link: no playlist, no self-update, no settings file of the
    /// user's, and the link after `--` so it can never be read as an option. Chirp has no ffmpeg to
    /// convert with, so it asks for a sound-only file it can read as it is (m4a, then mp3), and failing that
    /// the smallest file with video, which is deleted once the sound has been read.
    public static func arguments(link: URL, folder: URL, name: String) -> [String] {
        [
            "--no-playlist", "--no-update", "--ignore-config", "--no-warnings",
            "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp3]/worst[ext=mp4]/best[ext=mp4]",
            "--newline", "--progress", "--progress-template", "download:\(progressMark)%(progress._percent_str)s",
            "--no-simulate", "--print", "before_dl:\(titleMark)%(title)s",
            "-o", folder.appendingPathComponent("\(name).%(ext)s").path,
            "--", link.absoluteString,
        ]
    }

    static let progressMark = "CHIRP-PROGRESS "
    static let titleMark = "CHIRP-TITLE "

    /// What one line of the tool's output says.
    public enum Output: Equatable, Sendable {
        /// How far the download is, 0 to 1.
        case progress(Double)
        case title(String)
    }

    public static func read(line: String) -> Output? {
        let line = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(titleMark) {
            let title = String(line.dropFirst(titleMark.count)).trimmingCharacters(in: .whitespaces)
            return title.isEmpty || title == "NA" ? nil : .title(title)
        }
        if line.hasPrefix(progressMark) {
            let number = line.dropFirst(progressMark.count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            return Double(number).map { .progress(min(max($0 / 100, 0), 1)) }
        }
        return nil
    }

    /// Why a link could not be fetched, in the user's terms.
    public enum Failure: Equatable, Sendable {
        case noNetwork
        /// Private, for members, or needing a sign-in or an age check.
        case notPublic
        /// A site or a kind of page the tool does not know.
        case unsupported
        /// Gone, or blocked where this Mac is.
        case unavailable
        case other
    }

    /// Reads the tool's own error text. The phrases are yt-dlp's.
    public static func failure(from errors: String) -> Failure {
        let text = errors.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains(where: text.contains) }
        if has("private video", "sign in", "log in", "login required", "age-restricted", "confirm your age", "members-only", "members only", "requires payment", "premium", "cookies") {
            return .notPublic
        }
        if has("unsupported url", "no video formats", "requested format is not available", "no suitable") { return .unsupported }
        if has("video unavailable", "not available in your country", "has been removed", "does not exist", "http error 404", "http error 410") { return .unavailable }
        if has("unable to download webpage", "getaddrinfo", "name or service not known", "nodename nor servname", "network is unreachable", "timed out", "connection refused", "temporary failure in name resolution") {
            return .noNetwork
        }
        return .other
    }
}
