import AVFoundation
import AppKit
import ChirpCore
import SwiftUI

/// `chirp://` links. `chirp://show/<pillar>` is a normal feature. The `chirp://debug/…` commands
/// only work when the app was launched with `--debug-hooks`; they let the app be driven and
/// photographed for testing without screen-recording or automation permissions.
@MainActor
enum LinkHandler {
    /// True when the app was launched with `--debug-hooks`. Without it only `chirp://show/…` does anything.
    static var debugEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--debug-hooks") }
    /// True when the app was launched with `--no-global-shortcuts`: a test copy run beside the real Chirp.
    /// It registers no global shortcuts and watches no keys or text in other apps, so the two do not
    /// both answer one key press. The perch still follows the pointer.
    static let noGlobalShortcuts = ProcessInfo.processInfo.arguments.contains("--no-global-shortcuts")
    /// Extra debug commands registered by features.
    static var commands: [String: @MainActor ([String: String]) -> Void] = [:]
    /// Values features expose for `chirp://debug/state?path=…`, written as JSON.
    static var stateProviders: [String: @MainActor () -> Any] = [:]
    /// When the app started, so the state file can say how long it has been running.
    static let launchedAt = Date()

    /// Acts on one `chirp://` link. The host picks the kind (`show` or `debug`), the first path part
    /// the command, and the query its arguments.
    static func handle(_ url: URL, app: AppModel) {
        guard url.scheme == "chirp" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        // A name given twice keeps its last value. (Insisting on unique names stopped the app on such a link.)
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
        switch url.host {
        case "show":
            if let name = parts.first, let pillar = Pillar(rawValue: name) { app.pillar = pillar }
        case "debug" where debugEnabled:
            guard let command = parts.first else { return }
            switch command {
            case "shot": if let path = query["path"] { screenshot(to: path, mode: query["mode"] ?? "cache") }
            case "state":
                var state: [String: Any] = ["uptime": Date().timeIntervalSince(launchedAt), "pillar": app.pillar.rawValue,
                                            "banner": app.banner ?? "", "toast": Toast.lastMessage, "callAudioConfirmed": Permissions.shared.systemAudioConfirmed,
                                            "accessibility": AXIsProcessTrusted(),
                                            "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                            "mainWindowVisible": AppDelegate.mainWindowVisible,
                                            "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
                for (key, provider) in stateProviders { state[key] = provider() }
                if let path = query["path"], let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            case "icon": if let dir = query["dir"] { writeIcon(to: dir) }
            case "settings":
                if let tab = query["tab"] { UserDefaults.standard.set(tab, forKey: "settingsTab") }
                AppDelegate.openSettings?()
            case "language-size":
                Task { await (AppDelegate.models)?.chooseLanguage(query["size"].flatMap(LanguageModelSize.init(rawValue:))) }
            case "onboarding-step": app.onboardingStep = Int(query["n"] ?? "0"); app.showOnboarding = true
            case "options": app.optionsRequest += 1
            case "toast": Toast.show(query["text"] ?? "", seconds: 30)
            case "sound-check": Task { await Permissions.shared.soundCheck() }
            case "section": if let s = query["name"].flatMap(LibrarySection.init(rawValue:)) { app.section = s }
            case "seed": seed(app)
            case "write-card":
                if let c = CheckedTextEditor.Coordinator.current, let issue = c.parent.issues[safe: Int(query["issue"] ?? "0") ?? 0] { c.show(issue) }
            case "close-main": AppDelegate.mainWindow?.close()
            // `onboarding?again=1` is the Settings row "See onboarding again"; `onboarding?close=1` its Close button.
            case "onboarding":
                if query["again"] == "1" { app.seeOnboardingAgain() } else if query["close"] == "1" { app.closeOnboarding() } else { app.showOnboarding = query["show"] != "0" }
            case "appearance":
                NSApp.appearance = NSAppearance(named: query["dark"] == "1" ? .darkAqua : .aqua)
            default: commands[command]?(query)
            }
        default: break
        }
    }

    /// Renders the app icon (the bird on its wire) at every size macOS wants.
    static func writeIcon(to dir: String) {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            // The icon is drawn with the bird's light colours whatever the Mac's appearance.
            let view = AppIconArt().frame(width: 1024, height: 1024).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = CGFloat(size) / 1024
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(size).png"))
        }
    }

