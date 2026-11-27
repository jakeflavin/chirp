import ChirpCore
import SwiftUI

// MARK: - Dictionary

/// The user's own words: names and terms Chirp should spell, accept and say their way.
struct DictionaryView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var editing: DictionaryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Add a name or term, e.g. Kubernetes", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(add)
                    .accessibilityLabel("A name or term to add")
                    .accessibilityIdentifier("dictionary.newTerm")
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("dictionary.add")
            }
            .padding(.top, 16)
            SectionHeading("Words", count: entries.count)
            if entries.isEmpty {
                EmptyLine("No words yet. Add a name or term above.")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        DictionaryRow(entry: entry) { editing = entry } toggle: { toggle(entry) }
                            .contextMenu {
                                Button("Edit…") { editing = entry }
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
            }
            .padding(.horizontal, -10)
            .accessibilityIdentifier("dictionary.list")
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, PageLayout.gutter)
        .onAppear(perform: reload)
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { saved in
                try? app.engine.save(saved)
                reload()
            } delete: {
                delete(entry)
            }
        }
    }

    private func reload() { entries = (try? app.engine.dictionary(includeDisabled: true)) ?? [] }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        do {
            try app.engine.addWord(term)
            newTerm = ""
            reload()
        } catch { app.report(error, doing: "add the word") }
    }

    private func toggle(_ entry: DictionaryEntry) {
        var e = entry
        e.enabled.toggle()
        try? app.engine.save(e)
        reload()
    }

    private func delete(_ entry: DictionaryEntry) {
        try? app.engine.delete(entry)
        reload()
    }
}

/// One word in the dictionary, with what it is heard as and said as, and a switch to stop using it.
struct DictionaryRow: View {
    let entry: DictionaryEntry
    let edit: () -> Void
    let toggle: () -> Void

