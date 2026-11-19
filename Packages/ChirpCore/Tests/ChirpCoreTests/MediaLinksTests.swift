import Foundation
import Testing

@testable import ChirpCore

@Suite struct MediaLinksTests {
    @Test func onlyPlainWebLinksAreTaken() {
        #expect(MediaLink.url(from: " https://www.youtube.com/watch?v=abc \n")?.host == "www.youtube.com")
        #expect(MediaLink.url(from: "http://example.com/a.mp3") != nil)
        for bad in ["--exec=touch /tmp/x", "-a", "file:///etc/passwd", "", "ftp://example.com/a", "https://", "example.com", "https://a.com two"] {
            #expect(MediaLink.url(from: bad) == nil, "\(bad) should be turned away")
        }
    }

    @Test func theKindComesFromWhatTheServerSays() {
        let page = URL(string: "https://example.com/watch?v=1")!
        let file = URL(string: "https://cdn.example.com/show/ep1.mp3?x=1")!
        #expect(MediaLink.kind(of: file, contentType: "audio/mpeg", firstBytes: Data()) == .file)
        #expect(MediaLink.kind(of: page, contentType: "video/mp4", firstBytes: Data()) == .file)
        #expect(MediaLink.kind(of: page, contentType: "text/html; charset=utf-8", firstBytes: Data("<!DOCTYPE html><html>".utf8)) == .page)
        #expect(MediaLink.kind(of: page, contentType: "application/rss+xml", firstBytes: Data()) == .feed)
        #expect(MediaLink.kind(of: page, contentType: "text/xml", firstBytes: Data("<?xml version=\"1.0\"?><rss version=\"2.0\">".utf8)) == .feed)
        // No useful type: the ending decides.
        #expect(MediaLink.kind(of: file, contentType: "application/octet-stream", firstBytes: Data([0xFF, 0xFB])) == .file)
        #expect(MediaLink.kind(of: page, contentType: nil, firstBytes: Data()) == .page)
        #expect(MediaLink.fileTitle(file) == "ep1")
    }

    @Test func aFeedGivesItsEpisodesWithSound() throws {
        let feed = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
              <channel>
                <title>The Test Show</title>
                <image><title>Artwork</title><url>https://example.com/a.png</url></image>
                <item><title><![CDATA[Episode 2: Budgets & plans]]></title>
                  <enclosure url="https://cdn.example.com/ep2.mp3" length="123" type="audio/mpeg"/></item>
                <item><title>A post with no sound</title><link>https://example.com/post</link></item>
                <item><title>Episode 1</title><enclosure url="https://cdn.example.com/ep1.m4a" type="audio/x-m4a"/></item>
                <item><title>Artwork only</title><enclosure url="https://cdn.example.com/art.png" type="image/png"/></item>
              </channel>
            </rss>
            """
        let read = try #require(PodcastFeed.parse(Data(feed.utf8)))
        #expect(read.podcast == "The Test Show")
        #expect(read.episodes.map(\.title) == ["Episode 2: Budgets & plans", "Episode 1"])
        #expect(read.episodes.first?.audio.absoluteString == "https://cdn.example.com/ep2.mp3")
        #expect(PodcastFeed.parse(Data("<html><body>Hello</body></html>".utf8)) == nil)
    }

    @Test func theToolIsOnlyInstalledWhenItsChecksumIsListed() {
        let hash = String(repeating: "ab", count: 32)
        let sums = "\(String(repeating: "cd", count: 32))  yt-dlp\n\(hash)  yt-dlp_macos\n\(String(repeating: "ef", count: 32))  yt-dlp_macos.zip\n"
        #expect(LinkTool.checksum(in: sums, for: "yt-dlp_macos") == hash)
        #expect(LinkTool.checksum(in: sums.uppercased().replacingOccurrences(of: "YT-DLP", with: "yt-dlp").replacingOccurrences(of: "_MACOS", with: "_macos").replacingOccurrences(of: ".ZIP", with: ".zip"), for: "yt-dlp_macos") == hash)
        #expect(LinkTool.checksum(in: sums, for: "yt-dlp_linux") == nil)
        #expect(LinkTool.checksum(in: "short  yt-dlp_macos\n", for: "yt-dlp_macos") == nil)
        #expect(LinkTool.checksum(in: sums + "\(String(repeating: "00", count: 32))  yt-dlp_macos\n", for: "yt-dlp_macos") == nil)
        #expect(LinkTool.isReleaseTag("2025.01.15"))
        #expect(LinkTool.isReleaseTag("2025.01.15.232015"))
        for bad in ["latest", "2025.1.15", "../2025.01.15", "2025.01.15/x", ""] { #expect(!LinkTool.isReleaseTag(bad)) }
    }

    @Test func theLinkIsNeverAnOption() {
        let args = LinkTool.arguments(link: URL(string: "https://example.com/watch?v=1")!, folder: URL(fileURLWithPath: "/tmp/x"), name: "abc")
        #expect(args.suffix(2) == ["--", "https://example.com/watch?v=1"])
        #expect(args.contains("--no-playlist") && args.contains("--no-update") && args.contains("--ignore-config"))
        #expect(args.contains("/tmp/x/abc.%(ext)s"))
    }

    @Test func theToolsOutputIsRead() {
        #expect(LinkTool.read(line: "CHIRP-PROGRESS  42.5%\r") == .progress(0.425))
        #expect(LinkTool.read(line: "CHIRP-PROGRESS 100%") == .progress(1))
        #expect(LinkTool.read(line: "CHIRP-TITLE How to prune roses") == .title("How to prune roses"))
        #expect(LinkTool.read(line: "CHIRP-TITLE NA") == nil)
        #expect(LinkTool.read(line: "[download] Destination: x.m4a") == nil)
        #expect(LinkTool.failure(from: "ERROR: [youtube] abc: Private video. Sign in if you've been granted access") == .notPublic)
        #expect(LinkTool.failure(from: "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate") == .notPublic)
        #expect(LinkTool.failure(from: "ERROR: Unsupported URL: https://example.com/") == .unsupported)
        #expect(LinkTool.failure(from: "ERROR: [youtube] abc: Video unavailable") == .unavailable)
        #expect(LinkTool.failure(from: "ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>") == .noNetwork)
        #expect(LinkTool.failure(from: "ERROR: something else") == .other)
    }
}
