import AppKit
import ChirpCore
import ChirpML
import KeyboardShortcuts
import SwiftUI

/// Onboarding: a tour and the setup in one. Each step explains
/// one thing briefly and holds the real control for it, so what is changed here is changed for good.
/// A step for a feature that is switched off is left out. Opened again from Settings › General it shows
/// the current values and resets nothing.
struct OnboardingView: View {
    /// The window's fixed size, which every step is laid out for.
    static let size = CGSize(width: 600, height: 620)

    @Environment(AppModel.self) private var app
    @Environment(ModelCenter.self) private var models
    @Environment(DictationController.self) private var dictation
    @Environment(ReadController.self) private var reader

    @State private var step = OnboardingStep.features
    /// The dictation that was last on screen when the "try it" step opened, so only a new one counts.
    @State private var before = ""

    private var steps: [OnboardingStep] { OnboardingStep.shown(for: Features.shared.set) }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .features: FeaturesStep()
                case .dictation: DictationStep(before: before)
                case .shortcuts: ShortcutsStep()
                case .permissions: PermissionsStep()
                case .models: ModelsStep()
                case .language: LanguageStep()
                case .writing: WritingStep()
                case .notes: NotesStep()
                case .recording: RecordingStep()
                case .reading: ReadingStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 6)
            .id(step)
            .accessibilityIdentifier("onboarding.step.\(step.rawValue)")
            foot
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.ink)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.paper)
        .task {
            // Fetch the speech model without asking: dictation is the first thing the user will try.
            guard Features.shared.set.needs(.speech) else { return }
            _ = try? await models.ensure(.transcription)
            await models.prepareSpeech()
        }
        .onChange(of: step, initial: true) { _, now in
            HomeDebug.onboardingStep = now.rawValue
            dictation.practice = now == .dictation
            if now == .dictation { before = dictation.lastText }
        }
        .onDisappear {
            dictation.practice = false
            HomeDebug.onboardingPress = nil
        }
        .onAppear {
            HomeDebug.onboardingPress = { what in
                switch what {
                case "back": if index > 0 { step = steps[index - 1] }
                case "later": leave()
                default: next()
                }
            }
        }
        // A feature switched off on the first step takes its step away; the one shown stays put.
        .onChange(of: Features.shared.set) { step = OnboardingStep.keep(step, in: steps) }
        .onChange(of: app.onboardingStep, initial: true) { _, wanted in
            if let wanted { step = steps[min(max(wanted, 0), steps.count - 1)] }
        }
    }

    private var foot: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle().fill(i == index ? Color.amber : Color.ink.opacity(0.15)).frame(width: 7, height: 7)
                }
                Text("\(index + 1) of \(steps.count)").font(.system(size: 12)).foregroundStyle(Color.quiet).monospacedDigit().padding(.leading, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(steps.count)")
            Spacer()
            // Every step can be left for later: what it sets is in Settings too.
            if !isLast {
                OnbButton(title: "Later", style: .plain) { leave() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes this. Everything here is also in Settings")
                    .accessibilityIdentifier("onboarding.close")
            }
            if index > 0 { OnbButton(title: "Back") { step = steps[index - 1] }.accessibilityIdentifier("onboarding.back") }
            OnbButton(title: isLast ? (app.onboardingAgain ? "Done" : "Open Chirp") : "Continue", style: .primary) { next() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.next")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func next() {
        if !isLast { step = steps[index + 1] } else { leave() }
    }

    /// Closes onboarding. The first time, it is remembered as done and the Library opens on Home, with
    /// something real on it.
    private func leave() {
        dictation.practice = false
        if reader.item?.source == ReadingStep.sampleSource { reader.dismiss() }
        if app.onboardingAgain { return app.closeOnboarding() }
        FirstData.add(to: app)
        app.finishOnboarding()
        app.section = .home
        AppDelegate.showMain()
    }
}

/// What Home has on it after the first run: one short document about Chirp itself, to listen to,
/// summarize or delete. Added once, only to a library with nothing in it, and only while documents
/// have a page.
@MainActor
enum FirstData {
    static let title = "Welcome to Chirp"
    static let source = "Chirp"

    static func add(to app: AppModel) {
        let library = Library(store: app.store)
        guard Features.shared.set.shows(FeaturePage.documents) else { return }
        let has = ItemKind.allCases.contains { kind in kind != .dictation && ((try? library.count(kind: kind)) ?? 0) > 0 }
        guard !has else { return }
        _ = try? library.save(SavedItem(kind: .document, title: title, body: text, source: source))
        app.libraryVersion += 1
    }

    static var text: String {
        var lines = ["Welcome to Chirp", "", "Chirp lives in the small bar at the bottom of your screen, and in the menu bar. Everything it does stays on this Mac.", ""]
        let on = Features.shared.set
        if on.isOn(.dictate) { lines += ["Dictate", "Hold the right Option key, talk, and let go. Your words are typed where the cursor is. Names it gets wrong go in the Dictionary, and it spells them your way from then on.", ""] }
        if on.isOn(.meetings) { lines += ["Meetings", "When a call starts, Chirp offers to take notes on the meeting: a summary, key points, decisions and the transcript.", ""] }
        if on.isOn(.notes) { lines += ["Notes", "Press Note on the bar, or right Option and N, and type or say an idea. Copy or export it when it is ready to go somewhere.", ""] }
        if on.isOn(.read) { lines += ["Read aloud", "Select text in any app, or stay on a page, and press right Option and L. This document can be read aloud too: press Play below.", ""] }
        if on.isOn(.write) { lines += ["Writing checks", "Spelling and grammar are underlined in the apps you write in. Click an underline for the fix.", ""] }
        if on.isOn(.summarize) { lines += ["Summarize", "Press right Option and U on a page or a selection for its main points. Try it on this document with the Summarize button.", ""] }
        lines += ["This is a document like any other. Delete it when you have read it."]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Pieces shared by the steps

/// A step's top: the bird (on most steps), its title and one grey paragraph.
private struct StepHead<Title: View>: View {
    var bird = true
    let text: String
    @ViewBuilder var title: () -> Title

    var body: some View {
        VStack(spacing: 0) {
            if bird { Bird(mood: .idle, size: 44).frame(width: 44, height: 44).accessibilityHidden(true) }
            HStack(spacing: 8) { title() }
                .font(.system(size: 24, weight: .bold)).tracking(-0.4)
                .multilineTextAlignment(.center)
                .padding(.top, bird ? 8 : 0)
                .accessibilityAddTraits(.isHeader)
            Text(text).foregroundStyle(Color.quiet).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460).padding(.top, 6)
        }
    }
}

/// A group of rows on a rounded surface, as in Settings.
private struct OnbForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Color.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.1), lineWidth: 0.5))
    }
}

