import Foundation

/// The one small bird of "Fix the sentence" in other apps: which sentence gets it and where it sits.
///
/// Only the sentence the cursor is in, or has just finished, gets a bird, and only while it has a fix: the
/// same sentence ⌥⇥ fixes, so the bird says "this is ready" where the keys would act. A sentence in an
/// older paragraph has none: text written earlier is not what the user is working on. The bird never covers
/// text: it sits after the sentence's last character on the same line when there is room before the next word
/// or the edge; otherwise a smaller bird sits just above that last character when the space there is empty; otherwise there is none (⌥⇥ still works). It never
/// goes to the end of the line, where it would read as belonging to another sentence.
public enum SentenceBirdRule {
    /// The sentence that gets the bird: the one at `caret` (in it, or just after its end), when it has a
    /// fix. Nil with no caret (a selection, or the app does not say).
    public static func sentence(in text: String, caret: Int?, issues: [WritingIssue]) -> Proofreading.SentenceFix? {
        guard let caret, caret >= 0 else { return nil }
        return Proofreading.sentenceFix(in: text, caret: caret, issues: issues)
    }

    /// The bird's size on a line of this height: the design size, never taller than the line.
    public static func side(forLine height: CGFloat) -> CGFloat {
        min(max(height * 0.8, 10), 18, max(height, 1))
    }

    /// The smaller bird that sits above a character, on a line of this height.
    public static func smallSide(forLine height: CGFloat) -> CGFloat {
        min(max(height * 0.55, 8), 11)
    }

    /// Where the bird goes, in the app's top-left coordinates, or nil when there is no place that covers
    /// no text.
    /// - `end`: the box of the sentence's last character.
    /// - `next`: the box of the first character after the sentence that is not a space, if there is one.
    /// - `right`: the right edge of the field's visible area, when known.
    /// - `top`: the top edge of the field's visible area, when known.
    /// - `textAbove`: the boxes of the line above the sentence's last line (empty on the first line), or nil
    ///   when the app does not say where its lines are.
    public static func place(end: CGRect, next: CGRect?, right: CGFloat?, top: CGFloat? = nil, textAbove: [CGRect]? = nil) -> CGRect? {
        let side = side(forLine: end.height)
        func fits(_ r: CGRect) -> Bool { right.map { r.maxX <= $0 } ?? true }
        let here = CGRect(x: end.maxX + 3, y: end.minY + (end.height - side) / 2, width: side, height: side)
        let following = next.flatMap { sameLine($0, end) && $0.minX >= end.maxX - 1 ? $0 : nil }
        guard let following else {
            // The sentence ends its line or the text: the space after it is free up to the edge.
            return fits(here) ? here : above(end: end, right: right, top: top, textAbove: textAbove)
        }
        // Room before the next word on the line.
        if here.maxX + 2 <= following.minX { return here }
        // No room: a small bird just above the last character, if nothing is there.
        return above(end: end, right: right, top: top, textAbove: textAbove)
    }

    /// A small bird just above `end`, centred on it, in the empty space between it and the line above (or
    /// the field's top). Nil when that space is not known or too small: then there is no bird.
    static func above(end: CGRect, right: CGFloat?, top: CGFloat?, textAbove: [CGRect]?) -> CGRect? {
        guard let top, let textAbove else { return nil }
        let small = smallSide(forLine: end.height)
        var x = end.midX - small / 2
        if let right { x = min(x, right - small) }
        let span = x...(x + small)
        // What is above the character, over the bird's width: the lowest of it is the limit.
        let over = textAbove.filter { $0.maxY <= end.minY + 1 && $0.minX < span.upperBound && $0.maxX > span.lowerBound }
        let limit = max(top, over.map(\.maxY).max() ?? top)
        guard end.minY - limit >= small + 2 else { return nil }
        return CGRect(x: x, y: end.minY - 1 - small, width: small, height: small)
    }

    static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < min(a.height, b.height) / 2
    }
}
