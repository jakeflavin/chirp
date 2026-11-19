import AppKit
import ChirpCore
import Observation
import SwiftUI

/// Notices when a call app starts using the microphone and offers to record. It only looks at
/// which apps have the microphone open; it never listens to anything itself.
@MainActor
@Observable
final class MeetingDetector {
    /// Apps that mean "a call is happening" when they hold the microphone (`CallDetection`, which also
    /// knows the services macOS runs FaceTime and phone calls through).
    static var callApps: [String: String] { CallDetection.callApps }

    /// The name of a call app found with `helperParent`: for a FaceTime or phone call, whichever of
    /// FaceTime and Phone is in use.
    static func callName(_ parent: String) -> String? {
        CallDetection.name(of: parent, appleCall: appleCallName())
    }

    /// "FaceTime" or "Phone", from which of the two apps is in front, or open.
    private static func appleCallName() -> String {
        func state(_ bundleID: String) -> (open: Bool, inFront: Bool) {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            return (!apps.isEmpty, apps.contains(where: \.isActive))
        }
        let faceTime = state(CallDetection.faceTime), phone = state(CallDetection.phone)
        return CallDetection.appleCallName(faceTimeOpen: faceTime.open, faceTimeInFront: faceTime.inFront, phoneOpen: phone.open, phoneInFront: phone.inFront)
    }

    private let recorder: MeetingRecorder
    /// Checks every three seconds which apps have audio running.
    private var task: Task<Void, Never>?
    /// Apps the user said "not now" to, until they let go of the microphone.
    private var declined: Set<String> = []
    /// What is being offered for recording now: an app's bundle identifier, or "calendar".
    private var offering: String?
    /// The call app the current recording was started for. When that call ends, so does the recording.
    private var recordingFor: String?
    /// When the call being recorded last had audio running, to notice when it has ended.
    private var callLastSeen = Date()
    /// Whether a recording was running at the last check, to notice one stopped by hand.
    private var wasRecording = false
    /// Calendar meetings already announced, so each is offered once.
    private var announced: Set<String> = []
    /// True when the recording began from a calendar reminder and no call app is tied to it yet.
    private var awaitingCallApp = false
    /// The name shown in the offer: the meeting's from the calendar, or the call app's.
    private(set) var offerTitle = ""
    /// The call app's name when the offer was made, if the offer is for one.
    private var offerApp: String?
    /// When the current offer was made; a calendar offer goes away after three minutes.
    private var offeredAt = Date()

