import Foundation

/// Cuts a live stream into pieces of speech from a voice detector's scores: a piece starts a little
/// before the first frame scored as speech, ends once the score has stayed low for a while, and is cut
/// by force at a longest length. The scores are given from outside (one for each `frame` samples), so this is
/// plain arithmetic.
public struct VoiceSegmenter: Sendable {
    /// Samples scored at a time by the detector in use (FluidAudio's Silero: about a quarter second).
    public static let frame = 4096
    public var sampleRate = 16_000
    /// A frame scored above this starts a piece.
    public var startScore: Float = 0.5
    /// A frame scored below this counts as quiet. When `slides` is set it slides from
    /// `endScoreShort` for a piece under `minSeconds` down to this by `targetSeconds`; otherwise it is held here.
    public var endScore: Float = 0.35
    public var endScoreShort: Float = 0.80
    /// Whether the end score slides or is fixed.
    public var slides = true
    /// Quiet frames in a row that end a piece (three is 0.77 s).
    public var quietFrames = 3
    /// Sound kept from before the first speech frame, so the first word is not cut.
    public var leadSeconds = 0.6
    public var minSeconds = 3.0
    public var targetSeconds = 20.0
    /// A piece is cut by force at this length; the next begins `leadSeconds` back, with no sound lost or doubled.
    public var maxSeconds = 25.0

    private var buffer: [Float] = []
    private var bufferStart = 0
    /// The stream is scored up to this sample.
    private var cursor = 0
    /// Where the piece being gathered starts, when one is.
    private var pieceStart: Int?
    private var speechSamples = 0
    private var quietSamples = 0

    public init() {}

    /// Samples of audio received so far.
    public var receivedSamples: Int { bufferStart + buffer.count }

    /// Adds audio. Call `nextFrame` and `score` until `nextFrame` is nil.
    public mutating func append(_ samples: [Float]) { buffer.append(contentsOf: samples) }

    /// The next frame waiting for a score, when a whole one has arrived.
    public var nextFrame: [Float]? {
        let from = cursor - bufferStart
        guard buffer.count - from >= Self.frame else { return nil }
        return Array(buffer[from..<(from + Self.frame)])
    }

    /// Takes the detector's score for the frame `nextFrame` returned; gives back a piece when one has ended.
    public mutating func score(_ probability: Float) -> PauseSegmenter.Piece? {
        cursor += Self.frame
        guard let start = pieceStart else {
            if probability > startScore {
                pieceStart = max(bufferStart, cursor - Int(leadSeconds * Double(sampleRate)))
                speechSamples = Self.frame
                quietSamples = 0
            } else {
                trim()
            }
            return nil
        }
        speechSamples += Self.frame
        if probability < endScore(afterSpeech: speechSamples) { quietSamples += Self.frame } else { quietSamples = 0 }
        if quietSamples >= quietFrames * Self.frame {
            let piece = take(from: start, to: cursor - quietSamples)
            pieceStart = nil
            trim()
            return piece
        }
        if cursor - start >= Int(maxSeconds * Double(sampleRate)) {
            let next = cursor - max(Int(leadSeconds * Double(sampleRate)), Self.frame)
            guard next > start else { return nil }
            let piece = take(from: start, to: next)
            pieceStart = next
            speechSamples = cursor - next
            quietSamples = min(quietSamples, cursor - next)
            trim()
            return piece
        }
        return nil
    }

    /// The piece still being gathered at the end of the stream, with whatever sound followed it.
    public mutating func finish() -> PauseSegmenter.Piece? {
        defer {
            pieceStart = nil
            cursor = receivedSamples
            trim()
        }
        guard let start = pieceStart else { return nil }
        return take(from: start, to: receivedSamples)
    }

    private func endScore(afterSpeech samples: Int) -> Float {
        guard slides else { return endScore }
        let seconds = Double(samples) / Double(sampleRate)
        if seconds < minSeconds { return endScoreShort }
        if seconds >= targetSeconds { return endScore }
        return endScoreShort - Float((seconds - minSeconds) / (targetSeconds - minSeconds)) * (endScoreShort - endScore)
    }

    private func take(from: Int, to: Int) -> PauseSegmenter.Piece {
        let a = max(from - bufferStart, 0), b = min(max(to - bufferStart, a), buffer.count)
        return PauseSegmenter.Piece(start: Double(from) / Double(sampleRate), samples: Array(buffer[a..<b]))
    }

    /// Lets go of sound no piece can still need.
    private mutating func trim() {
        let keepFrom = min(pieceStart ?? max(cursor - Int(leadSeconds * Double(sampleRate)), bufferStart), cursor)
        guard keepFrom > bufferStart else { return }
        buffer.removeFirst(min(keepFrom - bufferStart, buffer.count))
        bufferStart = keepFrom
    }
}
