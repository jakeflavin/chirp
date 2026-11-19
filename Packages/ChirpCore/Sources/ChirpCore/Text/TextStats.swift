import Foundation

/// Small text helpers that several parts of Chirp need, kept in one place so they behave the same way.
public enum TextStats {
    /// How many words `text` has: runs of characters between spaces, tabs or line breaks.
    public static func words(_ text: some StringProtocol) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// A name for a file saved from `title`: at most `limit` characters, with no "/" or ":" (which a Mac
    /// file name cannot hold), or `fallback` when nothing is left.
    public static func fileName(_ title: String, limit: Int = 80, fallback: String = "Untitled") -> String {
        let cleaned = title.prefix(limit).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

extension Double {
    /// Seconds as a clock: 75 is "1:15", and an hour or more is "1:02:05".
    public var clock: String {
        let s = Int(self.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Data {
    /// 32-bit floats as bytes, the way vectors and recorded sound are stored and sent to a helper.
    public init(floats: [Float]) {
        self = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The bytes read as 32-bit floats. Bytes left over at the end that do not make a whole number are ignored.
    public var floats: [Float] {
        let count = self.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, used in
            // Copied rather than read in place: the bytes may not start where a float is allowed to.
            _ = copyBytes(to: buffer)
            used = count
        }
    }
}
