import CoreGraphics
import Foundation

/// How each kind of underline looks, everywhere Chirp draws one: over other apps, in its own editors and in
/// onboarding's example. Each kind has its own line as well as its own colour, so colour is never the
/// only signal:
/// - spelling: a wavy line (red);
/// - grammar: a solid line (blue);
/// - style: a dashed line (green);
/// - a typed snippet's cue: a dotted line;
/// - a likely name keeps the spelling line, thinner and fainter.
/// The widths: wavy 1.5, solid and dashed 2, dotted 2.5, a name 1 at 45%; the dash is 6 on, 4 off. The wave's
/// size follows the usual spell-check squiggle: 4 pt from crest to crest.
public enum UnderlinePattern: String, Sendable, CaseIterable {
    case wavy, solid, dashed, dotted
}

public struct UnderlineLook: Equatable, Sendable {
    public var pattern: UnderlinePattern
    /// The line's width in points.
    public var width: CGFloat
    /// How strong the colour is, 0 to 1.
    public var opacity: Double

    /// The look for a kind of problem. A likely name is the spelling line, thinner and fainter.
    public static func of(_ category: IssueCategory, likelyName: Bool = false, dark: Bool = false) -> UnderlineLook {
        switch category {
        case .spelling:
            likelyName ? UnderlineLook(pattern: .wavy, width: 1, opacity: dark ? 0.5 : 0.45) : UnderlineLook(pattern: .wavy, width: 1.5, opacity: 1)
        case .grammar: UnderlineLook(pattern: .solid, width: 2, opacity: 1)
        case .style: UnderlineLook(pattern: .dashed, width: 2, opacity: 1)
        case .snippet: UnderlineLook(pattern: .dotted, width: 2.5, opacity: 1)
        }
    }

    /// The dash for a dashed or dotted line (drawn with round ends): nil for a solid or wavy one.
    public var dash: [CGFloat]? {
        switch pattern {
        case .dashed: [6, 4]
        case .dotted: [0.1, 4.5]
        case .solid, .wavy: nil
        }
    }

    /// How far a wave rises above and falls below its middle.
    public var amplitude: CGFloat { pattern == .wavy ? (width < 1.5 ? 1 : 1.25) : 0 }
    /// From crest to crest.
    public static let wavelength: CGFloat = 4

    /// How much room under the words the line needs, from its middle to its lowest point.
    public var reach: CGFloat { amplitude + width / 2 }

    /// The line from `x0` to `x1` with its middle at `y` (any coordinates in which y grows either way: the
    /// wave is the same flipped). A wave starts and ends at its middle, so two side by side do not touch.
    public func path(from x0: CGFloat, to x1: CGFloat, y: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard x1 > x0 else { return path }
        path.move(to: CGPoint(x: x0, y: y))
        guard pattern == .wavy else {
            path.addLine(to: CGPoint(x: x1, y: y))
            return path
        }
        // Half a wave at a time: a curve up, then a curve down.
        let half = Self.wavelength / 2
        var x = x0
        var up = true
        while x < x1 {
            let next = min(x + half, x1)
            let crest = y + (up ? -amplitude : amplitude) * min(1, (next - x) / half)
            path.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: crest + (crest - y)))
            x = next
            up.toggle()
        }
        return path
    }
}
