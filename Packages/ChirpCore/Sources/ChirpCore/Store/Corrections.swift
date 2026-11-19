import Foundation
import GRDB

/// One spelling the user has put right, and how many times: "Kubernets" → "Kubernetes", 4.
/// Kept so Home can suggest adding a word that is corrected often to the Dictionary.
/// Only the two words are kept, never the text around them.
public struct Correction: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "correction"
    public var id: Int64?
    /// The word as it was written.
    public var wrong: String
    /// The word it was changed to.
    public var right: String
    public var times: Int
    public var lastAt: Date

    public init(id: Int64? = nil, wrong: String, right: String, times: Int = 1, lastAt: Date = Date()) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.times = times
        self.lastAt = lastAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Whether the two are single words that differ: a correction of one word, not of a phrase.
    public static func counts(wrong: String, right: String) -> Bool {
        func oneWord(_ s: String) -> Bool { !s.isEmpty && s.count <= 40 && !s.contains { $0.isWhitespace || $0.isNewline } && s.contains { $0.isLetter } }
        return oneWord(wrong) && oneWord(right) && wrong != right
    }

    /// Whether the corrected word reads as a name or a term of the user's own, which is what the
    /// Dictionary is for: a capital inside it ("GitHub"), a digit ("K8s"), or a capital at its start
    /// that the user had not typed ("kubernets" → "Kubernetes"). An everyday word put right
    /// ("recieve" → "receive") is not: in the Dictionary it would only pull other dictated words
    /// towards it. A capital the user typed too may only be the start of a sentence, so it is not enough.
    public var isOwnTerm: Bool {
        if right.dropFirst().contains(where: \.isUppercase) || right.contains(where: \.isNumber) { return true }
        guard let first = right.first, first.isUppercase, let typed = wrong.first else { return false }
        return typed.isLowercase
    }
}

extension PersonalLanguage {
    /// Counts one correction of a single word. Anything else (a phrase, the same word) is not counted.
    public func noteCorrection(wrong: String, right: String, now: Date = Date()) throws {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Correction.counts(wrong: wrong, right: right) else { return }
        try store.db.write { db in
            if var had = try Correction.filter(Column("wrong") == wrong && Column("right") == right).fetchOne(db) {
                had.times += 1
                had.lastAt = now
                try had.update(db)
            } else {
                var new = Correction(wrong: wrong, right: right, lastAt: now)
                try new.insert(db)
            }
        }
    }

    /// The corrections made at least `atLeast` times, the most often first.
    public func corrections(atLeast: Int = 1) throws -> [Correction] {
        try store.db.read { db in
            try Correction.filter(Column("times") >= atLeast).order(Column("times").desc, Column("lastAt").desc).fetchAll(db)
        }
    }

    /// Forgets every count kept for a corrected word (it went into the Dictionary, or was dismissed).
    public func forgetCorrections(of right: String) throws {
        _ = try store.db.write { db in try Correction.filter(Column("right").collating(.nocase) == right).deleteAll(db) }
    }
}
