import Foundation

extension SavedItem {
    /// What deleting it takes away, in its own words. A note says what a note has (its audio too,
    /// for a voice note whose audio was kept); a meeting keeps its wording.
    public var deleteWarning: String {
        switch kind {
        case .meeting: "The notes, transcript and recording are removed from this Mac."
        case .voiceNote: audioFile != nil ? "This note and its audio are removed from this Mac." : "This note is removed from this Mac."
        default: "It is removed from this Mac."
        }
    }
}
