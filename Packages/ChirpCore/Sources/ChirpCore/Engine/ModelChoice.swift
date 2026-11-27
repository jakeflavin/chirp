import Foundation

/// The sizes of language model Chirp can run, and which one suits a given Mac. This is the one place that
/// names each size's model and the memory it needs; the app and the language helper read it from here.
/// The speech, voice, speaker and search models are small enough to be the same on every Mac;
/// the language model is the one whose size has to match the memory available.
public enum LanguageModelSize: String, CaseIterable, Sendable, Identifiable, Codable {
    case small, medium, large

    public var id: String { rawValue }

    /// Where the model is downloaded from.
    public var modelID: String {
        switch self {
        case .small: "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .medium: "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .large: "mlx-community/Qwen3.5-9B-4bit"
        }
    }

    /// The commit of the model's repository that Chirp loads. Pinned so a change on the hub never reaches
    /// a Mac unasked; moving to a newer one is a change to this table, checked like any other.
    public var revision: String {
        switch self {
        case .small: "93760be4f1f69842a46bc13dbdc0f19e291392a3"
        case .medium: "32f3e8ecf65426fc3306969496342d504bfa13f3"
        case .large: "8b2b98c00a6b4d291155e4890773ca8f769aee53"
        }
    }

    /// The model and its pinned commit, as the language helper is given it ("repo@revision").
    public var hubReference: String { HubReference.joined(modelID, revision: revision) }

    /// The model's name as shown to the user.
    public var name: String {
        switch self {
        case .small: "Qwen3.5 2B"
        case .medium: "Qwen3.5 4B"
        case .large: "Qwen3.5 9B"
        }
    }

    /// Size of the download, in GB.
    public var downloadGB: Double {
        switch self {
        case .small: 1.6
        case .medium: 3.1
        case .large: 6.0
        }
    }

    /// The least memory a Mac should have for this size to run beside the other models and the user's apps.
    public var comfortableMemoryGB: Int {
        switch self {
        case .small: 8
        case .medium: 16
        case .large: 24
        }
    }

    /// The next size down, to fall back to when this one does not fit.
    public var smaller: LanguageModelSize? {
        switch self {
        case .small: nil
        case .medium: .small
        case .large: .medium
        }
    }

    /// Whether a Mac with this much memory can run this size without struggling.
    public func isComfortable(memoryBytes: UInt64) -> Bool {
        // A Mac sold as 16 GB reports slightly less than 16 × 2^30 usable, so allow a small margin.
        MacMemory.gigabytes(memoryBytes) >= Double(comfortableMemoryGB) - 0.5
    }

    /// What Chirp picks when the user has not chosen. Large is never picked automatically: it is
    /// offered to Macs with 24 GB or more as a choice.
    public static func recommended(memoryBytes: UInt64) -> LanguageModelSize {
        LanguageModelSize.medium.isComfortable(memoryBytes: memoryBytes) ? .medium : .small
    }

    /// The size to use: the user's choice if they made one, otherwise the recommendation.
    public static func resolve(choice: String?, memoryBytes: UInt64) -> LanguageModelSize {
        choice.flatMap(LanguageModelSize.init(rawValue:)) ?? recommended(memoryBytes: memoryBytes)
    }
}

/// The memory lines Chirp's model choices follow, in one place, so the app, Settings and the writing checks
/// agree on what a small Mac is.
public enum MacMemory {
    /// Bytes in a gigabyte as memory is counted (2^30).
    static let bytesPerGigabyte: Double = 1_073_741_824

    /// Memory in gigabytes, as a fraction.
    public static func gigabytes(_ memoryBytes: UInt64) -> Double { Double(memoryBytes) / bytesPerGigabyte }

    /// Memory in whole gigabytes, for showing to the user.
    public static func wholeGigabytes(_ memoryBytes: UInt64) -> Int { Int(gigabytes(memoryBytes).rounded()) }

    /// Below this many gigabytes only one heavy model (the language model or the reading voice) is kept
    /// loaded at a time, and heavy models are put away after sitting idle.
    static let oneHeavyModelBelowGigabytes = 12.0

    /// Whether this Mac keeps only one heavy model loaded at a time.
    public static func keepsOneHeavyModel(memoryBytes: UInt64) -> Bool {
        gigabytes(memoryBytes) < oneHeavyModelBelowGigabytes
    }

    /// Whether the deeper writing check runs in other apps unless switched off. It keeps the language model
    /// loaded while the user types, so it is on where the medium language model would be picked.
    public static func deepChecksEverywhereByDefault(memoryBytes: UInt64) -> Bool {
        LanguageModelSize.medium.isComfortable(memoryBytes: memoryBytes)
    }
}

/// A Hugging Face repository with the commit to load, written "repo@revision" so it travels as one string to
/// the language helper. Without "@" the hub's latest revision is meant.
public enum HubReference {
    public static func joined(_ repo: String, revision: String) -> String { repo + "@" + revision }

    /// The repository and its revision, or nil for the revision when none is named.
    public static func split(_ reference: String) -> (repo: String, revision: String?) {
        let parts = reference.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return (parts.first ?? reference, nil) }
        return (parts[0], parts[1])
    }
}