    var body: some View {
        ItemRow(title: entry.term, meta: meta, alwaysShowActions: true) {
            HStack(spacing: 8) {
                ActButton(title: "Edit", action: edit).accessibilityLabel("Edit \(entry.term)")
                Toggle("On", isOn: .init(get: { entry.enabled }, set: { _ in toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Use \(entry.term)")
            }
        }
        .opacity(entry.enabled ? 1 : 0.55)
    }

    /// The grey line: how it is heard and said, and where it came from when Chirp learned it.
    private var meta: String {
        var parts: [String] = []
        if !entry.soundsLike.isEmpty { parts.append("Heard as " + entry.soundsLike.joined(separator: ", ")) }
        if let p = entry.pronunciation, !p.isEmpty { parts.append("Said as " + p) }
        if entry.origin == .learned { parts.append(entry.originNote.flatMap { $0.isEmpty ? nil : $0 } ?? "Learned") }
        return parts.isEmpty ? "Added by you" : parts.joined(separator: " · ")
    }
}

/// The sheet for changing a word's spelling, what speech recognition mishears it as, and how it is said.
struct DictionaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: DictionaryEntry
    /// The "heard as" list as one comma-separated line while it is being typed.
    @State private var soundsLike = ""
    let save: (DictionaryEntry) -> Void
    /// Takes the word out of the dictionary. Here as well as on a right-click, like a snippet's.
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit word").font(.sectionTitle)
            Form {
                TextField("Spelling", text: $entry.term)
                TextField("Heard as", text: $soundsLike, prompt: Text("cooper netties, kuber nettys"))
                TextField(
                    "Said as", text: .init(get: { entry.pronunciation ?? "" }, set: { entry.pronunciation = $0.isEmpty ? nil : $0 }),
                    prompt: Text("How the voice should say it"))
            }
            Text("“Heard as” lists what speech recognition tends to write instead. Separate with commas.")
                .font(.rowMeta).foregroundStyle(Color.quiet)
            HStack {
                Button("Delete", role: .destructive) {
                    delete()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    entry.soundsLike = soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    save(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { soundsLike = entry.soundsLike.joined(separator: ", ") }
    }
}

// MARK: - Snippets

/// Saved pieces of text, each typed out when its spoken cue is said while dictating.
struct SnippetsView: View {
    @Environment(AppModel.self) private var app
    @State private var snippets: [Snippet] = []
    @State private var editing: Snippet?
    /// The snippet Delete… is asking about.
    @State private var deleting: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Snippets", count: snippets.count) {
                HeadingLink(title: "New snippet") { editing = Snippet(cue: "", text: "") }
                    .accessibilityIdentifier("snippets.new")
            }
            if snippets.isEmpty {
                EmptyLine("No snippets yet.") { Button("New snippet") { editing = Snippet(cue: "", text: "") } }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(snippets) { s in
                        ItemRow(title: s.cue, meta: s.text.replacingOccurrences(of: "\n", with: " "), alwaysShowActions: true) {
                            ActButton(title: "Edit") { editing = s }.accessibilityLabel("Edit the snippet \(s.cue)")
                        }
                        .contextMenu { Button("Delete…", role: .destructive) { deleting = s } }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
                // Adding a snippet is hard to find otherwise: the four ways, shown.
                SnippetWays().padding(.horizontal, 10).padding(.bottom, 24)
            }
            .padding(.horizontal, -10)
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, PageLayout.gutter)
        .onAppear(perform: reload)
        .confirmationDialog(
            deleting.map { "Delete the snippet “\($0.cue)”?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = deleting { delete(s) }
                deleting = nil
            }
        } message: {
            Text("Saying its cue no longer types it.")
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { saved, delete in
                if delete { try? app.engine.delete(saved) } else { try? app.engine.save(saved) }
                reload()
            }
        }
    }

    private func reload() { snippets = (try? app.engine.snippets(includeDisabled: true)) ?? [] }
    private func delete(_ s: Snippet) {
        try? app.engine.delete(s)
        reload()
    }
}

/// "Ways to add one", under the list of snippets: here, from selected text, from a dictation, and when
/// something is said often. Each is a title, a line, and a small picture of
/// where it is found.
struct SnippetWays: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Ways to add one")
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    way("Here", "New snippet, above. Give it a cue and the text.") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spoken cue, e.g. my email")
                            Rectangle().fill(PageLayout.line).frame(height: 1)
                            Text("Text to insert")
                        }
                        .foregroundStyle(Color.quiet.opacity(0.8)).padding(.horizontal, 5).padding(.vertical, 4)
                    }
                    way("From selected text", "In any app: the perch’s More menu, or the rewrite panel.") {
                        menuRows(["Rephrase…", "Save as a Snippet…", "Style in Mail: Formal"], chosen: 1)
                    }
                    way("From a dictation", "Its menu on the Dictations page.") {
                        menuRows(["Copy", "Play", "Save as a Snippet…"], chosen: 2)
                    }
                    way("When you repeat yourself", "Chirp suggests it on Dictations. Nothing is saved without you.") {
                        HStack(spacing: 7) {
                            Bird(mood: .idle, size: 18).accessibilityHidden(true)
                            Text("“Thanks, talk soon.” four times").lineLimit(2)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func way<Mini: View>(_ title: String, _ line: String, @ViewBuilder mini: () -> Mini) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
            Text(line).font(.system(size: 12)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            mini()
                .font(.system(size: 12)).foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .background(Color.float, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PageLayout.line))
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PageLayout.line))
        .accessibilityElement(children: .combine)
    }

    /// A few rows of a menu, one of them picked out.
    private func menuRows(_ rows: [String], chosen: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Text(row).lineLimit(1).padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(index == chosen ? Color.amber.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }
}

