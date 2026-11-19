import ChirpCore
import ChirpML
import SwiftUI

/// Receives `chirp://` links. Done at the app level (not per window) so links work whichever
/// window or panel is in front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The app's shared objects, set once at launch, for code that is not a view and has no environment to read them from.
    @MainActor static var app: AppModel?
    @MainActor static var models: ModelCenter?
    @MainActor static var dictation: DictationController?
    /// Opens Settings, which is a page of the Library window. There is no Settings window of its own.
    @MainActor static var openSettings: (() -> Void)?
    /// Opens the main window (set by the window itself, so it also works after the window was closed).
    @MainActor static var openMain: (() -> Void)?

    /// Brings Chirp forward on the given tab.
    @MainActor static func showMain(_ pillar: Pillar? = nil) {
        if let pillar { app?.pillar = pillar }
        NSApp.activate()
        if let openMain {
            openMain()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        // Without a Dock icon macOS does not bring the window forward by itself.
        Task { @MainActor in
            mainWindow?.makeKeyAndOrderFront(nil)
            if !DockPresence.shown { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// Opens Settings, which is a page of the Library window, on the tab it was last left on.
    @MainActor static func showSettings() {
        // A link may have named a tab since the page was last open.
        if let app, app.settingsTab != SettingsTab.saved { app.settingsTab = SettingsTab.saved }
        app?.section = .settings
        showMain()
    }

    /// The Library window, when it exists.
    @MainActor static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }
    }

    /// True while the Library window is on screen.
    @MainActor static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
    }

    /// Closing the window leaves Chirp running in the menu bar, so the shortcuts keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // The speech engine's GPU library stops the process if a model is still loaded at exit.
        Self.models?.transcriber.unloadNow()
        // The language model's helper would notice the app has gone within two seconds; this ends it now.
        Self.models?.language.stopNow()
    }

    /// Applies the light or dark choice, starts watching for first run, and lets the speech model
    /// unload itself when it has not been used for a while.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.models?.watchSpeechIdle()
        Self.models?.transcriber.onNote { Log.write("models", $0) }
        Task { @MainActor in
            Appearance.apply()
            DockPresence.applyAtLaunch()
            Updater.shared.start()
            if let app = Self.app, let models = Self.models, let dictation = Self.dictation {
                FirstRunWindow.shared.follow(app: app, models: models, dictation: dictation)
            }
            // Chirp starts with no window: the perch and the menu bar are the app. Automated runs still want the window.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                try? await Task.sleep(for: .milliseconds(600))
                Self.openMain?()
            }
        }
    }

    /// A test copy started with `--no-window` never opens its window by itself: each `open … chirp://debug/…`
    /// counts as a reopen, which would put the window over whatever the user is working in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !ProcessInfo.processInfo.arguments.contains("--no-window")
    }

    /// Files go to the perch, as if dropped on it; `chirp://` links go to the link handler.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            guard let app = Self.app else { return }
            for url in urls {
                // A file dropped on the Dock icon, or opened with Chirp.
                if url.isFileURL { PerchController.shared?.add(url) } else { LinkHandler.handle(url, app: app) }
            }
        }
    }
}

/// Hands the app a way to reopen the main window.
struct MainWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            AppDelegate.openMain = { openWindow(id: "main") }
            // Settings is a page of the Library window.
            AppDelegate.openSettings = { AppDelegate.showSettings() }
        }
    }
}

/// Whether Chirp has a Dock icon. Without one it lives in the menu bar and the perch.
@MainActor
enum DockPresence {
    static let key = "showInDock"
    static let menuBarKey = "showInMenuBar"

