import AppKit
import SwiftUI

/// A plain-text record of what Chirp did and why, at ~/Library/Logs/Chirp/chirp.log.
/// It exists so a problem can be diagnosed afterwards. It never holds what was said, typed or
/// selected: only sizes, timings and outcomes.
enum Log {
    static let url: URL = {
        // A test copy can keep its own log (`CHIRP_LOG=<file>`), so its lines are not mixed with the real Chirp's.
        if let other = ProcessInfo.processInfo.environment["CHIRP_LOG"], !other.isEmpty { return URL(fileURLWithPath: other) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Chirp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chirp.log")
    }()

    private static let queue = DispatchQueue(label: "chirp.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Adds one line to the log, from any thread. `area` says which part of Chirp it is from.
    static func write(_ area: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) [\(area)] \(message)\n"
            // Start again once the file passes 1 MB.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// A short message shown on top of whatever app is in front, for things that happen outside
/// Chirp's window (a shortcut that had nothing to work on, a missing permission).
@MainActor
enum Toast {
    private static let panel = FloatingPanel()
    /// Counts toasts, so an older one's timer does not hide a newer one.
    private static var current = 0
    /// The most recent message (for automated runs).
    private(set) static var lastMessage = ""

    /// Shows `message` for a few seconds: in the perch when there is one, otherwise in a floating panel.
    static func show(_ message: String, seconds: Double = 4) {
        // The message can name an item the user saved, so only its length is logged.
        Log.write("notice", "shown: \(message.count) characters")
        lastMessage = message
        if let perch = PerchController.shared {
            perch.say(message, seconds: seconds)
            return
        }
        current += 1
        let mine = current
        panel.show(ToastView(message: message), size: NSSize(width: 420, height: 64), corner: .bottomCenter)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if mine == current { panel.hide() }
        }
    }
}

/// How a toast looks when there is no perch to say it.
private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Bird(mood: .idle, size: 34)
            Text(message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.ink.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

/// Tells macOS that Chirp is doing something the user is waiting for. Without this, an app whose
/// window is hidden (Chirp's normal state while dictating into another app) is slowed down to save
/// power, and transcription takes many times longer.
@MainActor
final class FullSpeed {
    private var token: NSObjectProtocol?

    /// Starts telling macOS the user is waiting. Does nothing if already begun.
    func begin(_ reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: reason)
    }

    /// Stops telling macOS the user is waiting.
    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
