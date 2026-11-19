import Foundation

/// Where to cut a long recording so it can be transcribed in pieces while the user is still talking.
///
/// Cuts fall in the middle of pauses, the longest pause nearest the target length wins, and a piece is
/// never shorter than five seconds or longer than the target plus ten. The target length is adjustable.
public struct LongForm: Sendable, Equatable {
    /// Samples per second of the audio being cut.
    public static let rate = 16_000
    /// The length a piece aims for, in seconds (30 is the usual).
    public var targetSeconds: Double

    public init(targetSeconds: Double = 25) {
        self.targetSeconds = min(max(targetSeconds, 10), 60)
    }

    /// The longest a piece may be: the target plus ten seconds.
    public var maxSamples: Int { Int((targetSeconds + 10) * Double(Self.rate)) }
    /// The shortest a piece may be: five seconds.
    public var minSamples: Int { 5 * Self.rate }
    /// Audio that must exist past the longest piece before anything is cut, so the cut is not a guess.
    public var lookaheadSamples: Int { minSamples }

    /// A place the audio could be cut: the middle of a pause.
    public struct Cut: Sendable, Equatable {
        /// The sample to cut at.
        public var at: Int
        /// How long the pause around it is.
        public var gapSeconds: Double
    }

    /// The middle of every pause between stretches of speech.
    public static func candidates(speech: [Range<Int>], samples: Int) -> [Cut] {
        var out: [Cut] = []
        var silenceStart = 0
        for segment in speech + [samples..<samples] {
            if segment.lowerBound > silenceStart {
                out.append(Cut(at: (silenceStart + segment.lowerBound) / 2, gapSeconds: Double(segment.lowerBound - silenceStart) / Double(rate)))
            }
            silenceStart = max(silenceStart, segment.upperBound)
        }
        return out
    }

    /// Cut points for audio of `samples` length starting at `from`, leaving a last piece no longer than the maximum.
    public func cuts(_ candidates: [Cut], samples: Int, from: Int = 0) -> [Int] {
        var cuts: [Int] = []
        var start = from
        var first = 0
        while samples - start > maxSamples {
            while first < candidates.count, candidates[first].at < start + minSamples { first += 1 }
            var best: (at: Int, score: Double)?
            var fallback: (at: Int, score: Double)?
            for candidate in candidates[first...] {
                guard candidate.at <= start + maxSamples else { break }
                let position = Double(candidate.at - start) / Double(Self.rate)
                let offTarget = position > targetSeconds ? 0.1 * (position - targetSeconds) : 0.05 * (targetSeconds - position)
                let score = min(candidate.gapSeconds, 1.0) - offTarget
                if samples - candidate.at >= minSamples, best.map({ score > $0.score }) ?? true { best = (candidate.at, score) }
                if fallback.map({ score > $0.score }) ?? true { fallback = (candidate.at, score) }
            }
            let hardCut = samples - start < maxSamples + minSamples ? start + (samples - start) / 2 : start + maxSamples
            start = (best ?? fallback)?.at ?? hardCut
            cuts.append(start)
        }
        return cuts
    }

    /// The pieces' text in order, with a space between.
    public static func join(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
