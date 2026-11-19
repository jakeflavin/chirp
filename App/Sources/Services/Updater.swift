import AppKit
import ChirpCore
import Observation
import Sparkle

/// Keeps Chirp up to date with Sparkle, from the update feed on the project's website (Docs/RELEASING.md).
///
/// Stable and beta releases share one feed. Beta items are on Sparkle's `beta` channel and are only offered when
/// "Get beta versions" is on. Turning it off never downgrades: the app waits for the next stable version.
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// Where the "Get beta versions" choice is kept.
    static let betaKey = "updatesIncludeBetas"

    /// Whether beta versions are offered. A beta build starts with this on, so its user keeps getting betas.
    var includesBetas: Bool {
        didSet { UserDefaults.standard.set(includesBetas, forKey: Self.betaKey) }
    }

    /// Whether Chirp checks for updates by itself, once a day.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// False in builds that can't update: test copies, and builds without the feed or its signing key.
    private(set) var isAvailable = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        includesBetas = UserDefaults.standard.object(forKey: Self.betaKey) as? Bool ?? Beta.isOn
        super.init()
    }

    /// Starts the updater, unless this is a test copy or a build that has no feed.
    func start() {
        guard controller == nil, Self.canUpdate else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            isAvailable = true
        } catch {
            Log.write("updates", "could not start: \(error.localizedDescription)")
        }
    }

    /// Checks now and shows the result.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    /// The `beta` channel when beta versions are on. The default (stable) channel is always included.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { includesBetas } ? ["beta"] : []
    }

    /// Test copies (started with a data folder of their own or driven by test links) never update themselves, and a
    /// build needs both the feed address and the public key to check signatures.
    private static var canUpdate: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--debug-hooks") || arguments.contains("--data-dir") || arguments.contains("--ui-testing") { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        return !(info["SUFeedURL"] as? String ?? "").isEmpty && !(info["SUPublicEDKey"] as? String ?? "").isEmpty
    }
}

/// Opens a new GitHub issue with the Chirp and macOS versions filled in. Nothing else is sent.
enum Feedback {
    static let repository = URL(string: "https://github.com/jakeflavin/chirp")!

    static func open() {
        var parts = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        parts.queryItems = [
            URLQueryItem(name: "template", value: "bug.yml"),
            URLQueryItem(name: "version", value: Beta.versionLine + (Beta.isOn ? " beta" : "")),
            URLQueryItem(name: "macos", value: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}