    /// Example dictionary words, snippets and app styles, for demos and screenshots.
    static func seed(_ app: AppModel) {
        _ = try? app.engine.addWord("Zorblax")
        _ = try? app.engine.addWord("Kubernetes")
        _ = try? app.engine.learnCorrection(heard: "pria", meant: "Priya", note: "You changed “pria” to “Priya” in a dictation")
        try? app.engine.save(Snippet(cue: "my address", text: "221B Baker Street, London NW1 6XE"))
        try? app.engine.save(Snippet(cue: "sign off", text: "Thanks,\nSam"))
        try? app.engine.save(AppStyle(bundleID: "com.apple.mail", appName: "Mail", formality: .formal))
        try? app.engine.save(AppStyle(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", formality: .casual))
        // A small library, so the window can be looked at with something in it.
        let library = Library(store: app.store)
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        _ = try? library.save(SavedItem(
            kind: .document, title: "How birds learn to sing",
            body: "Most songbirds are not born knowing their song. A young bird listens to adults for weeks before it makes a sound, storing what it hears as a template. Then it starts to babble. The first attempts are quiet and messy, a little like a baby’s first words. Over about three and a half months the bird compares its own voice with the remembered template and corrects itself, note by note.",
            source: "birdnotes.example", createdAt: yesterday.addingTimeInterval(-7200)))
        if let note = try? library.save(SavedItem(kind: .voiceNote, title: "Remind me to book the venue before Friday", duration: 4, createdAt: yesterday.addingTimeInterval(-3600))),
            let id = note.id {
            try? library.replaceSegments(itemID: id, with: [TranscriptSegment(itemID: id, speaker: "Me", start: 0, end: 4, text: "Remind me to book the venue before Friday.")])
        }
        if let sync = try? library.save(SavedItem(
            kind: .meeting, title: "Design sync", summary: "## Summary\n- Onboarding stays as it is until after the beta.\n\n## Key points\n- I will share the new icon by Monday\n\n## Decisions\n- None noted",
            duration: 1440, createdAt: yesterday)), let id = sync.id {
            try? library.replaceSegments(itemID: id, with: [
                TranscriptSegment(itemID: id, speaker: "Me", start: 0, end: 5, text: "We should not change the onboarding until after the beta."),
                TranscriptSegment(itemID: id, speaker: "Speaker 2", start: 6, end: 9, text: "Agreed. Can you share the new icon by Monday?"),
            ])
        }
        _ = try? library.save(SavedItem(
            kind: .document, title: "Q3 report.pdf",
            body: String(repeating: "Feedback from the private beta was positive, with launch planned for the first week of March. ", count: 60),
            position: 2300, createdAt: now.addingTimeInterval(-10_800)))
        _ = try? library.save(SavedItem(
            kind: .dictation, body: "I can find the two testers this week.", appBundleID: "com.apple.mail", createdAt: now.addingTimeInterval(-7200)))
        if let review = try? library.save(SavedItem(
            kind: .meeting, title: "Launch review",
            summary: "## Summary\n- The beta goes out on March 3rd.\n- Two more testers are needed before then.\n- The payment bug is the main risk.\n\n## Key points\n- I will send the budget numbers by Wednesday\n- I will find the two testers this week\n- Priya will fix the payment bug before the beta\n- Sam will own the release notes\n\n## Decisions\n- The beta goes out on March 3rd.",
            duration: 1920, source: "Sam Lee, Priya Shah", createdAt: now.addingTimeInterval(-3600))), let id = review.id {
            try? library.replaceSegments(itemID: id, with: [
                TranscriptSegment(itemID: id, speaker: "Sam", start: 0, end: 6, text: "Thanks for joining everyone. The beta goes out on March 3rd, and we need two more testers."),
                TranscriptSegment(itemID: id, speaker: "Me", start: 7, end: 9, text: "I can find the two testers this week."),
                TranscriptSegment(itemID: id, speaker: "Priya", start: 10, end: 15, text: "One risk is the payment bug. I will fix it before the beta."),
            ])
        }
        app.libraryVersion += 1
    }

    /// A picture of a window as it is drawn on screen, sidebar materials included. Falls back to nil
    /// when the system will not provide one.
    static func composited(_ window: NSWindow) -> NSBitmapImageRep? {
        // Ignore the shadow framing (1), best resolution (8).
        guard let image = windowImage(window.windowNumber, options: (1 << 0) | (1 << 3)), image.width > 8 else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    /// One window of this app as it is on screen, at its own bounds. The system call is looked up by
    /// name, and reading the app's own windows needs no screen-recording permission. Nil when the
    /// system will not provide a picture. Safe to call from any thread.
    nonisolated static func windowImage(_ windowNumber: Int, options: UInt32) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // A window not yet on screen has a number that is not a real window id (it can be negative).
        guard let id = UInt32(exactly: windowNumber), id > 0,
            let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return nil }
        // A .null rect with "this window only" (8) gives the window's own bounds.
        return unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, id, options)?.takeRetainedValue()
    }

