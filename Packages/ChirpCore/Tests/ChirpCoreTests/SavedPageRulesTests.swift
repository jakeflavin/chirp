import Foundation
import Testing

@testable import ChirpCore

@Suite struct SavedPageRulesTests {
    private func rules(_ json: String) throws -> [[String: [String: String]]] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]])
    }

    @Test func everyWebAddressIsBlockedFirst() throws {
        let list = try rules(SavedPageRules.json(allowing: []))
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0["action"]?["type"] == "block" })
        #expect(list.map { $0["trigger"]?["url-filter"] } == ["^https?://", "^wss?://"])
    }

    @Test func savedAddressesAreLetThroughAsThemselves() throws {
        let list = try rules(SavedPageRules.json(allowing: [
            "https://example.com/a.png?w=2&h=3", "https://example.com/a.png?w=2&h=3", "file:///tmp/x", "https://example.com/é.png",
        ]))
        // Once each, after the blocks; local and non-ASCII addresses are left out.
        #expect(list.count == 3)
        #expect(list[2]["action"]?["type"] == "ignore-previous-rules")
        #expect(list[2]["trigger"]?["url-filter"] == #"^https://example\.com/a\.png\?w=2&h=3"#)
    }

    @Test func patternCharactersAreEscaped() {
        #expect(SavedPageRules.escaped("a.b*c+d?e(f)g[h]i{j}k|l^m$n\\o") == #"a\.b\*c\+d\?e\(f\)g\[h\]i\{j\}k\|l\^m\$n\\o"#)
    }

    @Test func addressesComeFromThePageItsPiecesAndItsFrames() throws {
        let archive: [String: Any] = [
            "WebMainResource": ["WebResourceURL": "https://example.com/page"],
            "WebSubresources": [["WebResourceURL": "https://example.com/a.png"], ["WebResourceURL": "https://cdn.example.com/b.css"]],
            "WebSubframeArchives": [[
                "WebMainResource": ["WebResourceURL": "https://frame.example.com/"],
                "WebSubresources": [["WebResourceURL": "https://frame.example.com/c.png"]],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        #expect(SavedPageRules.addresses(inArchive: data) == [
            "https://example.com/page", "https://example.com/a.png", "https://cdn.example.com/b.css",
            "https://frame.example.com/", "https://frame.example.com/c.png",
        ])
        #expect(SavedPageRules.addresses(inArchive: Data("<html></html>".utf8)).isEmpty)
    }
}
