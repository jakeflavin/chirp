import ChirpCore
import ChirpML
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The tabs of Settings, one per feature, in the order they are shown.
enum SettingsTab: String, CaseIterable, Identifiable {
    /// `meetings` is the tab that was "Recording" before Meetings and Notes were split.
    case general, perch, dictation, meetings, notes, reading, writing, models, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .perch: "Perch"
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .reading: "Reading"
        case .writing: "Writing"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        }
    }

    /// The feature a tab holds the settings of, for the tabs that are one feature's.
    var feature: Feature? {
        switch self {
        case .dictation: .dictate
        case .meetings: .meetings
        case .notes: .notes
        case .reading: .read
        case .writing: .write
        case .general, .perch, .models, .shortcuts: nil
        }
    }

    /// The tab last shown. Names from before Settings was organised by feature still open the right tab.
    static var saved: SettingsTab {
        let name = UserDefaults.standard.string(forKey: "settingsTab") ?? ""
        switch name {
        case "recording": return .meetings
        case "permissions", "about": return .general
        default: return SettingsTab(rawValue: name) ?? .general
        }
    }

    /// The names of the settings on each tab, for the search field.
    var settings: [String] {
        switch self {
        case .general:
            ["Features", "Dictate", "Meetings", "Notes", "Read aloud", "Writing checks", "Summarize", "Show Chirp in the Dock", "Show Chirp in the menu bar", "Show the perch", "Open Chirp when you log in", "Light or dark", "Microphone",
             "Permissions", "Check for updates automatically", "Get beta versions", "Check for updates", "Send feedback", "See onboarding again", "Show the log", "About Chirp", "Delete my library", "Reset Chirp completely"]
        case .perch: ["Show", "Position", "Move to bottom centre", "On the perch and in the extended area", "Customize Perch", "Reset sizes", "Tuck away in full screen"]
        case .dictation:
            ["Hold to talk", "Hands-free", "Keep dictations", "Keep the microphone ready", "Play a sound when dictation starts and stops", "Keep the audio of dictations",
             "Transcribe long dictations in pieces", "Free the speech model", "Run speech on"]
        case .meetings:
            ["Offer to record when a call starts", "Use my calendar", "Microphone", "Include this Mac’s sound", "Tell speakers apart", "Keep a meeting’s audio"]
        case .notes: ["Check writing in notes", "Microphone", "Title from the first words", "Keep a voice note’s audio"]
        case .reading: ["Voice", "Speed", "Leave out citation marks", "Leave out all text in brackets", "Read from the cursor when nothing is selected", "Mark the sentence and word being read",
             "Scroll to follow the reading"]
        case .writing: ["Deeper grammar check", "Also in other apps", "Underline spelling and grammar as I type", "Tone and underlines for each app", "Apps Chirp stays out of", "Fix the sentence at the cursor", "Offer snippets as I type"]
        case .models: ["Speech model", "Language model size", "Voice model", "Search model", "Keep the original file", "Keep images", "Documents use now"]
        case .shortcuts:
            ["Dictate", "Dictate hands-free", "Type the last dictation again", "New note", "Record a meeting", "Read aloud", "Summarize",
             "Fix writing", "Rephrase", "Fix the sentence at the cursor", "Open Library"]
        }
    }
}

