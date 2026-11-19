import Foundation

/// What macOS says about recording this Mac's sound ("System Audio Recording").
public enum SystemAudioAccess: String, Sendable {
    case allowed, denied
    /// macOS has not asked the user yet.
    case notAsked
    /// macOS would not say: nothing is claimed either way.
    case unknown

    /// True only when macOS says the permission is not there.
    public var isMissing: Bool { self == .denied || self == .notAsked }
}

/// The notice shown during a recording when a side of it is silent.
///
/// Silence from the other side used to be taken for a missing permission, so "Allow System Audio
/// Recording" was shown when it was already allowed and the other side was simply quiet.
/// The permission is now asked of macOS, and is only mentioned
/// when macOS says it is missing.
public enum CaptureNotice {
    public static let noSound = "No sound is arriving. Check the microphone and System Audio permissions in Settings."
    public static let noCallAudio = "No call audio is arriving, only your microphone. Allow System Audio Recording for Chirp in System Settings."
    public static let micSilent = "Your microphone is silent. Check the Microphone permission and input device."

    /// The notice for now, or nil for none. `otherSideSilent` is true when this Mac's sound is being
    /// recorded for a call and nothing has been heard from it.
    public static func text(micSilent: Bool, otherSideSilent: Bool, access: SystemAudioAccess) -> String? {
        let permissionMissing = otherSideSilent && access.isMissing
        if micSilent && permissionMissing { return noSound }
        if permissionMissing { return noCallAudio }
        if micSilent { return Self.micSilent }
        return nil
    }

    /// Whether `warning` is one of these notices (and so is taken down when the sound comes back).
    public static func isOne(_ warning: String?) -> Bool {
        warning == noSound || warning == noCallAudio || warning == micSilent
    }

    /// Whether capture of this Mac's sound should be set up again: only while the permission is missing
    /// or unknown, in case it was allowed after the recording began. With it allowed, silence is just silence.
    public static func shouldRetryCapture(otherSideSilent: Bool, access: SystemAudioAccess) -> Bool {
        otherSideSilent && access != .allowed
    }
}
