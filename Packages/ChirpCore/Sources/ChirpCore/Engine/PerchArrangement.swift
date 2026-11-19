import Foundation

/// An action the perch can carry. Stored by name, so a case is never renamed.
public enum PerchAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case dictate, note, read, fix, summarize, meeting, rephrase, snippet, typeAgain, library

    public var id: String { rawValue }

    /// Its name in Customize Perch and the menus.
    public var title: String {
        switch self {
        case .dictate: "Dictate"
        case .note: "Note"
        case .read: "Read aloud"
        case .fix: "Fix writing"
        case .summarize: "Summarize"
        case .meeting: "Record a meeting"
        case .rephrase: "Rephrase"
        case .snippet: "Save as a Snippet"
        case .typeAgain: "Type last dictation again"
        case .library: "Library"
        }
    }

    /// Its short name under its icon on the taller bar.
    public var shortTitle: String {
        switch self {
        case .read: "Read"
        case .fix: "Fix"
        case .meeting: "Meeting"
        case .snippet: "Snippet"
        case .typeAgain: "Again"
        default: title
        }
    }

    /// Whether it is there with these features on. An action whose feature is off is shown nowhere.
    public func isOn(_ features: FeatureSet) -> Bool {
        switch self {
        case .dictate, .typeAgain: features.isOn(.dictate)
        case .note: features.isOn(.notes)
        case .read: features.isOn(.read)
        case .fix, .rephrase: features.isOn(.write)
        case .summarize: features.isOn(.summarize)
        case .meeting: features.isOn(.meetings)
        case .snippet: features.isOn(.write) || features.isOn(.dictate)
        case .library: true
        }
    }
}

/// Which actions sit on the perch (five at most) and which in the extended area that More slides open,
/// in the order the user put them. Saved as JSON in the app's preferences.
public struct PerchArrangement: Codable, Equatable, Sendable {
    /// On the bar itself, in order: five at most.
    public private(set) var bar: [PerchAction]
    /// In the extended area, in order.
    public private(set) var extended: [PerchAction]

    public static let barLimit = 5

    /// The Default Set: Dictate, Note, Read aloud, Fix writing, Summarize on the perch; Record a meeting
    /// and Rephrase in the extended area.
    public static let standard = PerchArrangement(bar: [.dictate, .note, .read, .fix, .summarize], extended: [.meeting, .rephrase])

    public init(bar: [PerchAction], extended: [PerchAction]) {
        var seen = Set<PerchAction>()
        let bar = bar.filter { seen.insert($0).inserted }
        let extended = extended.filter { seen.insert($0).inserted }
        self.bar = Array(bar.prefix(Self.barLimit))
        // What does not fit on the bar goes to the front of the extended area.
        self.extended = Array(bar.dropFirst(Self.barLimit)) + extended
    }

    /// Where an action can be put.
    public enum Place: String, Sendable { case bar, extended }

    /// Where an action is now, if anywhere.
    public func place(of action: PerchAction) -> Place? {
        bar.contains(action) ? .bar : extended.contains(action) ? .extended : nil
    }

    /// Puts an action at `index` in `place`, taking it from wherever it was. Dropping a sixth onto the
    /// bar moves the bar's last one to the front of the extended area.
    public mutating func put(_ action: PerchAction, in place: Place, at index: Int) {
        var bar = self.bar.filter { $0 != action }
        var extended = self.extended.filter { $0 != action }
        switch place {
        case .bar:
            bar.insert(action, at: min(max(index, 0), bar.count))
            if bar.count > Self.barLimit { extended.insert(bar.removeLast(), at: 0) }
        case .extended:
            extended.insert(action, at: min(max(index, 0), extended.count))
        }
        self = PerchArrangement(bar: bar, extended: extended)
    }

    /// A drop in Customize Perch: `action` lands in `place` just before `anchor` (the tile it was dropped
    /// on), or last when `anchor` is nil (the end of the row). The anchor is the action, not a position, so
    /// a drop always lands next to the tile it was let go over, whatever has changed since the row was
    /// drawn; switched-off actions keep their places among the rest. Dropped on itself, nothing moves.
    public mutating func drop(_ action: PerchAction, in place: Place, before anchor: PerchAction?) {
        guard anchor != action else { return }
        let all = place == .bar ? bar : extended
        var target = anchor.flatMap { all.firstIndex(of: $0) } ?? all.count
        if let from = all.firstIndex(of: action), from < target { target -= 1 }
        put(action, in: place, at: target)
    }

    /// Takes an action off the perch and out of the extended area.
    public mutating func remove(_ action: PerchAction) {
        self = PerchArrangement(bar: bar.filter { $0 != action }, extended: extended.filter { $0 != action })
    }

    /// What is shown with these features on: switched-off actions leave, and the others close up.
    public func shown(_ features: FeatureSet) -> (bar: [PerchAction], extended: [PerchAction]) {
        (bar.filter { $0.isOn(features) }, extended.filter { $0.isOn(features) })
    }

    /// The actions in neither place, in their usual order: these are in the … menu.
    public var unplaced: [PerchAction] { PerchAction.allCases.filter { place(of: $0) == nil } }

    // MARK: Saving

    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Read back from `json`. Names it does not know are left out; anything unreadable is the Default Set.
    public init(json: String?) {
        struct Raw: Decodable { var bar: [String]; var extended: [String] }
        guard let data = json?.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            self = .standard
            return
        }
        self.init(bar: raw.bar.compactMap(PerchAction.init(rawValue:)), extended: raw.extended.compactMap(PerchAction.init(rawValue:)))
    }

    public enum CodingKeys: String, CodingKey { case bar, extended }
}

/// What a tile in Customize Perch carries while it is dragged: the action, and which version of the
/// sheet the drag began in. Default Set starts a new version, and a drop that began before it is let go
/// (a drop is delivered after its data has loaded, which on a busy Mac can be after the next click) is
/// ignored, so Default Set always has the last word.
public struct PerchDrag: Equatable, Sendable {
    public var action: PerchAction
    public var version: Int

    public init(action: PerchAction, version: Int) {
        self.action = action
        self.version = version
    }

    /// As text, for the drag: "fix@2".
    public var payload: String { "\(action.rawValue)@\(version)" }

    /// Read back from a drag's text. A bare action name (from an older drag) has no version.
    public init?(payload: String) {
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let action = parts.first.flatMap(PerchAction.init(rawValue:)) else { return nil }
        self.action = action
        self.version = parts.count == 2 ? (Int(parts[1]) ?? -1) : -1
    }

    /// Whether a drop of this drag still applies in the sheet's `current` version.
    public func applies(in current: Int) -> Bool { version == current }
}
