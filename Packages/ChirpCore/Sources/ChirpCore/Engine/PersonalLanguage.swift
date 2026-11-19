import Foundation
import GRDB

/// The user's writing habits. Every field is visible and editable under Remember.
public struct WritingProfile: Codable, Sendable, Equatable {
    public enum Spelling: String, Codable, Sendable, CaseIterable { case american, british }

    /// Which country's spelling rewrites and answers use.
    public var spelling: Spelling = .american
    /// Default formality when the current app has no style of its own.
    public var formality: Formality = .neutral
    /// Drop "um", "uh" and the like from dictation.
    public var removeFillers: Bool = true
    /// Keep a word said several times in a row ("the the") once.
    public var collapseRepeats: Bool = true
    /// Treat "no wait", "scratch that" and similar as an instruction to drop what was just said.
    public var handleSelfCorrections: Bool = true
    /// Turn spoken "comma", "period", "question mark" into punctuation.
    public var spokenPunctuation: Bool = false
    /// Turn spoken "new line" / "new paragraph" into line breaks.
    public var spokenLineBreaks: Bool = true
    /// Free-text notes on how the user likes to write, passed to rewrites. Written by the user.
    public var styleNotes: String = ""

    public init() {}

    /// Reads a saved profile field by field, so one saved before a switch existed keeps everything else
    /// the user chose and takes the default for the new switch. (Read all or nothing, a profile from an
    /// older version failed and every choice silently went back to its default.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Spelling.self, forKey: .spelling) { spelling = v }
        if let v = try c.decodeIfPresent(Formality.self, forKey: .formality) { formality = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) { removeFillers = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .collapseRepeats) { collapseRepeats = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .handleSelfCorrections) { handleSelfCorrections = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) { spokenPunctuation = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .spokenLineBreaks) { spokenLineBreaks = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .styleNotes) { styleNotes = v }
    }
}

/// A snapshot of where the user is working, used to pick a style. Never stores screen text.
public struct WorkContext: Sendable, Equatable {
    public var bundleID: String?
    public var appName: String?

    public init(bundleID: String? = nil, appName: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// The Personal Language Engine: one shared, user-controlled understanding of how the user
/// communicates. Dictation, meetings, writing checks and reading all read from here.
public final class PersonalLanguage: Sendable {
    public let store: ChirpStore

    public init(store: ChirpStore) {
        self.store = store
    }

    // MARK: Profile and settings

    /// The user's writing habits; the defaults until they change something.
    public func profile() throws -> WritingProfile {
        try setting("writingProfile", as: WritingProfile.self) ?? WritingProfile()
    }

    public func saveProfile(_ profile: WritingProfile, origin: Origin = .manual) throws {
        try setSetting("writingProfile", profile, origin: origin)
    }

    /// A saved preference, or nil when it was never saved or was saved as a different kind of value.
    public func setting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try store.db.read { db in
            guard let row = try SettingRow.fetchOne(db, key: key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(row.value.utf8))
        }
    }

    /// Saves a preference as JSON under `key`, replacing what was there.
    public func setSetting<T: Encodable>(_ key: String, _ value: T, origin: Origin = .manual) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try store.db.write { db in
            try SettingRow(key: key, value: json, origin: origin, updatedAt: Date()).save(db)
        }
    }

    // MARK: Dictionary

    /// The user's words in alphabetical order; switched-off ones only when asked for.
    public func dictionary(includeDisabled: Bool = false) throws -> [DictionaryEntry] {
        try store.db.read { db in
            var q = DictionaryEntry.order(Column("term").collating(.localizedCaseInsensitiveCompare))
            if !includeDisabled { q = q.filter(Column("enabled") == true) }
            return try q.fetchAll(db)
        }
    }

    /// Adds a word, or adds to the one already there: a word is kept once whatever its capitals, and
    /// adding it again merges the new "sounds like" spellings in and switches it back on.
    @discardableResult
    public func addWord(
        _ term: String, soundsLike: [String] = [], pronunciation: String? = nil,
        origin: Origin = .manual, note: String? = nil
    ) throws -> DictionaryEntry {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return try store.db.write { db in
            if var existing = try DictionaryEntry.filter(Column("term").collating(.nocase) == clean).fetchOne(db) {
                let merged = existing.soundsLike + soundsLike.filter { s in
                    !existing.soundsLike.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                }
                existing.soundsLike = merged
                existing.enabled = true
                if let pronunciation { existing.pronunciation = pronunciation }
                try existing.update(db)
                return existing
            }
            var entry = DictionaryEntry(
                term: clean, soundsLike: soundsLike, pronunciation: pronunciation, origin: origin, originNote: note)
            try entry.insert(db)
            return entry
        }
    }

