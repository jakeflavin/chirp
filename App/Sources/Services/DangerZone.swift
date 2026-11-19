import AppKit
import ChirpCore
import ChirpML
import Observation
import ServiceManagement
import SwiftUI

/// Settings › General › Danger zone: "Delete my library" and "Reset Chirp completely".
/// Each says what will go, needs a word typed, and stops
/// whatever Chirp is doing before anything is removed. What is removed is worked out in `DataReset`.
@MainActor
@Observable
final class DangerZone {
    static let shared = DangerZone()

    enum Action: String, Identifiable {
        case deleteLibrary, reset

        var id: String { rawValue }
        /// The word to type.
        var word: String { self == .deleteLibrary ? "delete" : "reset" }
        var title: String { self == .deleteLibrary ? "Delete your whole library?" : "Reset Chirp completely?" }
        var button: String { self == .deleteLibrary ? "Delete my library" : "Reset Chirp" }
    }

    /// The confirmation being shown, if one is.
    var asking: Action?
    /// What is being done once the button is pressed ("Stopping what is in progress"), nil otherwise.
    private(set) var working: String?
    /// Why it could not be done, to show in the confirmation.
    private(set) var problem: String?
    /// What the last one did, for test runs.
    private var last: [String: Any] = [:]

    // MARK: Where things are

