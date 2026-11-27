import ChirpCore
import SwiftUI

/// Everything dictated, by day. A row is the words and, under them, where and when they were typed;
/// Copy and More show on the row pointed at. The arrow keys move, Return opens a row in full.
struct DictationsPage: View {
    @Environment(DictationController.self) private var dictation
    @Environment(PerchController.self) private var perch
    @Environment(AppModel.self) private var app
    let items: [SavedItem]
    /// The app whose dictations to show; nil shows them all.
    let appFilter: String?

    /// The row opened to its full text.
    @State private var openID: Int64?
    /// The row the arrow keys are on.
    @State private var cursorID: Int64?
    @State private var editing: SavedItem?
    @State private var copiedID: Int64?
    /// The snippet being made from a dictation, in its sheet.
    @State private var snippet: Snippet?
    /// Changed when a snippet is saved or a suggestion declined, so the suggestion is worked out again.
    @State private var suggestionVersion = 0

    private var shown: [SavedItem] { appFilter.map { app in items.filter { $0.appBundleID == app } } ?? items }

    /// The rows under the day they were said, newest first.
    private var days: [(day: String, items: [SavedItem])] {
        var out: [(day: String, items: [SavedItem])] = []
        for item in shown {
            let day = Self.dayName(item.createdAt)
            if out.last?.day == day { out[out.count - 1].items.append(item) } else { out.append((day, [item])) }
        }
        return out
    }

    /// "Today", "Yesterday", or the weekday and date for anything older.
    static func dayName(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var subtitle: String {
        let kept = items.count == 1 ? "1 kept" : "\(items.count) kept"
        return "\(kept) · the newest \(dictation.historyLimit.formatted()) are saved"
    }

    /// How dictation is started, with the key in use: "Hold right ⌥ and speak."
    private var holdLine: String {
        if let hold = dictation.holdKeyInUse { return "Hold \(hold == .rightOption ? "right ⌥" : hold.title) and speak." }
        return "Press \(ShortcutLayout.label(.dictate) ?? "the Dictate shortcut") and speak."
    }

    var body: some View {
        let order = shown.compactMap(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "Dictations", subtitle: subtitle)
                    VStack(alignment: .leading, spacing: 0) {
                        if let said = suggestion {
                            SnippetSuggestion(said: said) {
                                snippet = Snippet(cue: "", text: said.text)
                            } notNow: {
                                SnippetSuggestion.decline(said.text)
                                suggestionVersion += 1
                            }
                        }
                        if items.isEmpty {
                            // The bird and one line; there is no button, since dictating is a key held anywhere.
                            EmptyPage("No dictations yet", line: "\(holdLine) Your words are typed where the cursor is, and kept here.")
                                .frame(minHeight: 380)
                        } else if shown.isEmpty {
                            EmptyLine("Nothing dictated in this app.").padding(.top, 12)
                        }
                        ForEach(days, id: \.day) { group in
                            SectionHeading(group.day)
                            ForEach(group.items, id: \.listID) { item in
                                row(item).id(item.listID)
                            }
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, PageLayout.gutter).padding(.bottom, 28)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard !order.isEmpty else { return }
                let at = cursorID.flatMap { order.firstIndex(of: $0) } ?? -1
                let next = max(0, min(order.count - 1, direction == .up ? at - 1 : direction == .down ? at + 1 : at))
                cursorID = order[next]
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(order[next]) }
            }
            .onKeyPress(.return) {
                guard let cursorID else { return .ignored }
                openID = openID == cursorID ? nil : cursorID
                return .handled
            }
            .onKeyPress(.escape) {
                guard openID != nil || cursorID != nil else { return .ignored }
                if openID != nil { openID = nil } else { cursorID = nil }
                return .handled
            }
        }
        .sheet(item: $editing) { item in
            DictationEditor(item: item) { newText in
                dictation.lastLearned = dictation.saveEdit(of: item, newText: newText)
            }
        }
        .sheet(item: $snippet) { new in
            SnippetEditor(snippet: new) { saved, _ in
                try? app.engine.save(saved)
                suggestionVersion += 1
            }
        }
        .accessibilityIdentifier("dictations.list")
    }

    /// Something said several times this week that is not a snippet yet. Nothing is saved without the user.
    private var suggestion: SnippetOffers.Repeat? {
        _ = suggestionVersion
        guard appFilter == nil else { return nil }
        return SnippetSuggestion.current(from: items, engine: app.engine)
    }

    private func row(_ item: SavedItem) -> some View {
        DictationRow(
            item: item, open: openID == item.id, onCursor: cursorID == item.id, copied: copiedID == item.id,
            copy: { copy(item) }, edit: { editing = item }, saveAsSnippet: { snippet = Snippet(cue: "", text: item.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
        .onTapGesture {
            cursorID = item.id
            openID = openID == item.id ? nil : item.id
        }
    }

    private func copy(_ item: SavedItem) {
        TextInserter.copy(item.body)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedID = nil
        }
    }
}

/// "You have said … four times this week." with Save as a snippet and Not now: the line at the top of
/// Dictations when something has been dictated several times.
struct SnippetSuggestion: View {
    let said: SnippetOffers.Repeat
    let save: () -> Void
    let notNow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Bird(mood: .idle, size: 22).accessibilityHidden(true)
            Text("You have said \(Text("“\(said.text)”").fontWeight(.semibold)) \(Self.times(said.count)) this week.")
                .font(.system(size: 13)).foregroundStyle(Color.ink).lineLimit(2)
            Spacer(minLength: 8)
            ActButton(title: "Save as a snippet", primary: true, action: save).accessibilityIdentifier("suggestion.save")
            ActButton(title: "Not now", action: notNow).accessibilityIdentifier("suggestion.notNow")
        }
        .padding(.horizontal, 10).frame(minHeight: 44)
        .background(Color.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, -10).padding(.top, 14)
        .accessibilityElement(children: .contain)
    }

    /// "four times", "12 times".
    static func times(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return "\(count < words.count ? words[count] : String(count)) times"
    }

    private static let declinedKey = "snippetSuggestionsDeclined"

    /// "Not now": these words are not suggested again.
    static func decline(_ text: String) {
        var declined = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        declined.append(SnippetOffers.key(text))
        UserDefaults.standard.set(Array(declined.suffix(200)), forKey: declinedKey)
    }

    /// What to suggest from these dictations: said at least three times in the last seven days.
    @MainActor static func current(from items: [SavedItem], engine: PersonalLanguage) -> SnippetOffers.Repeat? {
        let week = Date().addingTimeInterval(-7 * 86_400)
        let recent = items.filter { $0.kind == .dictation && $0.createdAt >= week }.map(\.body)
        return SnippetOffers.repeated(
            dictations: recent, snippets: (try? engine.snippets(includeDisabled: true)) ?? [],
            declined: Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? []))
    }
}