    public func save(_ entry: DictionaryEntry) throws {
        var e = entry
        try store.db.write { db in try e.save(db) }
    }

    public func delete(_ entry: DictionaryEntry) throws {
        _ = try store.db.write { db in try entry.delete(db) }
    }

    /// Records a correction the user made to dictated text, e.g. "cooper netties" → "Kubernetes".
    /// Stored as a learned dictionary entry the user can inspect or delete.
    @discardableResult
    public func learnCorrection(heard: String, meant: String, note: String) throws -> DictionaryEntry? {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard.caseInsensitiveCompare(meant) != .orderedSame,
            meant.split(separator: " ").count <= 4
        else { return nil }
        return try addWord(meant, soundsLike: [heard], origin: .learned, note: note)
    }

    // MARK: Snippets

    public func snippets(includeDisabled: Bool = false) throws -> [Snippet] {
        try store.db.read { db in
            var q = Snippet.order(Column("cue"))
            if !includeDisabled { q = q.filter(Column("enabled") == true) }
            return try q.fetchAll(db)
        }
    }

    public func save(_ snippet: Snippet) throws {
        var s = snippet
        try store.db.write { db in try s.save(db) }
    }

    public func delete(_ snippet: Snippet) throws {
        _ = try store.db.write { db in try snippet.delete(db) }
    }

    // MARK: Per-app style

    public func appStyles() throws -> [AppStyle] {
        try store.db.read { db in try AppStyle.order(Column("appName")).fetchAll(db) }
    }

    public func appStyle(bundleID: String) throws -> AppStyle? {
        try store.db.read { db in try AppStyle.filter(Column("bundleID") == bundleID).fetchOne(db) }
    }

    /// Saves an app's style. An app has one style: a new one for the same app replaces the old.
    public func save(_ style: AppStyle) throws {
        var s = style
        s.updatedAt = Date()
        try store.db.write { db in
            if s.id == nil, let existing = try AppStyle.filter(Column("bundleID") == s.bundleID).fetchOne(db) {
                s.id = existing.id
            }
            try s.save(db)
        }
    }

    public func delete(_ style: AppStyle) throws {
        _ = try store.db.write { db in try style.delete(db) }
    }

    /// The formality to use right now: the app's own style if it has one, else the profile default.
    public func formality(for context: WorkContext) throws -> Formality {
        if let id = context.bundleID, let style = try appStyle(bundleID: id) { return style.formality }
        return try profile().formality
    }

    /// Sets the writing style for one app, as the perch's More menu and the menu bar do for the app in
    /// front. An app with no setting of its own gets one, with its underlines left
    /// as they are (an app Chirp stays out of is not switched on by this).
    public func setFormality(_ formality: Formality, for context: WorkContext) throws {
        guard let id = context.bundleID, !id.isEmpty else { return }
        var style = try appStyle(bundleID: id)
            ?? AppStyle(bundleID: id, appName: context.appName ?? id, underlinesEnabled: try underlinesEnabled(for: context))
        style.formality = formality
        if let name = context.appName, !name.isEmpty { style.appName = name }
        style.updatedAt = Date()
        try save(style)
    }

    /// Whether writing checks show in this app: the user's choice for it if they made one, otherwise on
    /// everywhere except the apps Chirp stays out of.
    public func underlinesEnabled(for context: WorkContext) throws -> Bool {
        if let id = context.bundleID {
            if let style = try appStyle(bundleID: id) { return style.underlinesEnabled }
            if Self.staysOut(of: id) { return false }
        }
        return true
    }

