import ChirpCore
import SwiftUI

/// The card for one problem in another app. It is Chirp's, so the bird is on it, and it is small: the bird,
/// the fix as the thing to click, and one line saying why. The small buttons dismiss the suggestion, add
/// the word to the dictionary, or stop this kind of suggestion.
///
/// A word that is probably a name ("Garmin") is more likely right than wrong, so its card leads with
/// "Add to Dictionary" and the spelling guesses follow it.
///
/// A note that has no fix of its own ("This sentence is 57 words long.") has one button that rewrites
/// just that sentence, and then shows the change to accept. A snippet's cue that was typed has
/// "Use snippet" and the saved text under it.
struct SuggestionCard: View {
    let issue: WritingIssue
    let text: String
    /// Where a note's rewrite has got to. Nil before its button is pressed, and for every other card.
    var rewrite: NoteRewrite?
    let act: (IssueAction) -> Void

    /// A note's sentence being rewritten, the change to accept, or why there is none.
    enum NoteRewrite: Equatable {
        case working
        /// The rewritten sentence, and the line under it ("Shortened from 57 words to 31.").
        case ready(String, String)
        /// Why no rewrite is offered.
        case failed(String)
    }

    /// The rewrite this note offers in place of a fix, if it has no fix of its own.
    private var offer: (title: String, task: WritingTask)? { Proofreading.sentenceRewrite(for: issue) }

