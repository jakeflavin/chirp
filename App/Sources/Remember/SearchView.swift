import ChirpCore
import SwiftUI

extension ItemKind {
    /// The kind's name as shown to the user, in the singular.
    var label: String {
        switch self {
        case .dictation: "Dictation"
        case .voiceNote: "Note"
        case .meeting: "Meeting"
        case .document: "Document"
        case .note: "Note"
        }
    }

    /// The icon shown beside items of this kind.
    var symbol: String {
        switch self {
        case .dictation: "chirp.dictate"
        case .voiceNote: "chirp.voiceNote"
        case .meeting: "chirp.meeting"
        case .document: "chirp.documents"
        case .note: "chirp.note"
        }
    }
}

/// Find anything saved in Chirp. What is being looked for is typed in the window's search field.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(SearchController.self) private var search
    @Environment(ModelCenter.self) private var models
    /// False in the Library, whose toolbar holds the search field.
    var showField = true

    var body: some View {
        @Bindable var search = search
        VStack(alignment: .leading, spacing: 0) {
            if showField { HStack(spacing: 8) {
                Image("chirp.search").foregroundStyle(Color.quiet)
                TextField("Search dictations, meetings, notes and documents", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onChange(of: search.query) { search.search() }
                    .onSubmit { search.search() }
                    .accessibilityIdentifier("search.field")
                if search.searching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.1)))
            .padding(.bottom, 10)
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach([ItemKind.meeting, .voiceNote, .dictation, .document], id: \.self) { kind in
                    let on = search.kinds.contains(kind)
                    Button {
                        if on { search.kinds.remove(kind) } else { search.kinds.insert(kind) }
                        search.search()
                    } label: {
                        ChipLabel(title: kind.label + "s", selected: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityLabel("Only \(kind.label.lowercased())s")
                }
                meaningStatus.padding(.leading, 12)
            }
            .padding(.top, 14)

            // What a switched-off feature saved is kept, and not listed.
            let results = search.results.filter { Features.shared.set.shows($0.item.kind) }
            SectionHeading("Found", count: results.count)
            if results.isEmpty, !search.searching, !search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                // The bird looks left and right once, and finds nothing either.
                EmptyPage("Nothing found", line: "Try other words, or fewer of them.", look: .around)
                    .frame(minHeight: 300)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        SearchRow(result: result) { app.open(result.item) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
            }
            .padding(.horizontal, -10)
            .accessibilityIdentifier("search.results")
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, PageLayout.gutter)
        .onAppear { search.refreshPending() }
    }

    /// Where search by meaning stands: being prepared, not turned on yet, behind by some items, or ready.
    @ViewBuilder private var meaningStatus: some View {
        if search.indexing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(search.pendingIndex > 0 ? "Reading \(search.pendingIndex) items" : "Getting ready").font(.caption).foregroundStyle(Color.quiet)
            }
        } else if !search.meaningAvailable {
            Button("Turn on search by meaning") { search.buildIndex() }
                .controlSize(.small)
                .help("Downloads a small model (130 MB) once, then reads your saved items on this Mac.")
        } else if search.pendingIndex > 0 {
            Button(search.pendingIndex == 1 ? "Search 1 new item by meaning" : "Search \(search.pendingIndex) new items by meaning") { search.buildIndex() }
                .controlSize(.small)
                .help("New items are found by their words. This reads them so they are found by meaning too.")
        } else {
            Text("Searching by words and meaning").font(.caption).foregroundStyle(Color.quiet)
        }
    }

    /// Turns «matched» markers from keyword search into bold text.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        // Notes are kept as Markdown; show the words, not the marks.
        let plain = snippet.replacingOccurrences(of: "**", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in line.drop { $0 == "#" || $0 == "-" || $0 == " " } }
            .filter { !$0.isEmpty && $0 != "Summary" }
            .joined(separator: " · ")
        var rest = Substring(plain)
        while let open = rest.firstIndex(of: "«") {
            out += AttributedString(String(rest[..<open]))
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "»") else {
                rest = rest[after...]
                break
            }
            var bold = AttributedString(String(rest[after..<close]))
            bold.inlinePresentationIntent = .stronglyEmphasized
            out += bold
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

/// One thing search found: its name, what it is, and the words around the match. Return or a click opens it.
private struct SearchRow: View {
    let result: SemanticSearch.Result
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(result.item.kind.symbol).font(.system(size: 14)).foregroundStyle(Color.quiet).frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LibraryRows.title(result.item)).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                    Text("\(result.item.kind.label) · \(result.item.createdAt.shortRelative)").font(.rowMeta).foregroundStyle(Color.quiet)
                    Text(SearchView.highlighted(result.snippet)).font(.system(size: 12.5)).foregroundStyle(Color.ink.opacity(0.72)).lineLimit(2)
                        .multilineTextAlignment(.leading).padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(hovering ? PageLayout.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottom) { Rectangle().fill(PageLayout.line).frame(height: 1).padding(.horizontal, 10).opacity(hovering ? 0 : 1) }
            .padding(.horizontal, -10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