    /// Whether Chirp watches for calls and offers to record them.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "detectMeetings")
            follow()
        }
    }

    /// Looks for calls and calendar meetings only while it is switched on and Record is.
    private func follow() {
        enabled && Features.on(.meetings) ? start() : stop()
    }
    /// True while calls and the calendar are being looked for.
    var isLooking: Bool { task != nil }

    init(recorder: MeetingRecorder) {
        self.recorder = recorder
        enabled = UserDefaults.standard.object(forKey: "detectMeetings") as? Bool ?? true
        follow()
        Features.shared.whenChanged { [weak self] old, new in
            if old.isOn(.meetings) != new.isOn(.meetings) { self?.follow() }
        }
        Features.shared.probe("record.lookingForCalls") { [weak self] in self?.isLooking ?? false }
        LinkHandler.commands["meeting-offer"] = { [weak self] q in self?.offer(bundleID: q["app"] ?? "us.zoom.xos") }
        LinkHandler.commands["meeting-offer-accept"] = { [weak self] q in self?.accept(bundleID: q["app"] ?? "us.zoom.xos") }
        LinkHandler.stateProviders["micApps"] = { SystemAudioTap.appsUsingMicrophone() }
        LinkHandler.stateProviders["detector"] = { [weak self] in
            ["offering": self?.offering ?? "", "recordingFor": self?.recordingFor ?? "", "offerTitle": self?.offerTitle ?? "",
             "audioApps": SystemAudioTap.audioApps().map { "\($0.id) in=\($0.input) out=\($0.output)" }] as [String: Any]
        }
    }

    /// Starts the regular check.
    private func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.check()
            }
        }
    }

    /// Stops checking and takes down any offer.
    private func stop() {
        task?.cancel()
        task = nil
        offering = nil
    }

    /// One look at which apps have audio running: ends a recording whose call is over, takes down a stale
    /// offer, and offers to record a new call or a calendar meeting that is starting.
    private func check() {
        let apps = SystemAudioTap.audioApps()
        // On a call: the app has the microphone open.
        let active = apps.filter(\.input).compactMap { Self.helperParent($0.id) }
        // Still on a call: microphone or sound. A muted call app may let go of the microphone but keeps playing the others.
        let audible = Set(apps.compactMap { Self.helperParent($0.id) })
        declined.formIntersection(active)

        let recording = recorder.phase == .recording
        if recording, let app = recordingFor {
            if audible.contains(app) {
                callLastSeen = Date()
            } else if Date().timeIntervalSince(callLastSeen) > 10 {
                Log.write("record", "the \(Self.callName(app) ?? app) call ended: stopping the recording")
                recordingFor = nil
                recorder.stop()
            }
        }
        // A recording begun from a calendar reminder ends with the call that then shows up.
        if recording, awaitingCallApp, recordingFor == nil, let app = active.first {
            recordingFor = app
            callLastSeen = Date()
            awaitingCallApp = false
        }
        if !recording {
            recordingFor = nil
            awaitingCallApp = false
        }
        // A recording stopped by hand during a call: do not offer the same call again.
        if wasRecording, !recording { declined.formUnion(active) }
        wasRecording = recording

        // A call offer goes away when the call does; a calendar offer after three minutes.
        let stale = offering == "calendar" ? Date().timeIntervalSince(offeredAt) > 180 : !active.contains(offering ?? "")
        if offering != nil, stale || recorder.phase != .idle {
            self.offering = nil
        }
        guard recorder.phase == .idle, offering == nil else { return }
        // A meeting on the calendar is starting: offer before the call app is even open.
        if let event = MeetingCalendar.starting(CalendarReader.shared.events(), at: Date(), alreadyOffered: announced) {
            announced.insert(event.id)
            Log.write("record", "a calendar meeting is starting: offering to record")
            offer(bundleID: "calendar", title: event.title)
            return
        }
        guard let candidate = active.first(where: { !declined.contains($0) }) else { return }
        Log.write("record", "\(Self.callName(candidate) ?? candidate) is using the microphone: offering to record")
        offer(bundleID: candidate)
    }

    /// Maps what holds the microphone to the call app it belongs to, if it is one: the app itself, one of its
    /// helpers ("com.google.Chrome.helper", "us.zoom.caphost"), or the services behind FaceTime and phone calls.
    static func helperParent(_ bundleID: String) -> String? { CallDetection.parent(of: bundleID) }

    /// Whether somebody else is on the line: another app has the microphone open. With `name`, the call
    /// app's name when it is one Chirp knows.
    static func call() -> (on: Bool, name: String?) {
        let mine = Bundle.main.bundleIdentifier ?? "com.jakeflavin.chirp"
        let found = CallDetection.call(using: SystemAudioTap.appsUsingMicrophone(), own: mine)
        let known = found.parent.flatMap(callName)
        return (found.on, known == "a browser call" ? nil : known)
    }

    /// Starts recording the offered call or calendar meeting, and remembers which app it is so the
    /// recording ends when the call does.
    private func accept(bundleID: String) {
        let name = Self.callName(bundleID) ?? "A call"
        offering = nil
        if bundleID == "calendar" {
            recorder.start(.meeting)
            awaitingCallApp = true
            wasRecording = true
            Log.write("record", "recording the calendar meeting")
            return
        }
        recorder.start(.meeting, sourceApp: name == "a browser call" ? nil : name)
        recordingFor = bundleID
        callLastSeen = Date()
        wasRecording = true
        Log.write("record", "recording the \(name) call")
    }

    /// The offer on screen now, if any.
    var currentOffer: (id: String, title: String)? {
        guard let offering else { return nil }
        // `offerApp` is the app's name as it was when the offer was made (a FaceTime or phone call's can change).
        let generic = offerApp.map { $0 == "a browser call" ? "Call in your browser" : "\($0) call" }
        return (offering, offerTitle == offerApp ? generic ?? offerTitle : offerTitle)
    }

    /// The user said yes to the offer on screen.
    func acceptOffer() {
        if let offering { accept(bundleID: offering) }
    }

    /// The user said not now: the offer goes, and this app is not offered again until it lets go of the microphone.
    func declineOffer() {
        guard let offering else { return }
        declined.insert(offering)
        self.offering = nil
    }

    /// Offers to record a call in `bundleID` (or "calendar"), in the perch.
    func offer(bundleID: String, title: String? = nil) {
        guard Features.on(.meetings) else { return }
        // Say the meeting's own name when the calendar knows it.
        // Only a real meeting on the calendar names the offer; a call app is open, so one under way counts.
        let event = title == nil ? CalendarReader.shared.current(onCall: bundleID != "calendar") : nil
        offerApp = Self.callName(bundleID)
        let name = title ?? event?.title ?? offerApp ?? "A call"
        offering = bundleID
        offeredAt = Date()
        offerTitle = name
    }
}
