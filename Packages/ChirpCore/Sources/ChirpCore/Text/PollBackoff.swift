import Foundation

/// How often to look at the focused text field while nothing is changing.
///
/// Looking means a dozen requests to another app, so a Mac that is sitting idle should not keep asking
/// seven times a second. Each look that finds nothing new makes the next gap longer; anything the user
/// does (a key, a click, a scroll, another app coming to the front) puts it back to the shortest.
/// The first few quiet looks stay at full speed so a short pause in typing costs nothing, then the gap
/// grows to ten times the shortest.
public struct PollBackoff: Sendable, Equatable {
    /// Looks in a row that found nothing new.
    public private(set) var quietLooks = 0
    /// A long idle spell must not count for ever; the gap is at its longest well before this.
    static let cap = 60

    public init() {}

    /// How many times the shortest gap to wait before the next look.
    public var stride: Int { Self.stride(quietLooks: quietLooks) }

    public static func stride(quietLooks: Int) -> Int {
        switch quietLooks {
        case ..<5: return 1
        case ..<12: return 3
        case ..<30: return 6
        default: return 10
        }
    }

    /// Notes one finished look: something new goes back to full speed, nothing new stretches the gap.
    public mutating func record(changed: Bool) {
        quietLooks = changed ? 0 : min(quietLooks + 1, Self.cap)
    }

    /// The user did something: back to full speed.
    public mutating func reset() { quietLooks = 0 }
}
