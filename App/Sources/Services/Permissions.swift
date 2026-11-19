import AVFoundation
import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// The macOS permissions Chirp uses, and whether each is granted.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var accessibility = false
    /// Screen Recording: lets Chirp read the window in front during a recording.
    private(set) var screen = false
    /// True once the system Screen Recording prompt has been shown; after that only System Settings can change it.
    private(set) var screenAsked = UserDefaults.standard.bool(forKey: "screenAsked")

    init() { refresh() }

    /// Reads the current state of each permission from macOS.
    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        screen = CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording prompt the first time; afterwards opens System Settings.
    /// macOS applies the answer the next time Chirp is opened.
    func requestScreen() {
        if screenAsked {
            open("Privacy_ScreenCapture")
        } else {
            _ = CGRequestScreenCaptureAccess()
            screenAsked = true
            UserDefaults.standard.set(true, forKey: "screenAsked")
        }
        refresh()
    }

    var microphoneGranted: Bool { microphone == .authorized }

    /// Shows the system microphone prompt the first time; afterwards opens System Settings.
    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            open("Privacy_Microphone")
        }
        refresh()
    }

    /// Asks macOS to show its Accessibility prompt, which links to System Settings.
    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    /// True once Chirp has made macOS ask about System Audio Recording. macOS does not say what was answered.
    private(set) var systemAudioAsked = UserDefaults.standard.bool(forKey: "systemAudioAsked")

    /// macOS only asks about System Audio Recording when an app starts capturing, so capture for a moment.
    /// Asking here means the question does not arrive in the first minute of a real call.
    func requestSystemAudio() {
        guard !systemAudioAsked else { return openAudioCaptureSettings() }
        let tap = SystemAudioTap()
        try? tap.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tap.stop() }
        systemAudioAsked = true
        UserDefaults.standard.set(true, forKey: "systemAudioAsked")
        Log.write("permissions", "asked for System Audio Recording")
    }

    /// True once a sound check has heard this Mac's own sound, which proves call audio can be recorded.
    private(set) var systemAudioConfirmed = UserDefaults.standard.bool(forKey: "systemAudioConfirmed")
    /// True while a sound check is playing and listening.
    private(set) var checkingSound = false

    /// Plays a short chime and listens for it through the same path a meeting recording uses.
    /// macOS never says whether System Audio Recording was allowed, so this is how Chirp finds out.
    @discardableResult
    func soundCheck() async -> Bool {
        guard !checkingSound else { return systemAudioConfirmed }
        checkingSound = true
        defer { checkingSound = false }
        let peak = PeakMeter()
        let tap = SystemAudioTap()
        tap.onSamples = { samples in peak.add(samples) }
        do { try tap.start() } catch {
            Log.write("permissions", "sound check could not start: \(error.localizedDescription)")
            return false
        }
        systemAudioAsked = true
        UserDefaults.standard.set(true, forKey: "systemAudioAsked")
        try? await Task.sleep(for: .milliseconds(300))
        // The chime plays from another process: Chirp leaves its own sound out of recordings.
        for _ in 0..<2 {
            let chime = Process()
            chime.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            chime.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? chime.run()
            try? await Task.sleep(for: .milliseconds(900))
        }
        tap.stop()
        let heard = peak.value > 0.0005
        Log.write("permissions", String(format: "sound check: level %.5f, %@", peak.value, heard ? "heard" : "silent"))
        systemAudioConfirmed = heard
        UserDefaults.standard.set(heard, forKey: "systemAudioConfirmed")
        return heard
    }

    func openAudioCaptureSettings() { open("Privacy_AudioCapture") }

    /// Opens a Privacy & Security pane in System Settings.
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The loudest sample seen, shared between the audio thread and the caller.
final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func add(_ samples: [Float]) {
        let m = samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.lock(); peak = max(peak, m); lock.unlock()
    }
    var value: Float { lock.lock(); defer { lock.unlock() }; return peak }
}

/// The five permissions with what each is for and its state. Shared by Settings and first run.
struct PermissionRows: View {
    @State private var permissions = Permissions.shared
    @State private var calendar = CalendarReader.shared
    @State private var soundFailed = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()


    var body: some View {
        VStack(spacing: 8) {
            row("Microphone", "To hear you", granted: permissions.microphoneGranted, id: "microphone") {
                Task { await permissions.requestMicrophone() }
            }
            row("Accessibility", "To type into other apps and check your writing", granted: permissions.accessibility, id: "accessibility") {
                permissions.requestAccessibility()
            }
            row(
                "Call audio",
                soundFailed
                    ? "Chirp could not hear this Mac. Turn Chirp on under System Audio Recording, then check again."
                    : permissions.checkingSound ? "Playing a chime and listening for it" : "To hear the other side of a meeting",
                granted: permissions.systemAudioConfirmed, id: "systemAudio",
                label: permissions.checkingSound ? "Checking" : permissions.systemAudioAsked ? "Sound check" : "Allow",
                extra: soundFailed ? ("Open Settings", { permissions.openAudioCaptureSettings() }) : nil
            ) {
                Task {
                    if !permissions.systemAudioAsked {
                        // The first capture makes macOS ask. Give the user time to answer before listening.
                        permissions.requestSystemAudio()
                        try? await Task.sleep(for: .seconds(4))
                    }
                    soundFailed = !(await permissions.soundCheck())
                }
            }
            .disabled(permissions.checkingSound)
            row("Calendar", "To name meetings and know who is in them", granted: calendar.allowed, id: "calendar") {
                Task { await calendar.requestAccess() }
            }
            // Nothing looks at the screen now (automatic snapshots are off), so it is not asked for. It
            // comes back with the capture button.
            if ScreenReader.automatic { row(
                "Screen",
                permissions.screenAsked && !permissions.screen
                    ? "Turn Chirp on under Screen & System Audio Recording, then quit and reopen Chirp."
                    : "To see what a meeting is looking at, so the notes get names and numbers right",
                granted: permissions.screen, id: "screen", label: permissions.screenAsked ? "Open Settings" : "Allow"
            ) {
                permissions.requestScreen()
            } }
        }
        .onReceive(timer) { _ in
            permissions.refresh()
            calendar.refresh()
        }
    }

    /// One permission: what it is for, whether it is allowed, and the button to allow it.
    private func row(
        _ title: String, _ why: String, granted: Bool, id: String, label: String = "Allow",
        extra: (String, () -> Void)? = nil, action: @escaping () -> Void
    ) -> some View {
        Card(padding: 12) {
            HStack {
                Image(granted ? "chirp.checkCircle" : "chirp.ring")
                    .foregroundStyle(granted ? Color.style : Color.quiet)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(why).font(.caption).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Text("Allowed").font(.caption).foregroundStyle(Color.quiet)
                } else {
                    if let extra { Button(extra.0, action: extra.1).buttonStyle(.borderless) }
                    Button(label, action: action)
                        .accessibilityIdentifier("permission.\(id).allow")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission.\(id)")
    }
}
