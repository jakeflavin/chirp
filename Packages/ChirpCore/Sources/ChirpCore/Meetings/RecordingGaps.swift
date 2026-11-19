import Foundation

extension MeetingText {
    /// The stretches of one side of a recording that no transcript line covers and that are long enough
    /// to hold words, as sample ranges: what a run that ended early never got to. `lines` are that side's.
    public static func uncovered(samples: Int, lines: [TranscriptSegment], rate: Int = 16_000, shortest: Double = 1.0) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var at = 0
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let from = Int(line.start * Double(rate)), to = Int(line.end * Double(rate))
            if from - at >= Int(shortest * Double(rate)) { out.append(at..<min(from, samples)) }
            at = max(at, to)
        }
        if samples - at >= Int(shortest * Double(rate)) { out.append(at..<samples) }
        return out.filter { !$0.isEmpty }
    }
}