/// The sheet for writing a new snippet or changing one: its spoken cue and the text to type.
struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet
    /// Called with the snippet and whether to delete it (true) or save it (false).
    let done: (Snippet, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.id == nil ? "New snippet" : "Edit snippet").font(.sectionTitle)
            TextField("Spoken cue, e.g. my email", text: $snippet.cue)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snippet.cue")
            TextEditor(text: $snippet.text)
                // Chirp never offers Apple's Writing Tools: its own models do that work.
                .writingToolsBehavior(.disabled)
                .font(.body)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.15)))
                .accessibilityLabel("Text to insert")
                .accessibilityIdentifier("snippet.text")
            HStack {
                if snippet.id != nil {
                    Button("Delete", role: .destructive) {
                        done(snippet, true)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    done(snippet, false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.cue.trimmingCharacters(in: .whitespaces).isEmpty || snippet.text.isEmpty)
                .accessibilityIdentifier("snippet.save")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Writing profile

/// How the user writes (spelling, tone, style notes) and how dictated speech is tidied. Saved as it changes.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @State private var profile = WritingProfile()
    /// False until the saved profile has been read, so the placeholder shown first is never saved over it.
    @State private var loaded = false

    var body: some View {
        Form {
            SettingsSection("How you write") {
                Picker("Spelling", selection: $profile.spelling) {
                    Text("American").tag(WritingProfile.Spelling.american)
                    Text("British").tag(WritingProfile.Spelling.british)
                }
                Picker("Usual tone", selection: $profile.formality) {
                    Text("Casual").tag(Formality.casual)
                    Text("Neutral").tag(Formality.neutral)
                    Text("Formal").tag(Formality.formal)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes on your style")
                    Text("For example: short sentences, no exclamation marks").font(.rowMeta).foregroundStyle(Color.quiet)
                    TextEditor(text: $profile.styleNotes)
                        // Chirp never offers Apple's Writing Tools: its own models do that work.
                        .writingToolsBehavior(.disabled)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.12)))
                        .accessibilityLabel("Notes on your style")
                        .accessibilityIdentifier("profile.notes")
                }
            }
            SettingsSection("When you dictate") {
                Toggle("Remove “um” and “uh”", isOn: $profile.removeFillers)
                Toggle("Remove stuttered words", isOn: $profile.collapseRepeats)
                Toggle("Act on “no wait” and “scratch that”", isOn: $profile.handleSelfCorrections)
                Toggle("“New line” and “new paragraph” make line breaks", isOn: $profile.spokenLineBreaks)
                Toggle("Say punctuation aloud (“comma”, “question mark”)", isOn: $profile.spokenPunctuation)
            }
        }
        .settingsForm()
        .onAppear {
            profile = (try? app.engine.profile()) ?? WritingProfile()
            loaded = true
        }
        .onChange(of: profile) { _, new in
            guard loaded else { return }
            do { try app.engine.saveProfile(new) } catch { app.report(error, doing: "save your profile") }
        }
    }
}

// MARK: - Per-app styles