/// One row: a symbol where one helps, a name, a grey line under it where the name is not
/// enough, and its control at the right.
private struct OnbRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var help: String?
    /// Every row but a group's first has a hairline above it.
    var first = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(symbol).font(.system(size: 14)).foregroundStyle(Color.quiet).frame(width: 20).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let help { Text(help).font(.system(size: 12)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: help == nil ? 36 : 42)
        .padding(.vertical, help == nil ? 0 : 3)
        .overlay(alignment: .top) { if !first { Rectangle().fill(PageLayout.line).frame(height: 1) } }
    }
}

/// A capsule button of the window: plain grey, the one amber action, or words alone.
private struct OnbButton: View {
    enum Style { case normal, primary, plain }

    let title: String
    var symbol: String?
    var style = Style.normal
    var small = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: small ? 12.5 : 13, weight: style == .primary ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(style == .primary ? Color.onAmber : style == .plain ? Color.quiet : Color.ink.opacity(0.88))
            .padding(.horizontal, small ? 10 : 14).frame(height: small ? 24 : 28)
            .background(style == .primary ? Color.amber : style == .plain ? Color.clear : Color.ink.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A shortcut that can be changed where it is shown: click it and press the new keys.
private struct OnbShortcut: View {
    let name: KeyboardShortcuts.Name
    let label: String
    @State private var version = 0

    var body: some View {
        HStack(spacing: 6) {
            let _ = version
            if ShortcutLayout.needsRightOption(name) {
                Text("right").font(.system(size: 12)).foregroundStyle(Color.quiet).accessibilityHidden(true)
            }
            KeyboardShortcuts.Recorder(for: name) { _ in
                version += 1
                ShortcutLayout.apply()
            }
            .accessibilityLabel(label)
            .accessibilityValue(ShortcutLayout.label(name) ?? "Not set")
        }
    }
}

/// The small grey line at the bottom of a step.
private struct StepNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.quiet).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470).padding(.top, 12)
    }
}

