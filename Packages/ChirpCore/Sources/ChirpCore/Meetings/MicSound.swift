import Foundation

/// Turning what a microphone delivers into the one channel Chirp records.
///
/// While a call app has the microphone, the Mac's built-in microphone can open with three channels (its
/// separate capsules) instead of one. Left to the system's converter, a format like that comes out as
/// silence, and a call then records none of the user's own voice. So Chirp mixes the channels down
/// itself, averaging the first two of a microphone with more, because the others can carry the same
/// sound upside down and cancel it.
public enum MicDownmix {
    /// How many of a microphone's channels go into the one: all of one or two, the first two of more.
    public static func channelsUsed(of count: Int) -> Int { min(max(count, 0), 2) }

    /// One channel from several, a frame at a time.
    public static func mono(_ channels: [UnsafeBufferPointer<Float>]) -> [Float] {
        let used = channelsUsed(of: channels.count)
        guard used > 0, let frames = channels.prefix(used).map(\.count).min(), frames > 0 else { return [] }
        if used == 1 { return Array(channels[0].prefix(frames)) }
        var out = [Float](repeating: 0, count: frames)
        let a = channels[0], b = channels[1]
        for i in 0..<frames { out[i] = (a[i] + b[i]) * 0.5 }
        return out
    }

    /// The same, for sound held in arrays.
    public static func mono(_ channels: [[Float]]) -> [Float] {
        func with(_ index: Int, _ sofar: [UnsafeBufferPointer<Float>]) -> [Float] {
            guard index < channels.count else { return mono(sofar) }
            return channels[index].withUnsafeBufferPointer { with(index + 1, sofar + [$0]) }
        }
        return with(0, [])
    }
}

/// Brings a microphone that arrives far too quiet up to an ordinary level, and leaves an ordinary one
/// alone. While a call app holds the microphone macOS can hand other apps its sound at about a thirtieth
/// of the usual level (measured with FaceTime); at that level Chirp's own "is this silence?" checks
/// throw the user's voice away.
///
/// The loudness of everything heard so far sets one gain, with a limit on peaks. The level aimed for is
/// Chirp's ordinary microphone level, not a broadcast level, and the gain is never below 1,
/// so a recording made with a microphone at its usual level is exactly what it was before.
public struct MicLeveler: Sendable {
    /// The level speech is brought up to (root mean square over the blocks that have sound in them).
    public static let target: Float = 0.03
    /// The most the sound is turned up: 40 dB.
    public static let mostGain: Float = 100
    /// Blocks quieter than this are silence and are not measured (−70 dB).
    static let floor: Float = 0.000_316
    /// 0.4 s at 16 kHz, the block length loudness is measured over.
    static let block = 6400
    static let ceiling: Float = 0.89

    /// What the sound is multiplied by now.
    public private(set) var gain: Float = 1
    private var pending: [Float] = []
    /// Mean squares of the blocks with sound in them so far.
    private var blocks: [Float] = []

    public init() {}

    /// Takes the next chunk of 16 kHz sound and returns it at the level for now.
    public mutating func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        while pending.count >= Self.block {
            var sum: Float = 0
            for s in pending[0..<Self.block] { sum += s * s }
            pending.removeFirst(Self.block)
            let mean = sum / Float(Self.block)
            if mean.squareRoot() > Self.floor { blocks.append(mean) }
            gain = Self.gain(for: blocks)
        }
        guard gain > 1 else { return samples }
        return samples.map { max(-Self.ceiling, min(Self.ceiling, $0 * gain)) }
    }

    /// The gain for what has been heard: from the blocks within 10 dB of the average of them all, so the
    /// pauses between words do not count as quiet speech.
    static func gain(for blocks: [Float]) -> Float {
        guard !blocks.isEmpty else { return 1 }
        let average = blocks.reduce(0, +) / Float(blocks.count)
        let loud = blocks.filter { $0 >= average * 0.1 }
        let level = ((loud.isEmpty ? average : loud.reduce(0, +) / Float(loud.count))).squareRoot()
        guard level > 0 else { return 1 }
        return min(mostGain, max(1, target / level))
    }
}
