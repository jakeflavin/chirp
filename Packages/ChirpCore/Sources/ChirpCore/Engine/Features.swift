import Foundation

/// One of Chirp's six main features. Each can be switched off in Settings › General; what belongs to
/// it (attachments with Meetings; Fix and Rephrase with Writing checks) goes with it. Meetings and Notes
/// were once one switch, "Record": a saved "Record" switch is read for both.
public enum Feature: String, CaseIterable, Identifiable, Sendable {
    case dictate, meetings, notes, read, write, summarize

    public var id: String { rawValue }

    /// Its name as shown beside its switch.
    public var title: String {
        switch self {
        case .dictate: "Dictate"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .read: "Read aloud"
        case .write: "Writing checks"
        case .summarize: "Summarize"
        }
    }

    /// Where its switch is saved.
    public var settingsKey: String { "feature." + rawValue }

    /// Where the one switch Meetings and Notes shared was saved; read for either while it has no switch of its own.
    public static let oldRecordKey = "feature.record"
}

/// A model more than one feature can need.
public enum FeatureModel: String, CaseIterable, Sendable {
    case speech, language, voice, speakers, search
}

/// A page of the Library that exists for one or more features.
public enum FeaturePage: String, CaseIterable, Sendable {
    case meetings, voiceNotes, dictations, documents, dictionary, snippets, style
}

/// What can be done with a document dropped on the perch.
public enum DropOffer: String, CaseIterable, Sendable {
    case read, summarize, record
}

/// Which features are switched on, and what follows from that. All are on unless switched off.
public struct FeatureSet: Equatable, Sendable {
    public private(set) var on: Set<Feature>

    public static let all = FeatureSet(on: Set(Feature.allCases))
    public static let none = FeatureSet(on: [])

    public init(on: Set<Feature>) { self.on = on }

    /// Reads the saved switches. A feature never saved is on. Meetings and Notes each take the old
    /// "Record" switch until they have been saved themselves.
    public init(read: (String) -> Bool?) {
        on = Set(Feature.allCases.filter { feature in
            if let saved = read(feature.settingsKey) { return saved }
            if feature == .meetings || feature == .notes, let old = read(Feature.oldRecordKey) { return old }
            return true
        })
    }

    public func isOn(_ feature: Feature) -> Bool { on.contains(feature) }

    public mutating func set(_ feature: Feature, _ isOn: Bool) {
        if isOn { on.insert(feature) } else { on.remove(feature) }
    }

    /// The features in their usual order, for anything that lists them.
    public var ordered: [Feature] { Feature.allCases.filter(isOn) }

    /// The set after a test link's arguments: `dictate=0&notes=1`, and `all=0` or `all=1` for every
    /// feature at once (a named feature wins over `all`). `record` sets Meetings and Notes together, as
    /// the old switch did. Anything else is ignored.
    public func applying(_ query: [String: String]) -> FeatureSet {
        var next = self
        if let all = query["all"].flatMap(Self.flag) {
            for feature in Feature.allCases { next.set(feature, all) }
        }
        if let record = query["record"].flatMap(Self.flag) {
            next.set(.meetings, record)
            next.set(.notes, record)
        }
        for feature in Feature.allCases {
            if let value = query[feature.rawValue].flatMap(Self.flag) { next.set(feature, value) }
        }
        return next
    }

    private static func flag(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "on", "yes": true
        case "0", "false", "off", "no": false
        default: nil
        }
    }

    /// Each feature by name, for the test state.
    public var state: [String: Bool] {
        Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0.rawValue, isOn($0)) })
    }

    /// Whether a feature that is on needs this model. A model nothing needs is unloaded and stays so.
    /// Dictate and Notes do not use the language model: what is said is cleaned up by rule, and Chirp
    /// never writes into a note.
    public func needs(_ model: FeatureModel) -> Bool {
        switch model {
        case .speech: isOn(.dictate) || isOn(.meetings) || isOn(.notes)
        case .language: isOn(.meetings) || isOn(.write) || isOn(.summarize)
        case .voice: isOn(.read)
        case .speakers: isOn(.meetings)
        // Search by meaning looks through saved items, so it is needed while any kind of saved item is listed.
        case .search: !shownKinds.isEmpty
        }
    }

    /// Meetings or Notes is on: something can be recorded (a meeting or a voice note), and a file or a
    /// link with sound in it can be transcribed.
    public var records: Bool { isOn(.meetings) || isOn(.notes) }

    /// The models to unload after going from `old` to this set: those that were needed and no longer are.
    public func modelsToUnload(after old: FeatureSet) -> [FeatureModel] {
        FeatureModel.allCases.filter { old.needs($0) && !needs($0) }
    }

    /// Whether a Library page is shown. A page that only a switched-off feature fills leaves the sidebar;
    /// what is saved in it is kept.
    public func shows(_ page: FeaturePage) -> Bool {
        switch page {
        case .meetings: isOn(.meetings)
        case .voiceNotes: isOn(.notes)
        case .dictations: isOn(.dictate)
        // A snippet is typed out when its cue is said, and offered when its cue is typed.
        case .snippets: isOn(.dictate) || isOn(.write)
        // Documents are read aloud and summarized; and what is transcribed from a file or a link is
        // filed there, so the page is there for it too.
        case .documents: isOn(.read) || isOn(.summarize) || records
        // Words Chirp should know are used when it listens and when it checks spelling.
        case .dictionary: isOn(.dictate) || records || isOn(.write)
        // The style switches are dictation's clean-up by rule; how formal to be in each app is rephrasing's.
        case .style: isOn(.dictate) || isOn(.write)
        }
    }

    /// Whether saved items of a kind are listed: those on a page that is shown.
    public func shows(_ kind: ItemKind) -> Bool {
        switch kind {
        case .meeting: shows(.meetings)
        case .voiceNote: shows(.voiceNotes)
        case .dictation: shows(.dictations)
        case .document: shows(.documents)
        // A draft saved from the old "Check a draft" page is kept, and listed with the documents.
        case .note: shows(.documents)
        }
    }

    /// The kinds of saved item that are listed, for Home, search and the menu bar.
    public var shownKinds: [ItemKind] { ItemKind.allCases.filter(shows) }

    /// What is offered for a dropped document, in the order shown. Only a file can go with a recording.
    public func dropOffers(isFile: Bool) -> [DropOffer] {
        var offers: [DropOffer] = []
        if isOn(.read) { offers.append(.read) }
        if isOn(.summarize) { offers.append(.summarize) }
        if records, isFile { offers.append(.record) }
        return offers
    }

    /// Whether a dropped file is taken at all: sound is transcribed with Meetings or Notes on; a document needs
    /// something that can be done with it.
    public func takesDrop(audio: Bool) -> Bool {
        audio ? records : !dropOffers(isFile: true).isEmpty
    }
}