/// A small heading above a group, on its left line.
private struct GroupName: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.quiet)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 2).padding(.top, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension Feature {
    var symbol: String {
        switch self {
        case .dictate: "chirp.dictate"
        case .meetings: "chirp.meeting"
        case .notes: "chirp.note"
        case .read: "chirp.read"
        case .write: "chirp.fix"
        case .summarize: "chirp.summarize"
        }
    }

    /// What it does, in a line, for the first step.
    var blurb: String {
        switch self {
        case .dictate: "Hold a key and speak. The words are typed where your cursor is."
        case .meetings: "Calls and meetings, written down with a summary."
        case .notes: "Type or say an idea; copy or export it later."
        case .read: "Listen to a page, a selection or a document."
        case .write: "Spelling, grammar and rewrites in the apps you write in."
        case .summarize: "The main points of a page, a selection or a document."
        }
    }
}

// MARK: - 1 · What Chirp does, with the six switches

private struct FeaturesStep: View {
    var body: some View {
        let _ = Features.shared.set
        VStack(spacing: 0) {
            StepHead(text: "It works from a small bar at the bottom of your screen, and everything stays on this Mac. Turn off anything you will not use.") {
                Text("Welcome to Chirp")
                if Beta.isOn { BetaTag() }
            }
            OnbForm {
                ForEach(Array(GeneralSettings.featureOrder.enumerated()), id: \.element) { index, feature in
                    OnbRow(symbol: feature.symbol, title: feature.title, help: feature.blurb, first: index == 0) {
                        Toggle(feature.title, isOn: Features.shared.binding(feature)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityIdentifier("onboarding.feature.\(feature.rawValue)")
                    }
                }
            }
            .padding(.top, 16)
            StepNote(text: "A feature that is off is gone everywhere: no buttons, no shortcuts, no model. Change this any time in Settings › General.")
        }
    }
}

// MARK: - 2 · Dictation: try it, and change the key here

private struct DictationStep: View {
    @Environment(DictationController.self) private var dictation
    @Environment(ModelCenter.self) private var models
    let before: String

    /// What was dictated on this step; empty until something new has been said.
    private var spoken: String { dictation.lastText == before ? "" : dictation.lastText }

    var body: some View {
        @Bindable var dictation = dictation
        VStack(spacing: 0) {
            StepHead(bird: false, text: "\(dictation.holdKeyInUse == nil ? "Press it again" : "Let go") when you are done. Your words go where your cursor is. Here, they show below.") {
                // The hold key when there is one (right ⌥ unless changed); else the shortcut, pressed to start and stop.
                if let hold = dictation.holdKeyInUse {
                    Text("Hold")
                    BigKey(text: hold == .rightOption ? "right ⌥" : hold.title)
                } else {
                    Text("Press")
                    BigKey(text: ShortcutLayout.label(.dictate) ?? "the shortcut")
                }
                Text("and say hello")
            }
            VStack(spacing: 10) {
                // The bird in the middle of its wire, which is amber here and moves with the voice.
                ZStack(alignment: .bottom) {
                    Wire(levels: dictation.phase == .recording ? dictation.levels : [], color: Color.amber)
                        .frame(width: 220, height: 22).offset(y: 5)
                    Bird(
                        mood: dictation.phase == .recording ? .listening : dictation.phase == .idle ? .idle : .thinking,
                        level: dictation.phase == .recording ? dictation.levels.last ?? 0 : 0, size: 44
                    )
                    .frame(width: 44, height: 44)
                }
                .frame(width: 220, height: 50)
                Text(status).font(.system(size: spoken.isEmpty || dictation.phase != .idle ? 13 : 16, weight: .medium))
                    .foregroundStyle(spoken.isEmpty || dictation.phase != .idle ? Color.quiet : Color.ink)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("onboarding.spoken")
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.1), lineWidth: 0.5))
            .padding(.top, 16)
            OnbForm {
                OnbRow(title: "Hold to dictate", help: dictation.holdKey == .rightOption ? "Left ⌥ stays free for accents and symbols." : dictation.holdKey == .none ? "Off: dictation starts only from the hands-free shortcut." : nil, first: true) {
                    Picker("Hold to dictate", selection: $dictation.holdKey) {
                        ForEach(HoldKey.allCases) { Text($0 == .rightOption ? "Right ⌥" : $0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("onboarding.holdKey")
                }
                OnbRow(title: "Hands-free", help: "Press once to start a long dictation, again to stop.") {
                    OnbShortcut(name: .dictate, label: "Hands-free dictation")
                }
            }
            .padding(.top, 16)
            if !Permissions.shared.microphoneGranted {
                Text("Chirp cannot hear you yet. Allow the microphone two steps on.").font(.system(size: 12)).foregroundStyle(Color.caution).padding(.top, 12)
            } else if !modelNote.isEmpty {
                StepNote(text: modelNote)
            }
        }
    }

    /// The line in the practice card: what Chirp is doing, then the words it heard.
    private var status: String {
        switch dictation.phase {
        case .recording: "Listening"
        case .transcribing: "Writing it down"
        case .idle: spoken.isEmpty ? "Your words appear here" : spoken
        }
    }

    /// How the speech model is coming along, so a slow first dictation is explained. Empty once it is ready.
    private var modelNote: String {
        switch models.state(.transcription) {
        case .notDownloaded: "Getting the speech model ready."
        case .downloading(let fraction): "Downloading the speech model once: \(Int(fraction * 100))%. After that, dictation works offline."
        case .failed: "The speech model did not download. Check the connection; Chirp tries again when you dictate."
        default: models.speechPrepared ? "" : "The first minute on a new Mac is slower while the speech model settles in."
        }
    }
}

/// A key named in a step's title.
private struct BigKey: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).tracking(0)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Color.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.ink.opacity(0.15)))
    }
}