/// The tone to use, and whether to underline, in each app the user has added.
struct AppStylesView: View {
    @Environment(AppModel.self) private var app
    @State private var styles: [AppStyle] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Apps", count: styles.count) {
                Menu("Add app") {
                    ForEach(runningApps(), id: \.bundleID) { a in
                        Button(a.name) { add(bundleID: a.bundleID, name: a.name) }
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.quiet)
                .help("Pick from the apps that are open now")
            }
            if styles.isEmpty {
                EmptyLine("No apps yet. Apps not listed use your usual tone.")
            }
            Text("The switch is underlines in that app. Other apps use your usual tone. Change the app in front from the perch’s More menu or the menu bar.")
                .font(.system(size: 12)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(styles) { style in
                        ItemRow(
                            title: style.appName,
                            meta: "\(style.formality.rawValue.capitalized) tone · underlines \(style.underlinesEnabled ? "on" : "off")",
                            alwaysShowActions: true
                        ) {
                            HStack(spacing: 10) {
                                Picker("Tone", selection: binding(style, \.formality)) {
                                    Text("Casual").tag(Formality.casual)
                                    Text("Neutral").tag(Formality.neutral)
                                    Text("Formal").tag(Formality.formal)
                                }
                                .labelsHidden().frame(width: 104)
                                .accessibilityLabel("Tone in \(style.appName)")
                                Toggle("Underlines", isOn: binding(style, \.underlinesEnabled))
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("Underlines in \(style.appName)")
                                ActButton(title: "Remove") {
                                    try? app.engine.delete(style)
                                    reload()
                                }
                                .accessibilityLabel("Remove \(style.appName)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
            }
            .padding(.horizontal, -10)
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, PageLayout.gutter)
        .onAppear(perform: reload)
    }

    private func reload() { styles = (try? app.engine.appStyles()) ?? [] }

    /// A binding to one setting of an app's style that saves the change at once and marks the style as
    /// set by hand.
    private func binding<V>(_ style: AppStyle, _ keyPath: WritableKeyPath<AppStyle, V>) -> Binding<V> {
        Binding(
            get: { style[keyPath: keyPath] },
            set: { value in
                var s = style
                s[keyPath: keyPath] = value
                s.origin = .manual
                try? app.engine.save(s)
                reload()
            })
    }

    private func add(bundleID: String, name: String) {
        try? app.engine.save(AppStyle(bundleID: bundleID, appName: name))
        reload()
    }

    /// The apps open now that have no style yet, by name, for the "Add app" menu.
    private func runningApps() -> [(bundleID: String, name: String)] {
        let known = Set(styles.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in
                guard let id = a.bundleIdentifier, let name = a.localizedName, !known.contains(id),
                    id != Bundle.main.bundleIdentifier
                else { return nil }
                return (id, name)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Learned

/// Everything Chirp picked up on its own, with where it came from, and a way to remove it.
struct LearnedView: View {
    @Environment(AppModel.self) private var app
    @State private var words: [DictionaryEntry] = []
    @State private var rules: [DismissedRule] = []
    @State private var confirmForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("Words learned from your corrections", count: words.count) {
                    HStack(spacing: 14) {
                        HeadingLink(title: "Export…", action: export)
                        HeadingLink(title: "Forget everything") { confirmForget = true }
                            .disabled(words.isEmpty && rules.isEmpty)
                            .opacity(words.isEmpty && rules.isEmpty ? 0.5 : 1)
                    }
                }
                // What "learned" is made from, and when it changes.
                Text("Words you fixed after a misheard dictation. Updates each time you fix one.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.quiet).padding(.bottom, 4)
                if words.isEmpty { EmptyLine("Nothing learned yet. Fix a misheard word in a dictation and it shows here.") }
                ForEach(words) { w in
                    ItemRow(
                        title: w.term,
                        meta: [w.soundsLike.isEmpty ? nil : "Heard as " + w.soundsLike.joined(separator: ", "), w.originNote, w.createdAt.shortRelative]
                            .compactMap { $0 }.joined(separator: " · "),
                        alwaysShowActions: true
                    ) {
                        ActButton(title: "Forget") {
                            try? app.engine.delete(w)
                            reload()
                        }
                        .accessibilityLabel("Forget \(w.term)")
                    }
                }
                SectionHeading("Suggestions you dismissed", count: rules.count)
                if rules.isEmpty { EmptyLine("None dismissed.") }
                ForEach(rules) { r in
                    ItemRow(title: r.text.map { "“\($0)”" } ?? "All of this kind", meta: "\(r.ruleKey) · \(r.createdAt.shortRelative)", alwaysShowActions: true) {
                        ActButton(title: "Show again") {
                            try? app.engine.delete(r)
                            reload()
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, PageLayout.gutter).padding(.bottom, 24)
        }
        .onAppear(perform: reload)
        .confirmationDialog("Forget everything Chirp learned?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                try? app.engine.forgetLearned()
                reload()
            }
        } message: {
            Text("Words and settings you entered yourself are kept.")
        }
    }

    private func reload() {
        words = ((try? app.engine.dictionary(includeDisabled: true)) ?? []).filter { $0.origin == .learned }
        rules = (try? app.engine.dismissedRules()) ?? []
    }

    /// Saves the user's profile, words, snippets, app styles and dismissed suggestions to a file they
    /// choose, to keep or to look through.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Chirp profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(try app.engine.export()).write(to: url)
        } catch { app.report(error, doing: "export your profile") }
    }
}
