import AppKit
import ChirpCore
import ScreenCaptureKit
import Vision

/// Reads what is on screen while a recording runs, so the notes know what was being looked at: the window
/// in front (a shared screen in a call, a document, a slide). The picture is read as text on this Mac
/// with Apple's Vision framework and never leaves it.
@MainActor
enum ScreenReader {
    /// One look at the screen: which app and window, the words in it, and the picture.
    struct Shot {
        let app: String
        let window: String
        let text: String
        let image: CGImage
    }

    /// Whether macOS lets Chirp see the screen (the Screen Recording permission).
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Whether the window in front is looked at by itself during a recording. Off, with no setting:
    /// when on, every recording read whatever window was in front into itself. A
    /// capture button pressed by hand takes its place when recording is rebuilt; until then nothing looks.
    static let automatic = false

    /// Has macOS ask for the Screen Recording permission (it asks once; after that it is a switch in System Settings).
    static func ask() { CGRequestScreenCaptureAccess() }

    /// Whether the screen may be read during recordings: never by itself.
    static var enabled: Bool { automatic }

    /// Apps whose windows are never looked at.
    private static let privateApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane", "com.apple.systempreferences",
    ]

    /// The window in front right now, as a picture and as text. Nil when Chirp may not look, has been
    /// told not to, or there is nothing suitable in front.
    /// `byHand` is the capture button pressed during a recording: the only way anything is looked at now.
    /// `readText` false leaves the words unread (`text` empty): the caller reads them afterwards, so the
    /// picture is kept at once however long reading takes.
    static func look(byHand: Bool = false, readText: Bool = true) async -> Shot? {
        if let feed = MeetingRecorder.feedFile("--feed-screen") {
            guard let image = NSImage(contentsOf: feed)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return Shot(app: "Keynote", window: feed.deletingPathExtension().lastPathComponent, text: readText ? await read(image) : "", image: image)
        }
        guard enabled || byHand, allowed, let front = NSWorkspace.shared.frontmostApplication,
            front.bundleIdentifier != Bundle.main.bundleIdentifier, !privateApps.contains(front.bundleIdentifier ?? "")
        else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == front.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 300 && $0.frame.height > 200
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(2, 1600 / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        else { return nil }
        return Shot(app: front.localizedName ?? "", window: window.title ?? "", text: readText ? await read(image) : "", image: image)
    }

    /// Lets the picture cross to the background queue that reads it.
    private struct Picture: @unchecked Sendable { let image: CGImage }

    /// The words in a picture, top to bottom.
    static func read(_ image: CGImage) async -> String {
        let picture = Picture(image: image)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                try? VNImageRequestHandler(cgImage: picture.image).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// Saves a picture small enough to keep, as a JPEG in the audio folder. Returns whether it was written.
    static func save(_ image: CGImage, as name: String) -> Bool {
        let width = min(1200, image.width)
        let height = Int(Double(image.height) * Double(width) / Double(max(1, image.width)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return false }
        try? FileManager.default.createDirectory(at: ChirpStore.audioDirectory, withIntermediateDirectories: true)
        return (try? data.write(to: ChirpStore.audioDirectory.appendingPathComponent(name))) != nil
    }
}