/// Settings, a page of the window: the shared header, a row of tabs by feature, and that feature's
/// settings as grouped rows. `standalone` is the same page in a window of its own, which the menu bar's
/// "Settings…" opens.
struct SettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(PerchController.self) private var perch
    @Environment(SearchController.self) private var search
    var standalone = false

    /// What is typed in the window's search field while this page is open.
    private var query: String { standalone ? "" : search.query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", subtitle: "Changes apply straight away")
                .padding(.top, standalone ? 12 : 0)
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        app.settingsTab = tab
                        if !standalone { search.query = "" }
                    } label: {
                        ChipLabel(title: tab.title, selected: tab == app.settingsTab && query.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == app.settingsTab ? .isSelected : [])
                    .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                }
            }
            .padding(.leading, PageLayout.gutter).padding(.top, 14).padding(.bottom, 2)
            if query.isEmpty {
                // A feature's tab stays while the feature is switched off, and says so.
                if let feature = app.settingsTab.feature, !Features.on(feature) {
                    FeatureOffNote(feature: feature)
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(.leading, PageLayout.gutter).padding(.top, 12)
                }
                Group {
                    switch app.settingsTab {
                    case .general: GeneralSettings()
                    case .perch: PerchSettings()
                    case .dictation: SpeakOptions()
                    case .meetings: MeetingsOptions()
                    case .notes: NotesOptions()
                    case .reading: ReadOptions()
                    case .writing: WritingSettings()
                    case .models: ModelsSettings()
                    case .shortcuts: ShortcutsSettings()
                    }
                }
                .settingsForm()
            } else {
                found
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paper)
        // Customize Perch hangs from this window, from the perch's right-click and from Perch › Actions.
        .sheet(isPresented: Binding(get: { perch.customizing }, set: { perch.customizing = $0 })) { CustomizePerchSheet() }
    }

    /// The settings whose names hold what was typed, each with the tab it is on.
    private var found: some View {
        let matches = SettingsTab.allCases.flatMap { tab in
            tab.settings.filter { $0.localizedCaseInsensitiveContains(query) }.map { (tab: tab, name: $0) }
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("Settings found", count: matches.count)
                if matches.isEmpty { EmptyLine("No setting has that name.") }
                ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                    ItemRow(title: match.name, meta: match.tab.title, alwaysShowActions: true) {
                        ActButton(title: "Show") { show(match.tab) }
                    }
                    .onTapGesture { show(match.tab) }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, PageLayout.gutter)
        }
    }

    private func show(_ tab: SettingsTab) {
        app.settingsTab = tab
        search.query = ""
    }
}

extension View {
    /// A settings tab's rows: grouped as in System Settings, on Chirp's paper, with each group starting
    /// on the page's left line.
    func settingsForm() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            // A grouped form keeps its groups at most 700 wide, centred, with 20 at each side. Held to
            // that width it cannot centre them, and their edge lands on the page's left line.
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.leading, PageLayout.gutter - 20)
    }
}

/// A group of settings under a heading set like every other section heading: 13 semibold, on the
/// page's left line (a grouped form would indent it to the rows' text).
struct SettingsSection<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ title: String, @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    var body: some View {
        Section {
            content()
        } header: {
            Text(title).font(.sectionTitle).foregroundStyle(Color.ink).padding(.leading, -10).padding(.top, 6)
        } footer: {
            footer()
        }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// Where Chirp shows, light or dark, the microphone, what is kept, permissions and the version.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(DictationController.self) private var dictation
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(PerchController.self) private var perch
    @State private var inDock = DockPresence.shown
    @AppStorage(DockPresence.menuBarKey) private var inMenuBar = true
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var microphone = AudioDevices.preferredUID
    /// The microphones to choose from, read when the tab appears.
    @State private var inputs: [AudioDevices.Input] = []
    @State private var appearance = Appearance.choice
    @State private var danger = DangerZone.shared