// MARK: - 3 · The shortcuts, each one changeable

private struct ShortcutsStep: View {
    /// Redrawn when a shortcut is changed, so the keyboard shows the keys in use.
    @State private var version = 0

    /// The shortcuts listed, for the features that are on: (name, shortcut).
    private var rows: [(String, KeyboardShortcuts.Name)] {
        let on = Features.shared.set
        var out: [(String, KeyboardShortcuts.Name)] = []
        if on.isOn(.notes) { out.append(("New note", .recordNote)) }
        if on.isOn(.meetings) { out.append(("Meeting", .recordMeeting)) }
        if on.isOn(.read) { out.append(("Read aloud", .readSelection)) }
        if on.isOn(.summarize) { out.append(("Summarize", .summarize)) }
        if on.isOn(.write) { out.append(("Fix writing", .writePanel)) }
        if on.isOn(.write) { out.append(("Rephrase", .rephrase)) }
        out.append(("Open Library", .openLibrary))
        if on.isOn(.dictate) { out.append(("Type the last dictation again", .pasteLast)) }
        if on.isOn(.write) { out.append(("Fix the sentence", .fixSentence)) }
        return out
    }

    /// The letters the right ⌥ shortcuts use now.
    private var lit: Set<String> {
        Set(rows.compactMap { row in
            guard ShortcutLayout.needsRightOption(row.1), let key = KeyboardShortcuts.getShortcut(for: row.1)?.description.last else { return nil }
            return String(key).uppercased()
        })
    }

    var body: some View {
        let _ = version
        let lit = lit
        VStack(spacing: 0) {
            StepHead(bird: false, text: "Hold right ⌥ and press a letter under your right hand. Click one to change it.") { Text("The other shortcuts") }
            // The right-hand end of the keyboard, with the keys in use lit.
            VStack(spacing: 4) {
                keys(["Y", "U", "I", "O", "P", "[", "]"], lit: lit)
                keys(["H", "J", "K", "L", ";", "'"], lit: lit).padding(.leading, 10)
                keys(["N", "M", ",", ".", "/"], lit: lit).padding(.leading, 28)
                HStack(spacing: 4) {
                    KeyCap(text: "space", on: false, width: 96)
                    KeyCap(text: "⌘", on: false, width: 34)
                    KeyCap(text: "right ⌥", on: true, width: 62)
                    KeyCap(text: "◀", on: false)
                    KeyCap(text: "▶", on: false)
                }
            }
            .padding(.top, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The right-hand keys: right Option with \(lit.sorted().joined(separator: ", "))")
            OnbForm {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    OnbRow(title: row.0, first: index == 0) {
                        OnbShortcut(name: row.1, label: row.0)
                    }
                }
            }
            .padding(.top, 14)
        }
        // A changed shortcut is saved in the preferences; the keyboard above follows.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in version += 1 }
    }

    private func keys(_ letters: [String], lit: Set<String>) -> some View {
        HStack(spacing: 4) { ForEach(letters, id: \.self) { KeyCap(text: $0, on: lit.contains($0)) } }
            .frame(maxWidth: 270, alignment: .leading)
    }
}

/// One key of the small keyboard on the shortcuts step.
private struct KeyCap: View {
    let text: String
    let on: Bool
    var width: CGFloat = 32