    /// Whether Chirp leaves an app alone unless the user turns it on there.
    public static func staysOut(of bundleID: String) -> Bool {
        underlineUnfriendlyApps.contains(bundleID) || quietPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Apps Chirp does not check by default: terminals and code editors, where command output and source
    /// code are not prose, password managers, where nothing should be read,
    /// and apps whose text areas do not report reliable positions. The shortcut panel still works there,
    /// and suggestions can be turned on for any of them from Chirp's bar.
    public static let underlineUnfriendlyApps: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "dev.tabby",
        // Code editors
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "org.vim.MacVim", "com.panic.Nova", "com.barebones.bbedit",
        "com.exafunction.windsurf", "com.vscodium",
        // Password managers and keychains
        "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        "com.lastpass.LastPass", "in.sinew.Enpass-Desktop", "com.keepersecurity.passwordmanager",
        // Sign-in, lock-screen and security prompts, the system's own settings, and credential helpers:
        // nothing in them is writing, and some of it must not be read.
        "com.apple.loginwindow", "com.apple.LockScreen", "com.apple.systempreferences",
        "com.apple.Passwords.MenuBarExtra", "com.apple.AppSSOAgent", "com.apple.authkit.AuthKitHeadlessUIHelper",
        "com.apple.AutoFillPanelService", "com.apple.CaptiveNetworkAssistant", "com.apple.CertificateAssistant",
        "com.apple.devicemanagementclient.alertagent", "com.apple.DirectoryUtility", "com.apple.eap8021x.eaptlstrust",
        "com.apple.EraseAssistant", "com.apple.EscrowSecurityAlert", "com.apple.KerberosMenuExtra", "com.apple.ManagedClient",
        "com.apple.mcx.MCXDiskAuthorization", "com.apple.mcx.ProfileHelper", "com.apple.NetAuthAgent",
        "com.apple.PlatformSSO.PlatformSSOUIAgent", "com.apple.security.Keychain-Circle-Notification", "com.apple.SetupAssistant",
        "com.apple.tcc.AuthorizationPromptService", "com.apple.Ticket-Viewer", "com.apple.WebDAVFS.webdav-cert-ui",
        "com.apple.accessibility.universalAccessAuthWarn", "2BUA8C4S2C.com.1password.browser-helper",
        // Positions not reliable
        "notion.id",
    ]

    /// Whole families of apps left alone the same way, by the start of their bundle identifier.
    static let quietPrefixes = ["com.jetbrains.", "com.1password.", "com.agilebits.", "com.google.android.studio"]

    // MARK: Dismissed grammar rules

    public func dismissedRules() throws -> [DismissedRule] {
        try store.db.read { db in try DismissedRule.order(Column("createdAt").desc).fetchAll(db) }
    }

    /// Remembers that a suggestion was dismissed: for one piece of text, or for the whole rule when `text` is nil.
    public func dismiss(ruleKey: String, text: String?) throws {
        try store.db.write { db in
            var r = DismissedRule(ruleKey: ruleKey, text: text)
            try r.insert(db)
        }
    }

    public func delete(_ rule: DismissedRule) throws {
        _ = try store.db.write { db in try rule.delete(db) }
    }

    /// Whether a suggestion of this rule on this text was dismissed before.
    public func isDismissed(ruleKey: String, text: String, in rules: [DismissedRule]) -> Bool {
        rules.contains { $0.ruleKey == ruleKey && ($0.text == nil || $0.text == text) }
    }

    // MARK: Everything, for export and reset

    /// Everything the engine holds about the user, for saving to a file.
    public struct Export: Codable, Sendable {
        public var profile: WritingProfile
        public var dictionary: [DictionaryEntry]
        public var snippets: [Snippet]
        public var appStyles: [AppStyle]
        public var dismissedRules: [DismissedRule]
    }

    public func export() throws -> Export {
        Export(
            profile: try profile(), dictionary: try dictionary(includeDisabled: true),
            snippets: try snippets(includeDisabled: true), appStyles: try appStyles(),
            dismissedRules: try dismissedRules())
    }

    /// Deletes everything Chirp learned on its own, keeping what the user entered by hand.
    public func forgetLearned() throws {
        try store.db.write { db in
            try DictionaryEntry.filter(Column("origin") == Origin.learned.rawValue).deleteAll(db)
            try AppStyle.filter(Column("origin") == Origin.learned.rawValue).deleteAll(db)
            try DismissedRule.deleteAll(db)
            try Correction.deleteAll(db)
        }
    }
}