    /// The fixes offered: the first three, or two guesses after "Add to Dictionary" for a likely name.
    private var fixes: [Fix] { Array(issue.suggestions.prefix(isName ? 2 : 3)) }
    /// Whether the word is probably a name: capitalised in the middle of a sentence, or with a capital inside it.
    private var isName: Bool { Proofreading.likelyName(issue, in: text) }
    /// Where everything beside the bird starts: the bird's width and the gap after it.
    private static let column: CGFloat = 28
    /// Whether every fix fits on one line with the bird and the small buttons.
    private var inline: Bool {
        fixes.reduce(0) { $0 + issue.label(for: $1, in: text).count + 3 } <= 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Short fixes sit in one row beside the bird; long ones get a row each. Which it is comes from
            // their length, decided before drawing, so the card is measured as the layout it will use.
            if issue.category == .snippet, let fix = issue.suggestions.first {
                HStack(spacing: 6) {
                    bird
                    main("Use snippet", label: "Use your snippet") { act(.apply(fix)) }
                    Spacer(minLength: 8)
                    icon("chirp.hide", "Do not offer this snippet for these words") { act(.dismiss) }
                    icon("chirp.close", "Close") { act(.close) }
                }
                change(fix.text)
            } else if let offer {
                switch rewrite {
                case .ready(let sentence, _):
                    HStack(spacing: 6) {
                        bird
                        main("Replace", key: "↵", label: "Replace the sentence") { act(.acceptRewrite) }
                        quiet("Keep mine") { act(.close) }
                        Spacer(minLength: 8)
                        icon("chirp.close", "Close") { act(.close) }
                    }
                    change(sentence)
                case .failed(let why):
                    HStack(alignment: .top, spacing: 6) {
                        bird
                        Text(why).font(.system(size: 12.5)).foregroundStyle(PerchStyle.text)
                            .frame(width: 290, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                        Spacer(minLength: 8)
                        icon("chirp.close", "Close") { act(.close) }
                    }
                case .working, nil:
                    HStack(spacing: 6) {
                        bird
                        main(rewrite == .working ? "Working…" : offer.title, label: offer.title) { act(.rewrite) }
                            .disabled(rewrite == .working).opacity(rewrite == .working ? 0.6 : 1)
                        Spacer(minLength: 8)
                        icon("chirp.hide", "Stop showing this kind of suggestion") { act(.dismissRule) }
                        icon("chirp.close", "Close") { act(.close) }
                    }
                }
            } else if isName {
                HStack(spacing: 6) {
                    bird
                    addToDictionary
                    Spacer(minLength: 8)
                    tools
                }
                // The guesses come second, and none of them is the amber one.
                if !fixes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in pill(fix, first: false) }
                    }
                    .padding(.leading, Self.column)
                }
            } else if inline {
                HStack(spacing: 6) {
                    bird
                    ForEach(Array(fixes.enumerated()), id: \.offset) { index, fix in pill(fix, first: index == 0) }
                    Spacer(minLength: 8)
                    tools
                }
            } else {
                HStack(spacing: 6) {
                    bird
                    if let fix = fixes.first { pill(fix, first: true) }
                    Spacer(minLength: 8)
                    tools
                }
                ForEach(Array(fixes.dropFirst().enumerated()), id: \.offset) { _, fix in pill(fix, first: false).padding(.leading, Self.column) }
            }
            // The reason lines up under the fix: everything to the right of the bird shares one left edge.
            if reason != nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(Color(nsColor: issue.category.color)).frame(width: 6, height: 6).offset(y: -1)
                    Text(reason ?? "")
                        .font(.system(size: 11.5)).foregroundStyle(PerchStyle.dim)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, Self.column)
            }
        }
        .padding(10)
        .frame(minWidth: 190, maxWidth: wide ? 400 : 290, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(PerchStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PerchStyle.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chirp suggestion")
    }

    /// The line under the buttons: why the card is here, or what the rewrite did. None once a rewrite failed.
    private var reason: String? {
        switch rewrite {
        case .ready(_, let summary): return summary
        case .failed: return nil
        default: break
        }
        return isName ? "“\(issue.flagged(in: text))” looks like a name." : Proofreading.plain(issue.message)
    }

    /// A card that shows a sentence or a snippet's text is allowed more width than one with a word or two.
    private var wide: Bool {
        if case .ready = rewrite { return true }
        if case .failed = rewrite { return true }
        return issue.category == .snippet
    }

    /// The amber button: what the bird is offering.
    private func main(_ title: String, key: String? = nil, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let key { PerchKey(text: key, onAmber: true) }
            }
            .foregroundStyle(PerchStyle.onAmber)
            .padding(.horizontal, 9).frame(height: 24)
            .background(PerchStyle.amber, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A second button beside the amber one.
    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(PerchStyle.text)
                .padding(.horizontal, 9).frame(height: 24)
                .background(PerchStyle.softer, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The words that would go in: a snippet's saved text, or the rewritten sentence.
    private func change(_ words: String) -> some View {
        Text(words).font(.system(size: 13)).lineSpacing(2).foregroundStyle(PerchStyle.text)
            .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            // The card is as wide as what is in it, so a long text is given its width here and wraps inside it.
            .frame(width: words.count > 48 ? 340 : nil, alignment: .leading)
            .padding(.leading, Self.column).padding(.top, 2)
    }

    private var bird: some View {
        Bird(mood: .idle, size: 22).frame(width: 22, height: 22).accessibilityHidden(true)
    }

    /// One fix as a button. The first is the likeliest and is the amber one.
    private func pill(_ fix: Fix, first: Bool) -> some View {
        Button {
            act(.apply(fix))
        } label: {
            Text(issue.label(for: fix, in: text)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(first ? PerchStyle.onAmber : PerchStyle.text)
                .padding(.horizontal, 9).frame(height: 24)
                .background(first ? PerchStyle.amber : PerchStyle.softer, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change to \(issue.label(for: fix, in: text))")
    }

    /// The first thing offered for a likely name: keep the word, and never flag it again.
    private var addToDictionary: some View {
        Button {
            act(.addToDictionary)
        } label: {
            HStack(spacing: 5) {
                Image("chirp.dictionary").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text("Add to Dictionary").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(PerchStyle.onAmber)
            .padding(.horizontal, 9).frame(height: 24)
            .background(PerchStyle.amber, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add “\(issue.flagged(in: text))” to your dictionary")
    }

    /// The small buttons: add to the dictionary (spelling) or stop this kind of suggestion, and dismiss.
    /// A likely name's card has "Add to Dictionary" as its first button, so only Dismiss is here.
    private var tools: some View {
        HStack(spacing: 0) {
            if isName {
                EmptyView()
            } else if issue.category == .spelling {
                icon("chirp.addWord", "Add “\(issue.flagged(in: text))” to your dictionary") { act(.addToDictionary) }
            } else {
                icon("chirp.hide", "Stop showing this kind of suggestion") { act(.dismissRule) }
            }
            icon("chirp.close", "Dismiss") { act(.dismiss) }
        }
    }

    /// A small icon button whose tooltip is also its spoken label.
    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(PerchStyle.dim)
                .frame(width: 20, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
