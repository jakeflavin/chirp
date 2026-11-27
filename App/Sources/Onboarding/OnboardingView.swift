import AppKit
import ChirpCore
import ChirpML
import Observation
import SwiftUI

/// Shows first run in its own small window, since Chirp has no main window on screen at launch.
@MainActor
final class FirstRunWindow {
    static let shared = FirstRunWindow()
    /// The first-run window while it is open.
    private var window: NSWindow?
    private let closer = Closer()

    /// Closing the window by hand (only offered when it was opened again) closes onboarding the usual way.
    private final class Closer: NSObject, NSWindowDelegate {
        weak var app: AppModel?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { app?.closeOnboarding() }
            // `closeOnboarding` closes the window through `follow`.
            return false
        }
    }

    /// Keeps the window in step with `app.showOnboarding`, which first launch and test links both set.
    /// It opens or closes the window now, then waits to be told the value is changing and does the
    /// same again, so nothing runs in between.
    func follow(app: AppModel, models: ModelCenter, dictation: DictationController) {
        // The controllers are made after the app model; the window waits for them.
        if app.showOnboarding, window == nil, PerchController.shared == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                self.follow(app: app, models: models, dictation: dictation)
            }
            return
        }
        if app.showOnboarding, window == nil {
            open(app: app, models: models, dictation: dictation)
        } else if !app.showOnboarding, let window {
            window.close()
            self.window = nil
        }
        withObservationTracking {
            _ = app.showOnboarding
        } onChange: { [weak self] in
            // Told just before the value changes, and only once: look again after it has, and keep watching.
            Task { @MainActor in self?.follow(app: app, models: models, dictation: dictation) }
        }
    }

    /// Builds the window in the middle of the screen and brings Chirp forward to show it. On first run it
    /// has no close button: it goes when first run is finished. Opened again from Settings it can be closed
    /// at any step, with the button or ⌘W, like any other window.
    private func open(app: AppModel, models: ModelCenter, dictation: DictationController) {
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if app.onboardingAgain { style.formUnion([.closable, .miniaturizable]) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height), styleMask: style,
            backing: .buffered, defer: false)
        closer.app = app
        window.delegate = closer
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Chirp"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("firstRun")
        guard let perch = PerchController.shared else { return }
        // The steps hold the real controls, so they are given the real controllers.
        window.contentView = NSHostingView(
            rootView: OnboardingView().environment(app).environment(models).environment(dictation)
                .environment(perch).environment(perch.recorder).environment(perch.detector).environment(perch.reader).environment(perch.underlines))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