    /// True unless the user turned the Dock icon off.
    static var shown: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            // Chirp must stay reachable from somewhere: no Dock icon means the menu bar bird stays.
            if !newValue { UserDefaults.standard.set(true, forKey: menuBarKey) }
            apply()
        }
    }

    /// At launch only a hidden Dock icon needs anything done: an app starts with one.
    static func applyAtLaunch() {
        if !shown { NSApp.setActivationPolicy(.accessory) }
    }

    /// Shows or hides the Dock icon now, and keeps the Library window in front: changing this sends the
    /// app's windows to the back.
    static func apply() {
        let front = AppDelegate.mainWindowVisible
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        guard front else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

/// The app's executable is also every helper that runs a model (speech, language and search, the reading
/// voice, voice detection, speaker labelling): launched with a helper's flag it never becomes an app.
@main
enum Main {
    static func main() {
        if SpeechWorker.isWorkerInvocation { SpeechWorker.run() }
        if LanguageWorker.isWorkerInvocation { LanguageWorker.run() }
        if VoiceWorker.isWorkerInvocation { VoiceWorker.run() }
        if ListenWorker.isWorkerInvocation { ListenWorker.run() }
        ChirpApp.main()
    }
}

/// The app: the Library window (closed at launch) and the menu bar item. The perch is its
/// own panel, made here with the controllers every part shares.
struct ChirpApp: App {
    /// Keeps a test copy out of App Nap (see where it is begun).
    private static let testsAwake = FullSpeed()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel
    @State private var models: ModelCenter
    @State private var dictation: DictationController
    @State private var recorder: MeetingRecorder
    @State private var detector: MeetingDetector
    @State private var writeModel: WriteModel
    @State private var selectionPanel: SelectionPanelController
    @State private var underlines: UnderlineController
    @State private var reader: ReadController
    @State private var search: SearchController
    @State private var perch: PerchController
    @State private var menu: MenuBarModel

    /// Makes one of each controller, in the order they depend on each other, and hands the shared
    /// ones to the app delegate.
    init() {
        // The feature switches come first: every controller made below reads them.
        let features = Features.shared
        let app = AppModel()
        let models = ModelCenter()
        _app = State(initialValue: app)
        AppDelegate.app = app
        _models = State(initialValue: models)
        AppDelegate.models = models
        // Before any controller gives a shortcut its handler: installs still on the old keys move to the
        // right Option layout, and its own handler goes first.
        ShortcutLayout.prepare()
        let dictation = DictationController(app: app, models: models)
        _dictation = State(initialValue: dictation)
        AppDelegate.dictation = dictation
        let recorder = MeetingRecorder(app: app, models: models)
        _recorder = State(initialValue: recorder)
        let detector = MeetingDetector(recorder: recorder)
        _detector = State(initialValue: detector)
        let assistant = WritingAssistant(app: app, models: models)
        _writeModel = State(initialValue: WriteModel(app: app, assistant: assistant))
        let selection = SelectionPanelController(app: app, assistant: WritingAssistant(app: app, models: models))
        _selectionPanel = State(initialValue: selection)
        if LinkHandler.debugEnabled {
            // A copy driven by test links has nobody in front of it, and with the display off macOS
            // puts such an app to rest (App Nap): its timers slow down and it stops answering links for
            // minutes at a time. End-to-end runs started after the display went off lost checks in a
            // different place each time, on a build that passed all of them with the display on. So a
            // test copy says it is in use for as long as it runs.
            Self.testsAwake.begin("Driven by test links")
        }
        let underlines = UnderlineController(engine: app.engine, checker: assistant.checker)
        // A note's editor checks writing with the same checker.
        NoteController.checker = assistant.checker
        NoteController.engine = app.engine
        // A note's one button rewrites its sentence with the language model, read by rule afterwards.
        underlines.rewriter = { [assistant] task, text, context in try? await assistant.rewriteChecked(task, text: text, context: context) }
        _underlines = State(initialValue: underlines)
        let reader = ReadController(app: app, models: models)
        _reader = State(initialValue: reader)
        let perch = PerchController(
            app: app, dictation: dictation, recorder: recorder, detector: detector, reader: reader,
            underlines: underlines, selection: selection)
        _perch = State(initialValue: perch)
        // The menu bar item and its popover. It is not a scene: see MenuBarPopover.swift. Its "Settings…"
        // opens the Settings page of the Library window; there is no separate Settings window.
        _menu = State(initialValue: MenuBarModel(
            app: app, dictation: dictation, recorder: recorder, reader: reader, perch: perch, underlines: underlines))
        _search = State(initialValue: SearchController(app: app, models: models))
        // Test links for looking at the window: open it, and pick a Settings tab.
        // Opens the window without bringing Chirp in front of the app being used.
        LinkHandler.commands["open-main"] = { _ in AppDelegate.openMain?() }
        LinkHandler.commands["settings-tab"] = { q in
            if let tab = SettingsTab(rawValue: q["name"] ?? "") { app.settingsTab = tab }
            app.section = .settings
            // `at=about` scrolls General down to the version.
            app.settingsAnchor = q["at"]
        }
        LinkHandler.commands["open-item"] = { q in
            // The nth saved item of a kind, newest first, opened on its page.
            guard let kind = ItemKind(rawValue: q["kind"] ?? "") else { return }
            let items = (try? Library(store: app.store).items(kinds: [kind])) ?? []
            if let item = items[safe: Int(q["n"] ?? "0") ?? 0] { app.open(item) }
        }
        LinkHandler.commands["transcript"] = { q in app.showTranscript = q["show"] != "0" }
        // `window-size?w=760&h=600`: the window's size, for pictures at each width; `sidebar?show=0|1` its sidebar.
        LinkHandler.commands["window-size"] = { q in
            guard let window = AppDelegate.mainWindow, let w = Double(q["w"] ?? ""), let h = Double(q["h"] ?? "") else { return }
            window.setContentSize(NSSize(width: w, height: h))
        }
        LinkHandler.commands["sidebar"] = { q in
            if (q["show"] == "1") != app.sidebarVisible { app.toggleSidebar() }
        }
        LinkHandler.commands["dock"] = { q in DockPresence.shown = q["show"] != "0" }
        LinkHandler.stateProviders["library"] = {
            ["section": app.section.rawValue, "settingsTab": app.settingsTab.rawValue, "showInDock": DockPresence.shown,
             // The checked editor is a test copy's page, not one of the sidebar's.
             "sidebar": LibrarySection.allCases.filter { $0 != .draft && $0 != .folder && $0.isShown }.map(\.rawValue),
             "beta": Beta.isOn, "version": Beta.versionLine,
             "sidebarShown": app.sidebarVisible, "windowNarrow": app.windowNarrow,
             "windowWidth": AppDelegate.mainWindow?.contentLayoutRect.width ?? 0] as [String: Any]
        }
        // A page whose features were all switched off is left for Home.
        features.whenChanged { _, _ in if !app.section.isShown { app.section = .home } }
        // Features saved as switched off are put away now that everything exists.
        features.applyAtLaunch()
        // The right Option shortcuts answer only while that key is down.
        ShortcutLayout.start()
        // The danger zone's test links are there from launch, not from the first look at Settings.
        _ = DangerZone.shared
        // Import folders left by documents that were opened and never kept.
        DocumentImporter.clearStaging()
        if LinkHandler.debugEnabled { DocumentDebug.register(app: app, reader: reader) }
        if LinkHandler.debugEnabled { HomeDebug.register(app: app, recorder: recorder, dictation: dictation) }
    }

    var body: some Scene {
        Window("Chirp", id: "main") {
            LibraryWindow()
                .environment(app)
                .environment(models)
                .environment(dictation)
                .environment(recorder)
                .environment(detector)
                .environment(writeModel)
                .environment(underlines)
                .environment(reader)
                .environment(search)
                .environment(perch)
                // The smallest window everything fits in without overlapping.
                .frame(minWidth: 760, minHeight: 520)
                .background(MainWindowOpener())
        }
        .defaultSize(width: 1160, height: 740)
        // The toolbar and the title bar are one band; the sidebar floats under the window's buttons.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkNow() }
                    .disabled(!Updater.shared.isAvailable)
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { Feedback.open() }
            }
            // Settings is a page of this window, so the usual menu item and key open it there.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppDelegate.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
