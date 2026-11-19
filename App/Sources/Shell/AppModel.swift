import AppKit
import ChirpCore
import Observation
import SwiftUI

/// The five pillars, in sidebar order.
enum Pillar: String, CaseIterable, Identifiable {
    case speak, record, write, read, remember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speak: "Speak"
        case .record: "Record"
        case .write: "Write"
        case .read: "Read"
        case .remember: "Remember"
        }
    }

    var symbol: String {
        switch self {
        case .speak: "chirp.dictate"
        case .record: "chirp.voiceNote"
        case .write: "chirp.write"
        case .read: "chirp.documents"
        case .remember: "chirp.search"
        }
    }
}

/// App-wide state. Owns the store and the Personal Language Engine; feature controllers hang off it.
@MainActor
@Observable
final class AppModel {
    /// The database everything is saved in.
    let store: ChirpStore
    /// What Chirp knows about the user's language: dictionary, snippets, style and settings.
    let engine: PersonalLanguage

    /// The old five-tab name for where the window is; kept so links and checks that name a tab still work.
    var pillar: Pillar = .speak {
        didSet {
            switch pillar {
            case .speak: section = .dictations
            case .record: section = .meetings
            case .write: section = .draft
            case .read: section = .documents
            case .remember: section = .everything
            }
        }
    }
    /// Bumped when saved items change outside the usual paths, so the Library reloads.
    var libraryVersion = 0
    /// What the Library window is showing. It opens on Home. A page whose features are switched off is
    /// not there to be shown, whoever asks for it: Home is shown in its place.
    var section: LibrarySection = .home {
        didSet { if section != .home, !section.isShown { section = .home } }
    }
    /// The folder shown while `section` is `.folder`.
    var folderID: Int64?
    /// The folder being named in the sidebar: a new one (`id` nil) or one being renamed.
    var folderEdit: FolderEdit?
    /// The sidebar, shown or hidden with the button beside the window's controls. Below 900 points
    /// wide it hides on its own, and shows again there only when asked; what was chosen at full width is kept.
    var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebarHidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebarHidden") }
    }
    /// True while the window is under 900 points wide.
    var windowNarrow = false {
        didSet { if !windowNarrow { sidebarShownNarrow = false } }
    }
    /// The sidebar asked for while the window is narrow.
    var sidebarShownNarrow = false
    /// Whether the sidebar is on screen now.
    var sidebarVisible: Bool { windowNarrow ? sidebarShownNarrow : !sidebarHidden }
    /// The sidebar button: shows or hides it.
    func toggleSidebar() {
        if windowNarrow { sidebarShownNarrow.toggle() } else { sidebarHidden.toggle() }
    }
    /// Shows the sidebar, for something that happens in it (renaming a folder).
    func showSidebar() {
        if windowNarrow { sidebarShownNarrow = true } else { sidebarHidden = false }
    }
    /// True while a recording's transcript is shown beside its notes. Remembered between launches.
    var showTranscript = UserDefaults.standard.bool(forKey: "showTranscript") {
        didSet { UserDefaults.standard.set(showTranscript, forKey: "showTranscript") }
    }
    /// The Settings tab being shown. Saved, so Settings reopens where it was left (and a test link can pick one).
    var settingsTab = SettingsTab.saved {
        didSet { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settingsTab") }
    }
    /// True while the first-run window should be open. `FirstRunWindow` follows it.
    var showOnboarding: Bool
    /// What the bird is doing right now, shown in the menu bar and sidebar.
    var mood: BirdMood = .idle
    /// A short problem message shown at the top of the window until dismissed.
    var banner: String?

    /// Opens the library (the real one, a separate one for demos, or one in memory for tests) and
    /// decides whether first run still has to be shown.
    init() {
        // UI tests and previews run against a throwaway database.
        let args = ProcessInfo.processInfo.arguments
        // "--data-dir <folder>" keeps a separate library there (for demos and screenshots).
        let dataDir = args.firstIndex(of: "--data-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let inMemory = args.contains("--ui-testing") && dataDir == nil
        if let dataDir {
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            ChirpStore.audioDirectory = dataDir.appendingPathComponent("Audio", isDirectory: true)
        } else if inMemory {
            ChirpStore.audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-test-audio-\(ProcessInfo.processInfo.processIdentifier)")
        }
        do {
            store = try ChirpStore(url: inMemory ? nil : dataDir?.appendingPathComponent("chirp.sqlite") ?? ChirpStore.defaultURL)
        } catch {
            // A database that cannot be opened is unrecoverable for the app; fall back to memory
            // so the window can at least explain what happened.
            store = try! ChirpStore()
            banner = "Chirp could not open its library: \(error.localizedDescription)"
        }
        engine = PersonalLanguage(store: store)
        let done = (try? engine.setting("onboardingDone", as: Bool.self)) ?? false
        showOnboarding = !done && !args.contains("--skip-onboarding")
    }

    /// Remembers that first run is done, so it is not shown again, and closes it.
    func finishOnboarding() {
        try? engine.setSetting("onboardingDone", true)
        showOnboarding = false
        onboardingAgain = false
    }

    /// True while onboarding is open because it was asked for in Settings › General: it can then be
    /// closed at any step.
    var onboardingAgain = false

    /// Opens onboarding again from its first step (Settings › General › Help). It only shows the tour:
    /// no setting, permission or data is reset.
    func seeOnboardingAgain() {
        onboardingStep = 0
        onboardingAgain = true
        showOnboarding = true
    }

    /// Closes onboarding opened again from Settings, at whatever step it is on.
    func closeOnboarding() {
        showOnboarding = false
        onboardingAgain = false
    }

    // Set by test links to put a screen into a particular state.
    var onboardingStep: Int?
    var optionsRequest = 0
    /// The part of Settings › General a test link asked to be scrolled to ("about"), so it can be photographed.
    var settingsAnchor: String?

    /// An item another screen asked to show (from search, say). The owning page picks it up and clears it.
    var focus: SavedItem?

    /// Shows a saved item in the Library section that lists it. The Library window picks `focus` up
    /// and selects the item.
    func open(_ item: SavedItem) {
        // What a switched-off feature saved is kept, and its page is not there to open it on.
        guard Features.shared.set.shows(item.kind) else { return }
        focus = item
        section = LibrarySection.holding(item.kind)
    }

    /// Puts a problem in the banner at the top of the Library. `what` finishes the sentence "Could not …".
    func report(_ error: Error, doing what: String) {
        banner = "Could not \(what): \(error.localizedDescription)"
    }
}