    /// True for a copy started on its own data folder (a test copy), or on a library kept in memory.
    private static let ownData: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--data-dir") || args.contains("--ui-testing")
    }()

    /// The folder the library's files are in. A library kept in memory has only its audio folder.
    static var dataDirectory: URL {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), !args.contains("--data-dir") { return ChirpStore.audioDirectory }
        return ChirpStore.audioDirectory.deletingLastPathComponent()
    }

    /// The downloaded models and the link tool, wherever each is kept.
    ///
    /// A test copy shares the real Chirp's models, so it never removes them: it only removes the
    /// stand-ins named in `CHIRP_RESET_PLACES` (paths separated by colons), when started with `--debug-hooks`.
    static var downloads: [URL] {
        if ownData {
            guard LinkHandler.debugEnabled, let named = ProcessInfo.processInfo.environment["CHIRP_RESET_PLACES"] else { return [] }
            return named.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        let support = ChirpStore.supportDirectory.deletingLastPathComponent()
        return [
            // The speech model.
            Transcriber.modelDirectory,
            // The reading voice (FluidAudio keeps the model and its word list side by side).
            Voice.modelDirectory.appendingPathComponent("kokoro-82m-coreml"), Voice.modelDirectory.appendingPathComponent("kokoro"),
            // Speaker labels and voice detection, where FluidAudio downloads them.
            support.appendingPathComponent("FluidAudio/Models/speaker-diarization"), support.appendingPathComponent("FluidAudio/Models/silero-vad"),
            // The link tool.
            LinkImporter.toolsDirectory,
        ]
            // The language model in every size, the summary model and its adapter, and the search model.
            + (LanguageModelSize.allCases.map(\.modelID) + Self.summaryModelIDs + [Embedder.modelID]).map(ModelCenter.hubModelDirectory)
    }

    /// The summary model and its adapter, as hub ids without the adapter's pinned revision.
    private static var summaryModelIDs: [String] {
        let summary = ModelCenter.tldrSummaryModel
        return [summary.id] + (summary.adapter.map { [String($0.split(separator: "@")[0])] } ?? [])
    }

    /// What the library holds now.
    func counts() -> DataReset.Counts {
        guard let app = AppDelegate.app else { return .init() }
        return (try? DataReset.counts(Library(store: app.store))) ?? .init()
    }

    /// How much the downloaded models and the link tool take, in words ("2.3 GB").
    func downloadsSize() async -> String {
        let places = Self.downloads
        let bytes = await Task.detached(priority: .utility) { places.reduce(Int64(0)) { $0 + DataReset.size(of: $1) } }.value
        return bytes > 0 ? DataReset.sizeWords(bytes) : ""
    }

    private init() {
        // TESTING: `chirp://debug/danger?ask=deleteLibrary` (or `reset`) opens the confirmation on Settings ›
        // General; `danger?run=deleteLibrary&typed=delete` does what its button does with that word typed
        // (nothing happens unless the word is right); `danger?ask=` puts the confirmation away. `state` has `danger`.
        LinkHandler.commands["danger"] = { [weak self] q in
            guard let self else { return }
            if let ask = q["ask"] { self.asking = Action(rawValue: ask) }
            if let run = q["run"].flatMap(Action.init(rawValue:)) { Task { await self.run(run, typed: q["typed"] ?? "") } }
        }
        LinkHandler.stateProviders["danger"] = { [weak self] in
            guard let self else { return [:] }
            var out = self.last
            out["asking"] = self.asking?.rawValue ?? ""
            out["working"] = self.working ?? ""
            out["problem"] = self.problem ?? ""
            out["counts"] = self.counts().lines
            out["dataDirectory"] = Self.dataDirectory.path
            out["downloads"] = Self.downloads.map(\.path)
            out["logFolder"] = Log.url.deletingLastPathComponent().path
            out["onboardingDone"] = (try? AppDelegate.app?.engine.setting("onboardingDone", as: Bool.self)) ?? false
            return out
        }
    }

    // MARK: Doing it

    /// Does what the confirmation's button does. Nothing happens unless the word was typed.
    func run(_ action: Action, typed: String) async {
        guard working == nil, DataReset.confirms(typed, word: action.word), let app = AppDelegate.app else { return }
        problem = nil
        working = "Stopping what Chirp is doing"
        defer { working = nil }
        let stopped = await stopEverything()
        guard stopped else {
            problem = "Chirp is still finishing a recording. Try again in a moment."
            return
        }
        working = action == .deleteLibrary ? "Deleting your library" : "Resetting Chirp"
        let before = counts()
        do {
            try DataReset.deleteLibrary(app.store)
        } catch {
            problem = "The library could not be deleted: \(error.localizedDescription)"
            return
        }
        let left = DataReset.removeLibraryFiles(dataDirectory: Self.dataDirectory, audioDirectory: ChirpStore.audioDirectory)
        Log.write(
            "settings",
            "the library was deleted: \(before.meetings) meetings, \(before.notes) notes, \(before.dictations) dictations, "
                + "\(before.documents) documents, \(before.folders) folders\(left.isEmpty ? "" : "; \(left.count) files could not be removed")")
        last = ["did": action.rawValue, "left": left.map(\.lastPathComponent)]
        // Nothing on screen still points at something that is gone.
        PerchController.shared?.finished = nil
        PerchController.shared?.dropped = nil
        app.focus = nil
        app.banner = nil
        app.libraryVersion += 1
        guard action == .reset else {
            asking = nil
            PerchController.shared?.say("Your library was deleted", seconds: 4)
            return
        }
        await reset(app)
    }

    /// The rest of "Reset Chirp completely": the Dictionary, Snippets, Writing style and every setting,
    /// the downloaded models and the link tool. Then Chirp starts again, as on a new Mac.
    private func reset(_ app: AppModel) async {
        // Nothing holds a model's files open while they are removed.
        if let models = AppDelegate.models {
            for kind in ModelKind.allCases { await models.unload(kind) }
        }
        do {
            try DataReset.eraseEverything(app.store)
        } catch {
            problem = "Chirp could not be reset: \(error.localizedDescription)"
            return
        }
        let places = Self.downloads
        let freed = await Task.detached(priority: .userInitiated) { DataReset.remove(places) }.value
        Log.write(
            "settings",
            "Chirp was reset: \(DataReset.sizeWords(freed.bytes)) of models and tools removed"
                + (freed.failed.isEmpty ? "" : "; \(freed.failed.count) could not be removed"))
        // Opening at login is a setting too. (A test copy never asked for it.)
        if !Self.ownData { try? await SMAppService.mainApp.unregister() }
        // Every preference, shortcuts included. Last, so nothing that ran above writes one back.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        // Chirp opens again the way this copy was started, and this one ends without saving anything.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = !Self.ownData
        configuration.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        configuration.environment = ProcessInfo.processInfo.environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            exit(0)
        }
    }

    /// Stops a dictation, an import, a download, reading aloud, anything the language model is writing,
    /// and a recording (which is saved as Stop does, and then goes with the rest). False when a recording
    /// was still being finished after a minute and a half.
    private func stopEverything() async -> Bool {
        guard let perch = PerchController.shared else { return true }
        let dictation = perch.dictation, recorder = perch.recorder
        dictation.cancel()
        dictation.cancelImport()
        LinkImporter.shared.cancel()
        perch.reader.close()
        if recorder.phase == .recording { recorder.stop() }
        for _ in 0..<180 {
            // Notes, a summary or a rewrite being written: the language helper is ended, and the work fails at once.
            if recorder.writingNotesFor != nil || perch.reader.summarizing || perch.dropped?.summarizing == true {
                AppDelegate.models?.language.stopNow()
            }
            if recorder.phase == .idle, recorder.writingNotesFor == nil, dictation.phase == .idle { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

/// The two rows of the danger zone, and the confirmation each opens.
struct DangerZoneRows: View {
    @State private var danger = DangerZone.shared

    var body: some View {
        row(
            "Delete my library",
            "Every recording, note, dictation and document, with their audio and files. Dictionary, Snippets, Writing style and settings are kept",
            button: "Delete my library…", action: .deleteLibrary)
        row(
            "Reset Chirp completely",
            "The library, Dictionary, Snippets, Writing style, every setting and the downloaded models. Chirp starts again with onboarding",
            button: "Reset Chirp completely…", action: .reset)
    }

    private func row(_ title: String, _ help: String, button: String, action: DangerZone.Action) -> some View {
        LabeledContent {
            Button(button) { danger.asking = action }
                .buttonStyle(DeleteButtonStyle(solid: false))
                .accessibilityIdentifier("danger.\(action.rawValue)")
        } label: {
            Text(title)
            Text(help)
        }
    }
}

/// A button that deletes: Robin words on a faint Robin fill, or white on solid Robin for the one that does it.
struct DeleteButtonStyle: ButtonStyle {
    var solid: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(solid ? Color.white : Color.spelling)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Color.spelling.opacity(solid ? (configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? 0.18 : 0.09)), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// The confirmation: what goes, what is kept, that it cannot be undone, and the
/// word to type. The button stays off until the word matches.
struct DangerConfirmation: View {
    let action: DangerZone.Action
    @State private var danger = DangerZone.shared
    @State private var typed = ""
    @State private var counts = DataReset.Counts()
    @State private var downloads = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: Bool { DataReset.confirms(typed, word: action.word) }

    /// What is deleted, one line each.
    private var lines: [String] {
        switch action {
        case .deleteLibrary: counts.isEmpty ? ["Your library is empty: there is nothing to delete"] : counts.lines
        case .reset:
            [
                "Your whole library: meetings, notes, dictations and documents",
                "Your Dictionary, Snippets and Writing style",
                "Every setting and shortcut you changed",
                "The downloaded models and the link tool" + (downloads.isEmpty ? "" : " (\(downloads))"),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(action.title).font(.system(size: 15, weight: .bold)).tracking(-0.15).foregroundStyle(Color.ink)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text("This deletes, from this Mac:").padding(.bottom, 6)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Color.quiet.opacity(0.7)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        .accessibilityHidden(true)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 3).padding(.vertical, 2)
            }
            Text(action == .deleteLibrary
                ? "Kept: your Dictionary, Snippets, Writing style and settings."
                : "Chirp then quits and opens like a new install, with onboarding.")
                .foregroundStyle(Color.quiet).padding(.top, 10)
            Text("This cannot be undone.").fontWeight(.semibold).padding(.top, 12)
            if let problem = danger.problem {
                Text(problem).foregroundStyle(Color.spelling).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }
            Text("Type “\(action.word)” to confirm").font(.system(size: 12)).foregroundStyle(Color.quiet).padding(.top, 12)
            TextField(action.word, text: $typed)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focused ? Color.spelling.opacity(0.55) : Color.ink.opacity(0.2), lineWidth: focused ? 2 : 1))
                .padding(.top, 6).padding(.bottom, 16)
                .disabled(danger.working != nil)
                .onSubmit(run)
                .accessibilityLabel("Type \(action.word) to confirm")
                .accessibilityIdentifier("danger.word")
            HStack(spacing: 8) {
                if let working = danger.working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 12)).foregroundStyle(Color.quiet)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(danger.working != nil)
                Button(action.button, action: run)
                    .buttonStyle(DeleteButtonStyle(solid: true))
                    .disabled(!matches || danger.working != nil)
                    .accessibilityHint(matches ? "" : "Type \(action.word) in the field first")
                    .accessibilityIdentifier("danger.confirm")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.ink.opacity(0.9))
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
        .frame(width: 440, alignment: .leading)
        .background(Color.paper)
        .onAppear {
            counts = danger.counts()
            focused = true
        }
        .task { if action == .reset { downloads = await danger.downloadsSize() } }
    }

    private func run() {
        guard matches else { return }
        Task { await danger.run(action, typed: typed) }
    }
}
