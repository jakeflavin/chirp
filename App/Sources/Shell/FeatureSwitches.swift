import ChirpCore
import KeyboardShortcuts
import Observation
import SwiftUI

/// The six feature switches (Settings › General › Features): the one place that says which features
/// are on. A feature that is off is gone everywhere and does nothing: its buttons, pages and shortcuts
/// leave, its background work stops and its model is unloaded. What it saved is kept, and everything
/// returns when it is switched back on, without relaunching.
@MainActor
@Observable
final class Features {
    static let shared = Features()

    /// Which features are on. Saved in the app's preferences, one key per feature.
    private(set) var set: FeatureSet
    /// What each part of the app does when the switches change: stop its work, or start it again.
    @ObservationIgnored private var handlers: [(_ old: FeatureSet, _ new: FeatureSet) -> Void] = []
    /// What each part of the app says about its background work, for the test state.
    @ObservationIgnored private var probes: [String: () -> Any] = [:]
    /// Unloads the models nothing needs any more, once whatever was using them has finished.
    @ObservationIgnored private var unloader: Task<Void, Never>?

    /// Whether a feature is on. Reading it in a view keeps the view up to date.
    static func on(_ feature: Feature) -> Bool { shared.set.isOn(feature) }

    private init() {
        set = FeatureSet { UserDefaults.standard.object(forKey: $0) as? Bool }
        // TESTING: `chirp://debug/features?dictate=0&notes=1` (`record` is Meetings and Notes together) switches features as the Settings switches
        // do (`all=0` or `all=1` for every one); `state` lists them under `features`.
        LinkHandler.commands["features"] = { [weak self] q in
            guard let self else { return }
            self.change(to: self.set.applying(q))
        }
        LinkHandler.stateProviders["features"] = { [weak self] in
            guard let self else { return [:] }
            var out: [String: Any] = self.set.state
            out["shortcutsOff"] = Self.shortcuts.filter { !self.set.isOn($0.key) }.flatMap { $0.value.map(\.rawValue) }.sorted()
            out["shortcutsAnswering"] = Self.shortcuts.values.joined().filter { KeyboardShortcuts.isEnabled(for: $0) }.map(\.rawValue).sorted()
            out["needs"] = Dictionary(uniqueKeysWithValues: FeatureModel.allCases.map { ($0.rawValue, self.set.needs($0)) })
            out["background"] = self.probes.mapValues { $0() }
            return out
        }
    }

    /// A switch for one feature, for Settings.
    func binding(_ feature: Feature) -> Binding<Bool> {
        Binding(get: { self.set.isOn(feature) }, set: { self.turn(feature, on: $0) })
    }

    func turn(_ feature: Feature, on: Bool) {
        var next = set
        next.set(feature, on)
        change(to: next)
    }

    /// Saves the switches and has every part of the app follow them.
    func change(to next: FeatureSet) {
        let old = set
        guard next != old else { return }
        for feature in Feature.allCases { UserDefaults.standard.set(next.isOn(feature), forKey: feature.settingsKey) }
        set = next
        Log.write("features", "on: \(next.ordered.map(\.rawValue).joined(separator: ", "))")
        apply(from: old)
    }

    /// Registers what a part of the app does when the switches change. It is run with the old and the
    /// new set; a feature that is busy is stopped cleanly there first.
    func whenChanged(_ run: @escaping (_ old: FeatureSet, _ new: FeatureSet) -> Void) { handlers.append(run) }

    /// Registers a value for the test state's `features.background`.
    func probe(_ name: String, _ value: @escaping () -> Any) { probes[name] = value }

    /// Once at launch, after every controller exists: features saved as off are put away.
    func applyAtLaunch() {
        if set != .all { apply(from: .all) }
    }

    private func apply(from old: FeatureSet) {
        for handler in handlers { handler(old, set) }
        applyShortcuts()
        unloadWhatNothingNeeds()
    }

    // MARK: Shortcuts

    /// Each feature's global shortcuts. One that is off is unregistered, so its keys go to the app in front.
    static let shortcuts: [Feature: [KeyboardShortcuts.Name]] = [
        .dictate: [.dictate, .pasteLast],
        .meetings: [.recordMeeting],
        .notes: [.recordNote],
        .read: [.readSelection],
        .write: [.writePanel, .rephrase, .fixSentence],
        .summarize: [.summarize],
    ]

    private func applyShortcuts() {
        // The sentence shortcut is switched on only while a fix is on offer (see SentenceFixer), and the
        // right Option ones only while that key is down (see ShortcutLayout).
        if !set.isOn(.write) { KeyboardShortcuts.disable(.fixSentence) }
        ShortcutLayout.apply()
    }

    // MARK: Models

    private static func kind(_ model: FeatureModel) -> ModelKind {
        switch model {
        case .speech: .transcription
        case .language: .language
        case .voice: .voice
        case .speakers: .speakers
        }
    }

    /// Unloads each model that no feature still on needs. A model in use (a recording being saved, notes
    /// being written) is left until that is done, then unloaded. Nothing loads it again while its
    /// features are off, because nothing of theirs runs.
    private func unloadWhatNothingNeeds() {
        unloader?.cancel()
        unloader = Task { [weak self] in
            // At most half an hour of looking: long notes for a long meeting finish well inside that.
            for _ in 0..<900 {
                guard let self, !Task.isCancelled, let models = AppDelegate.models else { return }
                var waiting = false
                for model in FeatureModel.allCases where !self.set.needs(model) {
                    let kind = Self.kind(model)
                    if models.state(kind).isBusy { waiting = true }
                    guard models.state(kind) == .loaded else { continue }
                    var held = models.isInUse(kind)
                    if model == .speech {
                        let holds = await models.transcriber.holds
                        held = holds > 0
                    }
                    if held || self.busy {
                        waiting = true
                    } else {
                        await models.unload(kind)
                        Log.write("features", "\(kind.rawValue) model unloaded: no feature that is on needs it")
                    }
                }
                if !waiting { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// True while something a switched-off feature began is still finishing (a recording being saved).
    private var busy: Bool { probes.contains { $0.key.hasSuffix(".finishing") && ($0.value() as? Bool) == true } }
}

extension View {
    /// Leaves the view out while a feature is switched off.
    @ViewBuilder func shown(with feature: Feature) -> some View {
        if Features.on(feature) { self }
    }
}

/// The one line at the top of a feature's Settings tab while the feature is switched off, with a button
/// to the switches.
struct FeatureOffNote: View {
    let feature: Feature
    @Environment(AppModel.self) private var app

    var body: some View {
        if !Features.on(feature) {
            HStack(spacing: 8) {
                Image("chirp.power").foregroundStyle(Color.quiet).accessibilityHidden(true)
                Text("\(feature.title) is switched off.").foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                Button("Open General") { app.settingsTab = .general }
                    .accessibilityLabel("Open General settings to switch \(feature.title) on")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}
