import Foundation

/// Where to cut a dictation into a note so its words can be shown while the user is still talking.
///
/// A long dictation elsewhere is cut into pieces of about half a minute (`LongForm`), which keeps the
/// wait at the end short. A note shows the words as they come, so here a piece ends at the first pause
/// that is long enough once there is a little audio to go on. The latest such pause wins, so a burst
/// of short phrases becomes one piece rather than many. Past `maxSeconds` without a long pause it is cut
/// at the longest pause there is, or at `maxSeconds` when there is none.
public struct LiveCut: Sendable, Equatable {
    /// Samples per second of the audio being cut.
    public static let rate = LongForm.rate
    /// A piece is at least this long, so the model has enough to go on.
    public var minSeconds: Double
    /// A pause this long ends a phrase.
    public var pauseSeconds: Double
    /// No piece waits for a long pause past this length.
    public var maxSeconds: Double

    public init(minSeconds: Double = 1.5, pauseSeconds: Double = 0.35, maxSeconds: Double = 6) {
        self.minSeconds = max(0.5, minSeconds)
        self.pauseSeconds = max(0.1, pauseSeconds)
        self.maxSeconds = max(self.minSeconds + 1, maxSeconds)
    }

    /// What to do with the audio not yet transcribed.
    public enum Step: Sendable, Equatable {
        /// Nothing yet: the user is mid-phrase, or there is too little audio.
        case wait
        /// Transcribe the audio up to this sample and show its words.
        case transcribe(upTo: Int)
        /// Nothing was said up to this sample: it can be passed over.
        case skip(upTo: Int)
    }

    /// The next step for `samples` of audio not yet transcribed, given the stretches of speech found in it
    /// (sample ranges from its start).
    public func next(speech: [Range<Int>], samples: Int) -> Step {
        let least = Int(minSeconds * Double(Self.rate))
        let pause = Int(pauseSeconds * Double(Self.rate))
        let most = Int(maxSeconds * Double(Self.rate))
        let spoken = speech.filter { $0.lowerBound < $0.upperBound && $0.lowerBound < samples }.sorted { $0.lowerBound < $1.lowerBound }
        guard !spoken.isEmpty else {
            // Quiet so far. Half a second is kept back in case a word is just starting.
            return samples >= 2 * Self.rate ? .skip(upTo: samples - Self.rate / 2) : .wait
        }
        // Each pause after some speech, as (where to cut, how long it is). The pause after the last stretch
        // is still going on: it is cut half a pause in, so a word starting at its end is not clipped.
        var pauses: [(at: Int, gap: Int)] = []
        var end = spoken[0].upperBound
        for segment in spoken.dropFirst() {
            if segment.lowerBound > end { pauses.append(((end + segment.lowerBound) / 2, segment.lowerBound - end)) }
            end = max(end, segment.upperBound)
        }
        let trailing = samples - min(end, samples)
        if trailing > 0 { pauses.append((min(end, samples) + min(trailing, pause) / 2, trailing)) }
        if let phrase = pauses.last(where: { $0.gap >= pause && $0.at >= least }) { return .transcribe(upTo: phrase.at) }
        guard samples >= most else { return .wait }
        // Too long without a proper pause: the longest one within reach, or a hard cut.
        if let best = pauses.filter({ $0.at >= least && $0.at <= most }).max(by: { $0.gap < $1.gap }) { return .transcribe(upTo: best.at) }
        return .transcribe(upTo: most)
    }
}