    /// Draws a window from its layers. Sharp, and includes the sidebar, but materials come out flat.
    static func layered(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        if !layer.isGeometryFlipped, view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return rep
    }

    /// Writes a PNG of every visible Chirp window, largest first: `<path>.png`, `<path>-2.png`, …
    /// `mode` picks how: "screen" (as drawn on screen), "layer" (from its layers), or the default,
    /// which asks each window's view to draw itself and needs no permission.
    static func screenshot(to path: String, mode: String = "cache") {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 40 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for (i, window) in windows.enumerated() {
            let url = URL(fileURLWithPath: path + (i == 0 ? "" : "-\(i + 1)") + ".png")
            if let rep = mode == "screen" ? composited(window) : mode == "layer" ? layered(window) : nil {
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                continue
            }
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// The app icon: the bird on its wire against a warm paper tile.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 228, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.96, blue: 0.89), Color(red: 0.97, green: 0.88, blue: 0.70)], startPoint: .top, endPoint: .bottom))
                .padding(100)
            // The wire, with a small wave in it.
            Path { p in
                p.move(to: CGPoint(x: 150, y: 700))
                p.addCurve(to: CGPoint(x: 874, y: 700), control1: CGPoint(x: 420, y: 730), control2: CGPoint(x: 640, y: 670))
            }
            .stroke(Color(red: 0.12, green: 0.14, blue: 0.19), style: StrokeStyle(lineWidth: 22, lineCap: .round))
            StaticBird().frame(width: 560, height: 560).offset(x: -10, y: -52)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The bird drawn once, without animation, for the icon.
struct StaticBird: View {
    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 100
            let body = Color.birdBody
            let belly = Color("BirdBelly")
            let beak = Color("BirdBeak")
            let shade = Color.birdWing
            let bead = Color.birdEye
            var legs = Path()
            for x in [45.0, 55.0] {
                legs.move(to: CGPoint(x: x * u, y: 80 * u)); legs.addLine(to: CGPoint(x: x * u, y: 90 * u))
                legs.move(to: CGPoint(x: (x - 3) * u, y: 91 * u)); legs.addLine(to: CGPoint(x: (x + 3) * u, y: 91 * u))
            }
            ctx.stroke(legs, with: .color(beak), style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round))
            var tail = Path()
            tail.move(to: CGPoint(x: 26 * u, y: 58 * u))
            tail.addQuadCurve(to: CGPoint(x: 9 * u, y: 50 * u), control: CGPoint(x: 14 * u, y: 58 * u))
            tail.addQuadCurve(to: CGPoint(x: 30 * u, y: 70 * u), control: CGPoint(x: 13 * u, y: 68 * u))
            tail.closeSubpath()
            ctx.fill(tail, with: .color(shade))
            ctx.fill(Path(ellipseIn: CGRect(x: 20 * u, y: 24 * u, width: 60 * u, height: 58 * u)), with: .color(body))
            ctx.fill(Path(ellipseIn: CGRect(x: 38 * u, y: 46 * u, width: 38 * u, height: 34 * u)), with: .color(belly))
            var wing = Path()
            wing.move(to: CGPoint(x: 27 * u, y: 50 * u))
            wing.addQuadCurve(to: CGPoint(x: 50 * u, y: 66 * u), control: CGPoint(x: 29 * u, y: 71 * u))
            wing.addQuadCurve(to: CGPoint(x: 27 * u, y: 50 * u), control: CGPoint(x: 49 * u, y: 50 * u))
            ctx.fill(wing, with: .color(shade))
            var bk = Path()
            bk.move(to: CGPoint(x: 77 * u, y: 45 * u))
            bk.addQuadCurve(to: CGPoint(x: 88 * u, y: 49 * u), control: CGPoint(x: 87 * u, y: 46 * u))
            bk.addQuadCurve(to: CGPoint(x: 77 * u, y: 53 * u), control: CGPoint(x: 86 * u, y: 52 * u))
            bk.closeSubpath()
            ctx.fill(bk, with: .color(beak))
            ctx.fill(Path(ellipseIn: CGRect(x: 65 * u, y: 48 * u, width: 8 * u, height: 8 * u)), with: .color(Color.birdCheek.opacity(0.45)))
            ctx.fill(Path(ellipseIn: CGRect(x: 58.4 * u, y: 38.4 * u, width: 9.2 * u, height: 9.2 * u)), with: .color(bead))
            ctx.fill(Path(ellipseIn: CGRect(x: 63.1 * u, y: 39.9 * u, width: 3 * u, height: 3 * u)), with: .color(.white))
        }
    }
}
