import Foundation

/// Which apps mean "a call is happening" when they hold the microphone, and what to call them.
///
/// FaceTime and phone calls taken on the Mac do not hold the microphone as FaceTime or Phone: macOS runs
/// them through two background services, which are what Core Audio lists.
public enum CallDetection {
    /// Call apps by bundle identifier, with the name used in "… call".
    public static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex", "com.hnc.Discord": "Discord", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "a browser call", "com.apple.Safari": "a browser call",
        "company.thebrowser.Browser": "a browser call", "org.mozilla.firefox": "a browser call",
        "com.microsoft.edgemac": "a browser call", "com.brave.Browser": "a browser call",
    ]

    /// The services macOS runs FaceTime and phone calls through, as Core Audio names them (a bundle
    /// identifier, or the program's path when it has none).
    public static let appleCallServices: Set<String> = [
        "com.apple.avconferenced", "/usr/libexec/avconferenced",
        "com.apple.TelephonyUtilities", "com.apple.TelephonyUtilities.callservicesd",
    ]

    /// What every FaceTime or phone call is filed under, whichever service holds the microphone.
    public static let appleCall = "com.apple.avconferenced"
    public static let faceTime = "com.apple.FaceTime"
    public static let phone = "com.apple.mobilephone"

    /// The call app a process holding the microphone belongs to, if it is one: the app itself, one of its
    /// helpers ("com.google.Chrome.helper", "us.zoom.caphost"), or one of Apple's call services.
    public static func parent(of bundleID: String) -> String? {
        if appleCallServices.contains(bundleID) { return appleCall }
        if callApps[bundleID] != nil { return bundleID }
        if bundleID.hasPrefix("us.zoom.") { return "us.zoom.xos" }
        return callApps.keys.sorted().first { bundleID.hasPrefix($0 + ".") }
    }

    /// The name for a call that Apple's services carry: FaceTime's or the Phone app's, whichever is in
    /// front, else whichever is open. With neither to go by, both.
    public static func appleCallName(faceTimeOpen: Bool, faceTimeInFront: Bool, phoneOpen: Bool, phoneInFront: Bool) -> String {
        if faceTimeInFront { return "FaceTime" }
        if phoneInFront { return "Phone" }
        switch (faceTimeOpen, phoneOpen) {
        case (true, false): return "FaceTime"
        case (false, true): return "Phone"
        default: return "FaceTime or phone"
        }
    }

    /// The name of a call app found with `parent(of:)`. `appleCall` is the name worked out for Apple's services.
    public static func name(of parent: String, appleCall name: @autoclosure () -> String) -> String? {
        parent == appleCall ? name() : callApps[parent]
    }

    /// Whether somebody else is on the line: something other than Chirp has the microphone open. With the
    /// call app it belongs to, when it is one Chirp knows.
    public static func call(using: [String], own: String) -> (on: Bool, parent: String?) {
        let others = using.filter { !$0.hasPrefix(own) }
        return (!others.isEmpty, others.compactMap { parent(of: $0) }.first)
    }
}