    var body: some View {
        @Bindable var dictation = dictation
        @Bindable var recorder = recorder
        @Bindable var danger = danger
        @Bindable var perch = perch
        // The switches are redrawn when a feature changes from elsewhere (a test link).
        let _ = Features.shared.set
        ScrollViewReader { proxy in
        Form {
            SettingsSection("Features") {
                ForEach(GeneralSettings.featureOrder) { feature in
                    Toggle(isOn: Features.shared.binding(feature)) {
                        Text(feature.title)
                        if let help = Self.help(for: feature) { Text(help) }
                    }
                    .accessibilityIdentifier("settings.feature.\(feature.rawValue)")
                }
            } footer: {
                Text("A feature that is off is gone from the perch, the menu bar and the Library, and does nothing. What it saved is kept.")
            }
            SettingsSection("Where Chirp shows") {
                Toggle(isOn: $inDock) {
                    Text("Show Chirp in the Dock")
                    Text("Off: Chirp lives in the menu bar and the perch, with no Dock icon")
                }
                .onChange(of: inDock) { _, on in
                    guard on != DockPresence.shown else { return }
                    DockPresence.shown = on
                }
                .accessibilityIdentifier("settings.dock")
                Toggle(isOn: $inMenuBar) {
                    Text("Show Chirp in the menu bar")
                    if !inDock { Text("Stays on while Chirp has no Dock icon") }
                }
                .disabled(!inDock)
                Picker(selection: $perch.presence) {
                    ForEach(PerchPresence.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Show the perch")
                    Text("Position and full screen are under Perch")
                }
                .accessibilityIdentifier("settings.perch")
                Toggle("Open Chirp when you log in", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        // Already as asked. This is also how a change that failed is put back without trying again.
                        guard on != (SMAppService.mainApp.status == .enabled) else { return }
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {
                            Log.write("settings", "open at login: \(error.localizedDescription)")
                            atLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            SettingsSection("Appearance") {
                Picker("Light or dark", selection: $appearance) {
                    Text("Match the Mac").tag("")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, value in Appearance.choice = value }
            }
            SettingsSection("Sound") {
                Picker("Microphone", selection: $microphone) {
                    Text("Same as macOS").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.uid) }
                }
                .onChange(of: microphone) { _, uid in AudioDevices.preferredUID = uid }
            }
            // What is kept of a meeting or a voice note is on their own tabs.
            SettingsSection("Your data") {
                LabeledContent("Everything stays on this Mac", value: "Always")
            }
            SettingsSection("Permissions") {
                PermissionRows()
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            UpdateSettings()
            SettingsSection("Help") {
                LabeledContent {
                    Button("Send") { Feedback.open() }
                        .accessibilityLabel("Send feedback")
                        .accessibilityIdentifier("settings.feedback")
                } label: {
                    Text("Send feedback")
                    Text("Opens a new issue on GitHub with your Chirp version filled in")
                }
                LabeledContent {
                    Button("Show") { app.seeOnboardingAgain() }
                        .accessibilityLabel("See onboarding again")
                        .accessibilityIdentifier("settings.onboarding")
                } label: {
                    Text("See onboarding again")
                    Text("The tour and setup from the start. Nothing is reset")
                }
                // The log is for finding faults during the Beta; the row goes with the Beta flag.
                if Beta.isOn {
                    LabeledContent {
                        Button("Show in Finder") { NSWorkspace.shared.open(Log.url.deletingLastPathComponent()) }
                            .accessibilityLabel("Show the log in Finder")
                            .accessibilityIdentifier("settings.log")
                    } label: {
                        HStack(spacing: 6) {
                            Text("Show the log")
                            BetaTag()
                        }
                        Text("Sizes, timings and outcomes. Never what was said or typed")
                    }
                }
            }
            .id("help")
            SettingsSection("About Chirp") {
                LabeledContent("Version") {
                    HStack(spacing: 6) {
                        if Beta.isOn { BetaTag() }
                        Text(Beta.versionLine).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Version \(Beta.versionLine)\(Beta.isOn ? ", Beta" : "")")
                .id("about")
                DisclosureGroup("Built with") {
                    Text(AboutSettings.credits).font(.caption).foregroundStyle(Color.quiet).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SettingsSection("Danger zone") {
                DangerZoneRows()
            }
            .id("danger")
        }
        .sheet(item: $danger.asking) { action in DangerConfirmation(action: action) }
        .onAppear {
            inputs = AudioDevices.inputs()
            inDock = DockPresence.shown
        }
        .onChange(of: app.settingsAnchor, initial: true) { _, anchor in
            guard let anchor else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        }
        }
    }
}

/// Checking for updates, and the beta channel (Updater.swift).
struct UpdateSettings: View {
    @State private var updater = Updater.shared
    @State private var automatic = Updater.shared.checksAutomatically

    var body: some View {
        @Bindable var updater = updater
        SettingsSection("Updates") {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { _, on in updater.checksAutomatically = on }
                .disabled(!updater.isAvailable)
            Toggle(isOn: $updater.includesBetas) {
                Text("Get beta versions")
                Text("New features sooner, with more rough edges. Turning this off keeps your version until the next regular one")
            }
            .accessibilityIdentifier("settings.betas")
            LabeledContent {
                Button("Check Now") { updater.checkNow() }
                    .disabled(!updater.isAvailable)
                    .accessibilityHint(updater.isAvailable ? "" : "This copy of Chirp can't update itself")
            } label: {
                Text("Check for updates")
                if !updater.isAvailable { Text("This copy of Chirp can't update itself") }
            }
        }
        .onAppear { automatic = updater.checksAutomatically }
    }
}

extension GeneralSettings {
    /// The line under a feature's name, only where the name is not enough.
    /// The switches in one order, the same in Settings and in onboarding.
    static let featureOrder: [Feature] = [.dictate, .meetings, .notes, .write, .read, .summarize]

    static func help(for feature: Feature) -> String? {
        switch feature {
        case .meetings: "Calls and meetings: notes and a transcript"
        case .notes: "Type or say a note; voice notes keep their audio"
        case .write: "Underlines, Fix and Rewrite"
        case .dictate, .read, .summarize: nil
        }
    }
}

/// The perch: how much of it shows, where it sits, and what it does in full screen.
struct PerchSettings: View {
    @Environment(PerchController.self) private var perch

    var body: some View {
        @Bindable var perch = perch
        Form {
            SettingsSection("On screen") {
                Picker(selection: $perch.presence) {
                    ForEach(PerchPresence.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Show")
                    Text("Hidden shows the perch only while Chirp is working")
                }
                // Shows where the perch really is, a side edge or a dragged place included.
                Picker(selection: Binding(get: { perch.spot.stored }, set: { stored in
                    if let spot = PerchSpot(stored: stored) { perch.setSpot(spot) }
                })) {
                    ForEach(PerchPosition.allCases) { Text($0.title).tag($0.spot.stored) }
                    Text("Left edge").tag(PerchSpot.leftEdge.stored)
                    Text("Right edge").tag(PerchSpot.rightEdge.stored)
                    if case .free = perch.spot { Text("Where you dragged it").tag(perch.spot.stored) }
                } label: {
                    Text("Position")
                    Text("Or drag the perch by the bird; it remembers its place on each display")
                }
                LabeledContent("Put it back") {
                    Button("Move to bottom centre") { perch.setSpot(.bottomCentre) }
                }
            }
            // Which actions are on the perch and in More.
            SettingsSection("Actions") {
                PerchActionsRow()
            }
            SettingsSection("When it opens") {
                LabeledContent {
                    Button("Reset sizes") {
                        perch.bodyHeights = [:]
                        UserDefaults.standard.removeObject(forKey: "perchBodyHeights")
                    }
                    .disabled(perch.bodyHeights.isEmpty)
                } label: {
                    Text("Heights you pulled it to")
                    Text("The perch remembers how tall you made each kind of content")
                }
            }
            SettingsSection("In full screen") {
                Toggle(isOn: $perch.hideInFullScreen) {
                    Text("Tuck away in full screen")
                    Text("It comes back when the pointer rests on that edge, or on any Chirp shortcut")
                }
            }
        }
    }
}

/// Writing checks: the deeper check, and underlines in other apps.
struct WritingSettings: View {
    @Environment(UnderlineController.self) private var underlines
    @State private var deep = GrammarChecker.deepEnabled
    @State private var deepEverywhere = GrammarChecker.deepInOtherApps
    @Environment(AppModel.self) private var app

    /// How many apps underlines are switched off in, beside the kinds Chirp leaves alone by itself.
    private var staysOut: String {
        let off = ((try? app.engine.appStyles()) ?? []).filter { !$0.underlinesEnabled }.count
        let chosen = off == 0 ? "Terminals, code editors, password fields" : off == 1 ? "1 app and terminals, code editors, password fields" : "\(off) apps and terminals, code editors, password fields"
        return "\(chosen) · Writing style › By app"
    }
    @State private var snippets = GrammarChecker.offersSnippets

    var body: some View {
        @Bindable var underlines = underlines
        Form {
            SettingsSection("In other apps") {
                Toggle(isOn: $underlines.enabled) {
                    Text("Underline spelling and grammar as I type")
                    Text("Works in apps that say where their text is, such as Notes, Mail and TextEdit")
                }
                LabeledContent("Right now", value: underlines.status.isEmpty ? "Waiting" : underlines.status)
                if underlines.pausedUntil != nil {
                    Button("Turn underlines back on") { underlines.resume() }
                }
                ShortcutRow(
                    title: "Fix the sentence at the cursor", help: "A small bird at the end of a sentence shows there is something to fix",
                    name: .fixSentence)
                Toggle(isOn: $snippets) {
                    Text("Offer snippets as I type")
                    Text("When you type a snippet’s cue, Chirp offers its saved text. Nothing is replaced until you accept")
                }
                .onChange(of: snippets) { _, on in GrammarChecker.offersSnippets = on }
            }
            SettingsSection("Deeper grammar check") {
                Toggle(isOn: $deep) {
                    Text("Catch what the instant check misses")
                    Text("Uses the language model once you pause typing")
                }
                .onChange(of: deep) { _, on in GrammarChecker.deepEnabled = on }
                Toggle(isOn: $deepEverywhere) {
                    Text("Also in other apps")
                    Text("Keeps the language model in memory while you type; best with 16 GB or more")
                }
                .onChange(of: deepEverywhere) { _, on in GrammarChecker.deepInOtherApps = on }
                .disabled(!deep)
            }
            SettingsSection("Per app") {
                LabeledContent("Tone and underlines for each app", value: "Writing style › By app")
                LabeledContent("Apps Chirp stays out of", value: staysOut)
            }
        }
    }
}

/// Every key Chirp uses, in one place.
struct ShortcutsSettings: View {
    @Environment(DictationController.self) private var dictation

    var body: some View {
        @Bindable var dictation = dictation
        // A feature that is switched off has no shortcuts to list.
        let on = Features.shared.set
        Form {
            // The one line above the groups: a heading with no rows under it.
            Section {
            } header: {
                Text("Every shortcut is right ⌥ and one letter under your right hand. Left ⌥ still types its symbols. Click a shortcut to change it.")
                    .font(.system(size: 13)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.leading, -10).padding(.top, 6)
            }
            if on.isOn(.dictate) { SettingsSection("Dictation") {
                HoldKeyPicker(title: "Dictate", help: "Hold to talk, release to finish")
                ShortcutRow(title: "Dictate hands-free", help: "Press once to start, again to stop", name: .dictate)
                ShortcutRow(title: "Type the last dictation again", name: .pasteLast)
            } }
            if on.isOn(.notes) { SettingsSection("Notes") {
                ShortcutRow(title: "New note", help: "Opens a note in the perch", name: .recordNote)
            } }
            if on.isOn(.meetings) { SettingsSection("Meetings") {
                ShortcutRow(title: "Record a meeting, or stop", name: .recordMeeting)
            } }
            if on.isOn(.read) || on.isOn(.summarize) { SettingsSection("Reading") {
                if on.isOn(.read) { ShortcutRow(title: "Read aloud what is selected, or on from the cursor", name: .readSelection) }
                if on.isOn(.summarize) { ShortcutRow(title: "Summarize what is selected, or the page", name: .summarize) }
            } }
            if on.isOn(.write) { SettingsSection("Writing") {
                ShortcutRow(title: "Fix writing: the list of fixes, or rephrase when there are none", name: .writePanel)
                ShortcutRow(title: "Rephrase the selected text", name: .rephrase)
                ShortcutRow(title: "Fix the sentence at the cursor", name: .fixSentence)
            } }
            SettingsSection("Chirp") {
                ShortcutRow(title: "Open Library", name: .openLibrary)
            } footer: {
                Text("The right ⌥ shortcuts need Accessibility, which is how Chirp tells the right Option key from the left.")
            }
        }
    }
}

/// The key that is held to talk: Right Option unless another, or none, is chosen. On the Dictation and
/// Shortcuts tabs.
struct HoldKeyPicker: View {
    @Environment(DictationController.self) private var dictation
    let title: String
    let help: String

    var body: some View {
        @Bindable var dictation = dictation
        Picker(selection: $dictation.holdKey) {
            ForEach(HoldKey.allCases) { Text($0.title).tag($0) }
        } label: {
            Text(title)
            switch dictation.holdKey {
            case .fn: Text("Set “Press 🌐 key to” to “Do Nothing” in System Settings › Keyboard")
            case .none: Text("Off: dictation starts only from the hands-free shortcut")
            case .rightOption: Text("\(help). Left Option still types its symbols")
            case .rightCommand: Text(help)
            }
        }
        .accessibilityIdentifier("settings.holdKey")
    }
}

/// Lets the user override which size of language model Chirp uses on this Mac.
struct LanguageModelPicker: View {
    @Environment(ModelCenter.self) private var models
    @State private var choice = ModelCenter.languageChoice?.rawValue ?? ""

    /// This Mac's memory in whole gigabytes, for the note under the picker.
    private var memoryGB: Int { MacMemory.wholeGigabytes(ModelCenter.memoryBytes) }
    private var recommended: LanguageModelSize { .recommended(memoryBytes: ModelCenter.memoryBytes) }

    var body: some View {
        Picker(selection: $choice) {
            Text("Automatic: \(recommended.name) for this Mac").tag("")
            ForEach(LanguageModelSize.allCases) { size in
                Text("\(size.name) · \(String(format: "%.1f", size.downloadGB)) GB · for \(size.comfortableMemoryGB) GB Macs and up").tag(size.rawValue)
            }
        } label: {
            Text("Language model size")
            Text(note)
        }
        .onChange(of: choice) { _, value in
            Task { await models.chooseLanguage(LanguageModelSize(rawValue: value)) }
        }
        .accessibilityIdentifier("models.languageSize")
    }

    /// The line under the picker: which size is in use, or a warning when the chosen one is too big
    /// for this Mac.
    private var note: String {
        let _ = models.languageVersion
        let size = ModelCenter.languageSize
        if let chosen = LanguageModelSize(rawValue: choice), !chosen.isComfortable(memoryBytes: ModelCenter.memoryBytes) {
            return "\(chosen.name) may be slow with \(memoryGB) GB of memory. If it will not load, Chirp uses the next size down"
        }
        return "Larger sizes write better notes and rewrites; smaller ones are faster. Now using \(size.name)"
    }
}

/// One row per model: what it is for, its size and licence, and its current state.
struct ModelsSettings: View {
    @Environment(ModelCenter.self) private var models

    var body: some View {
        ScrollViewReader { proxy in
            form
                // A test link asks for the documents' settings to be scrolled to (`settings-tab?name=models&at=documents`).
                .onChange(of: app.settingsAnchor, initial: true) { _, anchor in
                    guard anchor == "documents" else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo("documents", anchor: .bottom)
                    }
                }
        }
    }

    private var form: some View {
        Form {
            SettingsSection("On this Mac") {
                ForEach(ModelKind.allCases) { kind in
                    ModelRow(kind: kind)
                }
                .id(models.languageVersion)
            } footer: {
                if models.lowMemory {
                    Text("This Mac keeps one large model loaded at a time, so switching features can take a few seconds.")
                }
            }
            SettingsSection("Language model") {
                LanguageModelPicker()
            }
            SettingsSection("For links") {
                LinkToolRow()
            }
            // The documents page is Read aloud's and Summarize's: with both off there is nothing to save for it.
            if LibrarySection.documents.isShown {
                SettingsSection("What is saved for documents") {
                    Toggle(isOn: $keepOriginal) {
                        Text("Keep the original file")
                        Text("The PDF, Word file or a saved copy of the web page, so you can switch to it while reading")
                    }
                    Toggle(isOn: $keepImages) {
                        Text("Keep images")
                        Text("Off: the reading view shows text only")
                    }
                    LabeledContent("Documents use now", value: documentsUse)
                        .id("documents")
                }
            }
        }
        .onAppear {
            models.refresh()
            measureDocuments()
        }
    }

    @AppStorage(DocumentImporter.Keep.originalKey) private var keepOriginal = true
    @AppStorage(DocumentImporter.Keep.imagesKey) private var keepImages = true
    @Environment(AppModel.self) private var app
    @State private var documentsUse = " "

    /// How much room the documents' files take, and how many documents there are.
    private func measureDocuments() {
        let count = (try? Library(store: app.store).count(kind: .document)) ?? 0
        let root = ChirpStore.documentsDirectory
        Task {
            // The folder is walked off the main actor; only the line it makes comes back to the view.
            let size = await Task.detached { () -> String in
                var bytes: Int64 = 0
                if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let url as URL in files { bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
                }
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }.value
            documentsUse = "\(size) · \(count == 1 ? "1 document" : "\(count) documents")"
        }
    }
}

/// The tool Chirp downloads to get the sound from video pages (yt-dlp): its version, and Update and Remove.
/// It sits with the models because it is downloaded and kept the same way.
struct LinkToolRow: View {
    private var links: LinkImporter { LinkImporter.shared }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link tool (yt-dlp)")
                Text("Gets the sound from video pages · about 35 MB · \(state)")
                    .font(.caption).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .gettingTool(let fraction) = links.phase {
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
            } else if links.toolVersion == nil {
                Button("Download") { links.downloadOrUpdateTool() }.disabled(links.isBusy)
            } else {
                Button("Update") { links.downloadOrUpdateTool() }.disabled(links.isBusy)
                Button("Remove") { links.removeTool() }.disabled(links.isBusy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.linkTool")
    }

    /// The grey line's last part: the version, where it stands, or what the last press came to.
    private var state: String {
        if case .gettingTool = links.phase { return "Downloading" }
        if !links.toolNote.isEmpty { return links.toolNote }
        guard let version = links.toolVersion else { return "Not downloaded" }
        return version == "installed" ? "Downloaded" : "Version \(version)"
    }
}

/// One model in the list, with the button or progress that fits its state.
struct ModelRow: View {
    @Environment(ModelCenter.self) private var models
    @Environment(AppModel.self) private var app
    let kind: ModelKind

    var body: some View {
        let state = models.state(kind)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                Text("\(kind.purpose) · \(kind.approximateSize) · \(Self.word(for: state))")
                    .font(.caption).foregroundStyle(Self.failed(state) ? Color.spelling : Color.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .notDownloaded:
                Button("Download") { load() }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
            case .onDisk:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded:
                Button("Unload") { Task { await models.unload(kind) } }
            case .failed(let why):
                Button("Try again") { load() }.help(why)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model.\(kind.rawValue)")
    }

    private static func failed(_ state: ModelState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// The model's state as one word or two, for the grey line under its name.
    private static func word(for state: ModelState) -> String {
        switch state {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading"
        case .onDisk: "Downloaded"
        case .loading: "Loading"
        case .loaded: "In memory"
        case .failed: "Failed"
        }
    }

    /// Downloads the model if needed and loads it; a failure goes to the banner in the Library.
    private func load() {
        Task {
            do { try await models.ensure(kind) } catch { app.report(error, doing: "get \(kind.name)") }
        }
    }
}

/// The open-source work Chirp is built on, shown under Settings › General › About Chirp.
enum AboutSettings {
    /// Every model and library Chirp uses, with its licence. Add to it when one is added.
    static let credits = """
        Chirp is open source under the GPL-3.0 licence.

        Built with:
        • transcribe.cpp by Handy (MIT) — speech recognition engine
        • Parakeet TDT v2 by NVIDIA (CC-BY-4.0) — speech recognition model
        • FluidAudio (Apache-2.0) — voice detection, speaker labels and the voice runtime
        • pyannote speaker-diarization-community-1 (CC-BY-4.0) — speaker labels
        • Silero VAD (MIT) — voice detection
        • Kokoro-82M by hexgrad (Apache-2.0) — voice
        • MLX and mlx-swift-lm by Apple (MIT) — language model runtime
        • Qwen3.5 by Alibaba Cloud (Apache-2.0) — language model
        • Qwen3 0.6B by Alibaba Cloud (Apache-2.0) with the TLDR adapter by phh (Apache-2.0) — summaries
        • bge-small-en-v1.5 by BAAI (MIT) — search embeddings
        • Harper by Automattic (Apache-2.0) — grammar and spelling
        • GRDB.swift (MIT) — storage
        • KeyboardShortcuts by Sindre Sorhus (MIT)
        • Sparkle (MIT) — updates
        • Dictionary matching follows the approach in Handy by CJ Pais (MIT)
        """
}