    var body: some View {
        Text(text).font(.system(size: 11, weight: on ? .bold : .regular)).foregroundStyle(on ? Color.onAmber : Color.quiet)
            .frame(width: width, height: 28)
            .background(on ? Color.amber : Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 4 · Permissions, with what each is for

private struct PermissionsStep: View {
    @State private var permissions = Permissions.shared
    @State private var calendar = CalendarReader.shared
    @State private var soundFailed = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// One permission as the step shows it.
    private struct Asked: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var why: String
        var granted: Bool
        var label = "Allow"
    }

    /// Only what a feature that is on needs.
    private var asked: [Asked] {
        let on = Features.shared.set
        var out: [Asked] = []
        if on.needs(.speech) { out.append(Asked(id: "microphone", symbol: "chirp.mic", title: "Microphone", why: on.records && on.isOn(.dictate) ? "To hear you dictate and record." : on.records ? "To hear you record." : "To hear you dictate.", granted: permissions.microphoneGranted)) }
        out.append(Asked(id: "accessibility", symbol: "chirp.pointer", title: "Accessibility", why: on.isOn(.write) ? "To type into other apps and check your writing." : "To type into other apps and read what you select.", granted: permissions.accessibility))
        if on.isOn(.meetings) {
            out.append(Asked(
                id: "systemAudio", symbol: "chirp.read", title: "Call audio",
                why: soundFailed ? "Chirp could not hear this Mac. Turn Chirp on under System Audio Recording, then check again."
                    : permissions.checkingSound ? "Playing a chime and listening for it." : "To hear the other side of a meeting.",
                granted: permissions.systemAudioConfirmed, label: permissions.checkingSound ? "Checking" : permissions.systemAudioAsked ? "Sound check" : "Allow"))
            out.append(Asked(id: "calendar", symbol: "chirp.calendar", title: "Calendar", why: "To name meetings and know who is in them.", granted: calendar.allowed))
        }
        if on.records || on.isOn(.read) || on.isOn(.summarize) {
            let why = on.records && (on.isOn(.read) || on.isOn(.summarize)) ? "For the capture button in a recording, and to read the page you are on."
                : on.records ? "For the capture button in a recording." : "To read the page you are on."
            out.append(Asked(
                id: "screen", symbol: "chirp.camera", title: "Screen",
                why: permissions.screenAsked && !permissions.screen ? "Turn Chirp on under Screen & System Audio Recording, then quit and reopen Chirp." : why,
                granted: permissions.screen, label: permissions.screenAsked ? "Open Settings" : "Allow"))
        }
        return out
    }

    var body: some View {
        let asked = asked
        let allowed = asked.filter(\.granted).count
        VStack(spacing: 0) {
            StepHead(text: "Each one is for a single job, and nothing leaves this Mac.") { Text("What Chirp may use") }
            OnbForm {
                ForEach(Array(asked.enumerated()), id: \.element.id) { index, item in
                    OnbRow(symbol: item.symbol, title: item.title, help: item.why, first: index == 0) {
                        if item.granted {
                            HStack(spacing: 4) {
                                Image("chirp.check").font(.system(size: 10, weight: .bold))
                                Text("Allowed").font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.style)
                        } else {
                            if item.id == "systemAudio", soundFailed {
                                OnbButton(title: "Open Settings", small: true) { permissions.openAudioCaptureSettings() }
                            }
                            OnbButton(title: item.label, style: .primary, small: true) { allow(item.id) }
                                .disabled(item.id == "systemAudio" && permissions.checkingSound)
                                .accessibilityLabel("\(item.label) \(item.title)")
                                .accessibilityIdentifier("permission.\(item.id).allow")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("permission.\(item.id)")
                }
            }
            .padding(.top, 16)
            StepNote(text: "\(allowed) of \(asked.count) allowed. Chirp asks again the first time you use something that needs one.")
        }
        .onReceive(timer) { _ in
            permissions.refresh()
            calendar.refresh()
        }
    }

    private func allow(_ id: String) {
        switch id {
        case "microphone": Task { await permissions.requestMicrophone() }
        case "accessibility": permissions.requestAccessibility()
        case "calendar": Task { await calendar.requestAccess() }
        case "screen": permissions.requestScreen()
        default:
            Task {
                if !permissions.systemAudioAsked {
                    // The first capture makes macOS ask. Give the user time to answer before listening.
                    permissions.requestSystemAudio()
                    try? await Task.sleep(for: .seconds(4))
                }
                soundFailed = !(await permissions.soundCheck())
            }
        }
    }
}

// MARK: - 5 · Models: what is downloaded, how big, and what works meanwhile

private struct ModelsStep: View {
    @Environment(ModelCenter.self) private var models
    @Environment(AppModel.self) private var app
    /// The model being fetched from this step, one at a time.
    @State private var fetching: ModelKind?

    /// The models the features that are on need, in the order they are fetched.
    private var kinds: [ModelKind] {
        let on = Features.shared.set
        var out: [ModelKind] = []
        if on.needs(.speech) { out.append(.transcription) }
        if on.needs(.language) { out.append(.language) }
        if on.needs(.voice) { out.append(.voice) }
        if on.needs(.speakers) { out.append(.speakers) }
        out.append(.search)
        return out
    }

    private static func title(_ kind: ModelKind) -> String {
        switch kind {
        case .transcription: "Speech"
        case .language: "Language"
        case .voice: "Reading voice"
        case .speakers: "Speakers"
        case .search: "Search"
        }
    }

    private static func what(_ kind: ModelKind) -> String {
        switch kind {
        case .transcription: "Dictation, voice notes, meetings and audio files."
        case .language: "Summaries, rewrites and meeting notes."
        case .voice: "Reads text aloud."
        case .speakers: "Works out who spoke when, after a meeting."
        case .search: "Finds things by meaning, not only exact words."
        }
    }

    private func megabytes(_ kind: ModelKind) -> Double {
        switch kind {
        case .transcription: 730
        case .language: ModelCenter.languageSize.downloadGB * 1000
        case .voice: 95
        case .speakers: 100
        case .search: 130
        }
    }

    private func ready(_ kind: ModelKind) -> Bool {
        switch models.state(kind) {
        case .onDisk, .loaded, .loading: true
        default: false
        }
    }

    var body: some View {
        let kinds = kinds
        let total = kinds.map(megabytes).reduce(0, +)
        let missing = kinds.filter { !ready($0) }
        VStack(spacing: 0) {
            StepHead(text: "Chirp runs open models on this Mac. They download once: about \(String(format: "%.1f", total / 1000)) GB.") { Text("Getting the models") }
            OnbForm {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    OnbRow(title: "\(Self.title(kind)) · \(kind.approximateSize)", help: Self.what(kind), first: index == 0) {
                        state(kind)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("onboarding.model.\(kind.rawValue)")
                }
            }
            .padding(.top, 16)
            StepNote(text: missing.isEmpty ? "Everything is on this Mac. Chirp works offline from here."
                : "What is ready works now. The rest are ready when their download finishes; you can carry on.")
        }
        .onAppear { models.refresh() }
        // One download at a time, in order; each is put away again once it is on this Mac, so nothing
        // large stays in memory because of this step.
        .task(id: missing.first) {
            // Opened again from Settings it only shows: a missing model is fetched when its button is pressed.
            guard !app.onboardingAgain, let next = missing.first else { return }
            if case .failed = models.state(next) { return }
            await fetch(next)
        }
    }

    /// Downloads one model and puts it away again (the speech model stays, for the dictation step).
    private func fetch(_ kind: ModelKind) async {
        guard fetching == nil, !models.state(kind).isBusy else { return }
        fetching = kind
        defer { fetching = nil }
        do {
            try await models.ensure(kind)
            if kind != .transcription { await models.unload(kind) }
        } catch {
            Log.write("models", "onboarding: \(kind.name) did not download: \(error.localizedDescription)")
        }
    }

    @ViewBuilder private func state(_ kind: ModelKind) -> some View {
        switch models.state(kind) {
        case .onDisk, .loaded, .loading:
            HStack(spacing: 4) {
                Image("chirp.check").font(.system(size: 10, weight: .bold))
                Text("Ready").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.style)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressBar(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(Color.quiet).frame(minWidth: 30, alignment: .trailing)
            }
        case .failed(let why):
            OnbButton(title: "Try again", small: true) { Task { await fetch(kind) } }.help(why)
        case .notDownloaded:
            if app.onboardingAgain {
                OnbButton(title: "Download", small: true) { Task { await fetch(kind) } }.disabled(fetching != nil)
            } else {
                Text("Waiting").foregroundStyle(Color.quiet)
            }
        }
    }
}

// MARK: - 6 · Your language: a first word, a first snippet, the style switches

private struct LanguageStep: View {
    @Environment(AppModel.self) private var app
    @State private var word = ""
    @State private var saidAs = ""
    @State private var cue = ""
    @State private var snippet = ""
    @State private var profile = WritingProfile()
    /// What was just added, said in the field's place for a moment.
    @State private var addedWord: String?
    @State private var addedCue: String?

    var body: some View {
        let on = Features.shared.set
        VStack(spacing: 0) {
            StepHead(text: "Chirp uses these everywhere: dictation, writing checks and reading aloud.") { Text("Your language") }
            if on.shows(FeaturePage.dictionary) {
                GroupName(text: "Dictionary · names and words Chirp should get right")
                OnbForm {
                    HStack(spacing: 8) {
                        TextField("A name or word", text: $word).textFieldStyle(.roundedBorder).accessibilityLabel("Word")
                            .accessibilityIdentifier("onboarding.word")
                        TextField("Said as (optional)", text: $saidAs).textFieldStyle(.roundedBorder).accessibilityLabel("Said as")
                        OnbButton(title: addedWord == nil ? "Add" : "Added", small: true) { addWord() }
                            .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("onboarding.word.add")
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44)
                }
            }
            if on.shows(FeaturePage.snippets) {
                GroupName(text: "Snippets · say or type a short cue, get the saved text")
                OnbForm {
                    HStack(spacing: 8) {
                        TextField("Cue", text: $cue).textFieldStyle(.roundedBorder).frame(width: 150).accessibilityLabel("Cue")
                            .accessibilityIdentifier("onboarding.cue")
                        TextField("The text it stands for", text: $snippet).textFieldStyle(.roundedBorder).accessibilityLabel("Saved text")
                        OnbButton(title: addedCue == nil ? "Add" : "Added", small: true) { addSnippet() }
                            .disabled(cue.trimmingCharacters(in: .whitespaces).isEmpty || snippet.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("onboarding.cue.add")
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44)
                }
            }
            if on.isOn(.dictate) {
                GroupName(text: "Your style · applied to every dictation")
                OnbForm {
                    style("Remove “um” and “uh”", \.removeFillers, first: true)
                    style("Remove stuttered words", \.collapseRepeats)
                    style("Act on “no wait” and “scratch that”", \.handleSelfCorrections)
                    style("“New line” and “new paragraph”", \.spokenLineBreaks)
                    style("Say punctuation aloud", \.spokenPunctuation)
                }
            }
        }
        .onAppear { profile = (try? app.engine.profile()) ?? WritingProfile() }
    }

    private func style(_ title: String, _ path: WritableKeyPath<WritingProfile, Bool>, first: Bool = false) -> some View {
        OnbRow(title: title, first: first) {
            Toggle(title, isOn: Binding(get: { profile[keyPath: path] }, set: { value in
                profile[keyPath: path] = value
                try? app.engine.saveProfile(profile)
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func addWord() {
        let term = word.trimmingCharacters(in: .whitespaces)
        let said = saidAs.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, (try? app.engine.addWord(term, pronunciation: said.isEmpty ? nil : said)) != nil else { return }
        addedWord = term
        word = ""
        saidAs = ""
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            addedWord = nil
        }
    }

    private func addSnippet() {
        let c = cue.trimmingCharacters(in: .whitespaces), text = snippet.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !text.isEmpty, (try? app.engine.save(Snippet(cue: c, text: text))) != nil else { return }
        addedCue = c
        cue = ""
        snippet = ""
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            addedCue = nil
        }
    }
}

// MARK: - 7 · Writing checks: where they show, the key, where they stay out

private struct WritingStep: View {
    @Environment(AppModel.self) private var app
    @Environment(UnderlineController.self) private var underlines

    var body: some View {
        @Bindable var underlines = underlines
        VStack(spacing: 0) {
            StepHead(text: "Underlines appear in the apps you write in. Click one for the fix, or fix the whole sentence with one key.") { Text("Writing checks") }
            // A sentence as it looks in another app: a grammar slip, a misspelling, and the fix on one key.
            VStack(alignment: .trailing, spacing: 8) {
                // Drawn as Chirp draws underlines: grammar solid, spelling wavy, style dashed.
                UnderlineSample(
                    text: "Thanks for the notes. I has one question about the shedule for April, at this point in time.",
                    marks: [("has", .grammar), ("shedule", .spelling), ("at this point in time", .style)])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement()
                    .accessibilityLabel("An example: Thanks for the notes. I has one question about the shedule for April, at this point in time. Has has a straight blue line for grammar, shedule a wavy red line for spelling, and at this point in time a dashed green line for style.")
                HStack(spacing: 6) {
                    Bird(mood: .idle, size: 18).frame(width: 18, height: 18).accessibilityHidden(true)
                    Text("Fix this sentence").font(.system(size: 12.5))
                    Text(ShortcutLayout.label(.fixSentence, short: true) ?? "").font(.system(size: 11)).foregroundStyle(Color.quiet)
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.float, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.ink.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.14), lineWidth: 0.5))
            .padding(.top, 16)
            OnbForm {
                OnbRow(title: "Underlines in other apps", help: "A wavy red line for spelling, a straight blue line for grammar, a dashed green line for style.", first: true) {
                    Toggle("Underlines in other apps", isOn: $underlines.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("onboarding.underlines")
                }
                // The small bird at a sentence's end and ⌥⇥; the key shown is the one in use.
                OnbRow(title: "Fix the sentence", help: "Fixes everything in the sentence your cursor is in.") {
                    OnbShortcut(name: .fixSentence, label: "Fix the sentence")
                }
                OnbRow(title: "Stays out of", help: "Terminal, Xcode, password fields") {
                    OnbButton(title: "Edit", small: true) {
                        app.section = .style
                        AppDelegate.showMain()
                    }
                    .accessibilityLabel("Edit the apps Chirp stays out of")
                    .accessibilityHint("Opens Writing style in the Library")
                }
            }
            .padding(.top, 16)
            StepNote(text: "Chirp helps with your own words. It never writes for you.")
        }
    }
}

// MARK: - 8 · Recording: a voice note or a meeting

private struct RecordingStep: View {
    @Environment(MeetingDetector.self) private var detector
    @State private var calendar = CalendarReader.shared
    @AppStorage(RecordingSound.key) private var macSound = true

    var body: some View {
        @Bindable var detector = detector
        @Bindable var calendar = calendar
        VStack(spacing: 0) {
            StepHead(text: "Chirp offers to take notes when a call starts. You can also start one yourself.") { Text("Meetings") }
            OnbKindCard(symbol: "chirp.meeting", title: "A meeting", what: "Summary, key points, decisions, and the transcript with speakers.",
                        how: "Chirp offers when one starts, or Record a meeting on the perch, or", key: .recordMeeting)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            OnbForm {
                OnbRow(title: "Offer to take notes when a call starts", first: true) {
                    Toggle("Offer to take notes when a call starts", isOn: $detector.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                OnbRow(title: "Offer for meetings on my calendar") {
                    Toggle("Offer for meetings on my calendar", isOn: $calendar.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                OnbRow(title: "Include this Mac’s sound", help: "The other side of a call.") {
                    Toggle("Include this Mac’s sound", isOn: $macSound).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            .padding(.top, 16)
            StepNote(text: "During a meeting, type a note and press Return to mark the moment, or press the capture button for a picture of the window in front.")
        }
    }
}

// MARK: - 8 · Notes (left out when Notes is off)

private struct NotesStep: View {
    @Environment(MeetingRecorder.self) private var recorder
    @State private var checks = NoteController.checksWriting

    var body: some View {
        @Bindable var recorder = recorder
        VStack(spacing: 0) {
            StepHead(text: "A quick place for an idea. Type it, or hold right ⌥ and say it. Copy or export it when it is ready to go somewhere.") { Text("Notes") }
            HStack(alignment: .top, spacing: 10) {
                OnbKindCard(symbol: "chirp.note", title: "A note", what: "Opens in the perch. Headings, lists and code look formatted as you type.",
                            how: "Note on the perch, or", key: .recordNote)
                OnbKindCard(symbol: "chirp.voiceNote", title: "A voice note", what: "For talking at length. The audio is kept, and its text is a note you can edit.",
                            how: "Record a voice note, in a note or on the Notes page", key: nil)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            OnbForm {
                OnbRow(title: "Check writing in notes", first: true) {
                    Toggle("Check writing in notes", isOn: $checks).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: checks) { _, on in NoteController.checksWriting = on }
                        .disabled(!Features.on(.write))
                }
                OnbRow(title: "Keep a voice note’s audio") {
                    Toggle("Keep a voice note’s audio", isOn: $recorder.keepNoteAudio).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            .padding(.top, 16)
            StepNote(text: "Closing a note saves it to Notes in the Library.")
        }
    }
}

/// One kind of thing a step introduces: its name, what it is, and how to start it.
private struct OnbKindCard: View {
    let symbol: String
    let title: String
    let what: String
    let how: String
    let key: KeyboardShortcuts.Name?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(symbol).font(.system(size: 14)).foregroundStyle(Color.quiet).accessibilityHidden(true)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            Text(what).font(.system(size: 12.5)).foregroundStyle(Color.quiet).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(how).font(.system(size: 12)).foregroundStyle(Color.quiet)
                if let key { OnbShortcut(name: key, label: title) }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.ink.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - 9 · Reading and summaries, then into the app

private struct ReadingStep: View {
    @Environment(ReadController.self) private var reader
    /// What the reader is told a voice sample came from, so it can be told from a real document.
    static let sampleSource = "Voice sample"

    var body: some View {
        @Bindable var reader = reader
        let on = Features.shared.set
        VStack(spacing: 0) {
            StepHead(text: on.isOn(.read) && on.isOn(.summarize) ? "Listen instead of reading, or get the main points first." : on.isOn(.read) ? "Listen instead of reading." : "Get the main points first.") {
                Text(on.isOn(.read) && on.isOn(.summarize) ? "Reading and summaries" : on.isOn(.read) ? "Reading aloud" : "Summaries")
            }
            OnbForm {
                if on.isOn(.read) {
                    OnbRow(symbol: "chirp.read", title: "Read aloud", help: "Select text, or stay on a page.", first: true) {
                        OnbShortcut(name: .readSelection, label: "Read aloud")
                    }
                    OnbRow(title: "Voice") {
                        OnbButton(title: reader.isPlaying || reader.isPreparing ? "Stop" : "Hear it", symbol: reader.isPlaying || reader.isPreparing ? "chirp.stop" : "chirp.play", small: true) {
                            if reader.isPlaying || reader.isPreparing { reader.dismiss() } else {
                                reader.readOnce(DocumentImporter.Imported(title: "Voice sample", text: "This is how I sound when I read to you.", source: Self.sampleSource))
                            }
                        }
                        .accessibilityIdentifier("onboarding.hear")
                        Picker("Voice", selection: $reader.voiceID) {
                            ForEach(Voice.voices) { v in Text(v.name).tag(v.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                if on.isOn(.summarize) {
                    OnbRow(symbol: "chirp.summarize", title: "Summarize", help: "Select text, or stay on a page.", first: !on.isOn(.read)) {
                        OnbShortcut(name: .summarize, label: "Summarize")
                    }
                }
                OnbRow(symbol: "chirp.drop", title: "Drop a file on the perch", help: "To read it, summarize it or keep it in the Library.") { EmptyView() }
            }
            .padding(.top, 16)
            StepNote(text: "See this again any time from Settings › General.")
        }
    }
}

/// Settings › Recording › "Include this Mac's sound": whether the other side of a call is recorded
/// when Chirp records one. On unless switched off. The switch in a recording's own panel still adds or
/// removes it for that recording.
enum RecordingSound {
    static let key = "recordIncludeMacSound"
    static var include: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
