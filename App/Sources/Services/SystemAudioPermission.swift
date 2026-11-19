import ChirpCore
import Foundation

/// Whether macOS lets Chirp record this Mac's sound ("System Audio Recording"), asked of macOS itself.
///
/// There is no public way to ask. Chirp used to infer it from silence, and so told the user to allow a
/// permission that was already allowed whenever the other side of a call was simply quiet. So the
/// system's own permission service is asked instead.
enum SystemAudioPermission {
    typealias Status = SystemAudioAccess

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int

    private static let preflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
            let symbol = dlsym(handle, "TCCAccessPreflight")
        else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    /// What macOS says now. TESTING: `--debug-hooks` with `CHIRP_SYSTEM_AUDIO=denied` (or `allowed`,
    /// `notAsked`, `unknown`) in the environment answers that instead.
    static var status: Status {
        if ProcessInfo.processInfo.arguments.contains("--debug-hooks"), let forced = ProcessInfo.processInfo.environment["CHIRP_SYSTEM_AUDIO"].flatMap(Status.init(rawValue:)) {
            return forced
        }
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .allowed
        case 1: return .denied
        case 2: return .notAsked
        default: return .unknown
        }
    }
}
