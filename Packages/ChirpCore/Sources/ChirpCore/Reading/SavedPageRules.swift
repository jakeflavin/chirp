import Foundation

/// The content rules a saved copy of a web page is shown with: nothing may be fetched from the network,
/// except what the copy itself holds. A web view checks its rules before it looks in the copy, so every
/// address saved in the copy is let through by name and everything else on the web is blocked.
public enum SavedPageRules {
    /// More addresses than this are not let through by name; what is past it is simply not shown. Keeps
    /// the rules quick to compile for a page that saved thousands of pieces.
    static let addressLimit = 3000

    /// Every address saved in a web archive: the page, its pieces, and those of any frames inside it.
    /// Empty when the data is not a web archive.
    public static func addresses(inArchive data: Data) -> [String] {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var out: [String] = []
        collect(archive, into: &out)
        return out
    }

    private static func collect(_ archive: [String: Any], into out: inout [String]) {
        if let main = archive["WebMainResource"] as? [String: Any], let url = main["WebResourceURL"] as? String { out.append(url) }
        for piece in archive["WebSubresources"] as? [[String: Any]] ?? [] {
            if let url = piece["WebResourceURL"] as? String { out.append(url) }
        }
        for frame in archive["WebSubframeArchives"] as? [[String: Any]] ?? [] { collect(frame, into: &out) }
    }

    /// The rules as the web view's JSON: block every web address, then let through each of `allowed`.
    /// An address the rules cannot hold (not plain ASCII, or not on the web) is left out, so it stays blocked.
    public static func json(allowing allowed: [String]) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://"], "action": ["type": "block"]],
        ]
        var seen = Set<String>()
        for address in allowed where seen.count < addressLimit {
            guard address.hasPrefix("http://") || address.hasPrefix("https://"), address.allSatisfy(\.isASCII),
                seen.insert(address).inserted
            else { continue }
            rules.append(["trigger": ["url-filter": "^" + escaped(address)], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `text` as a pattern that matches only itself: each character with a meaning in a pattern gets a
    /// backslash in front.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.*+?()[]{}|".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
