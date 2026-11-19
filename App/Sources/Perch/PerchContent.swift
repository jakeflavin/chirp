import AppKit
import ChirpCore
import SwiftUI

// What the perch holds above its bar. Each is part of the perch's one surface, laid out the same way:
// a head row (title, grey detail, close), a body with its words straight on the glass, and a foot row
// of what to do next, the main one first.

/// The frame every kind of content shares: handle, head, body, foot.
struct PerchSection<Middle: View, Foot: View>: View {
    let perch: PerchController
    let kind: PerchContent
    let title: String
    var meta = ""
    /// Shows the handle and the arrows button that pull the surface taller.
    var resizable = true
    let close: () -> Void
    @ViewBuilder var content: () -> Middle
    @ViewBuilder var foot: () -> Foot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let down = perch.opensDown
        VStack(alignment: .leading, spacing: 0) {
            if resizable, !down { handle }
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if !meta.isEmpty {
                    Text(meta).foregroundStyle(GlassFill.quiet).lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if resizable {
                    let tall = perch.isTall(kind)
                    PerchIconButton(
                        perch: perch, symbol: tall ? "chirp.collapse" : "chirp.expand",
                        label: tall ? "Make shorter" : "Make taller", size: 11, side: 26
                    ) {
                        withAnimation(GlassMotion.shape(growing: !tall, reduceMotion: reduceMotion)) { perch.toggleTall(kind) }
                    }
                }
                PerchIconButton(perch: perch, symbol: "chirp.close", label: "Close", size: 11, side: 26, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.top, resizable && !down ? 6 : 12)
            content()
            // Beside an upright column the surface can be taller than what it holds: the foot row stays at the bottom.
            Spacer(minLength: 0)
            // The key that closes it sits at the far end, when there is room beside the actions.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    foot()
                    Spacer(minLength: 6)
                    PerchKey(text: "esc").fixedSize()
                }
                HStack(spacing: 4) {
                    foot()
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(GlassFill.quiet).font(.system(size: 12))
            .padding(.leading, 12).padding(.trailing, 10).padding(.top, 8).padding(.bottom, down ? 8 : 2)
            .overlay(alignment: .top) { Rectangle().fill(GlassFill.line).frame(height: 1) }
            .padding(.top, 6)
            if resizable, down { handle.padding(.bottom, 7) }
        }
        .padding(.top, down ? -4 : 0)
    }

    /// The small bar on the edge away from the bar row. Pulling it makes the surface taller or shorter.
    private var handle: some View {
        Capsule().fill(GlassFill.ink.opacity(0.22)).frame(width: 36, height: 4)
            .frame(maxWidth: .infinity).frame(height: 11, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in perch.pull(kind, by: perch.opensDown ? value.translation.height : -value.translation.height) }
                    .onEnded { _ in perch.pullEnded() }
            )
            .accessibilityLabel("Height")
            .accessibilityHint("Drag to make this taller or shorter")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 80 : -80
                perch.setBodyHeight(perch.bodyHeight(for: kind) + step, for: kind)
            }
            .help("Drag to make this taller or shorter")
    }
}

/// A scrolling area that is only as tall as what is in it, up to a limit. Beyond that it scrolls.
struct PerchScroll<Content: View>: View {
    let limit: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var natural: CGFloat = 40

    var body: some View {
        ScrollView {
            content().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(1, min(natural, limit)))
    }
}

// MARK: A document

/// A document that was dropped on the perch or summarized from the screen: its summary, and what can
/// be done with it.
struct DocumentContent: View {
    let perch: PerchController

    var body: some View {
        if let doc = perch.dropped {
            let summarized = doc.summary != nil
            // Before anything is done with it the panel says what the file is; its length is in that line.
            PerchSection(
                perch: perch, kind: .document, title: doc.imported.title, meta: summarized || doc.summarizing ? "\(doc.minutes) min read" : "",
                resizable: summarized || doc.summarizing, close: { perch.dropped = nil }
            ) {
                if doc.summarizing {
                    // The summary fills in as it is written: each section in reading order, no overview,
                    // with one quiet line saying how far it has got.
                    if let draft = perch.reader.summaryDraft, !draft.isEmpty {
                        PerchScroll(limit: perch.bodyLimit(for: .document, chrome: 132)) {
                            VStack(alignment: .leading, spacing: 10) {
                                MarkdownText(draft, size: perch.isTall(.document) ? 13.5 : 13)
                                    .textSelection(.enabled)
                                SummaryProgressLine(progress: perch.reader.summaryProgress)
                            }
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        }
                    } else {
                        SummaryProgressLine(progress: perch.reader.summaryProgress)
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let summary = doc.summary {
                    PerchScroll(limit: perch.bodyLimit(for: .document, chrome: 108)) {
                        MarkdownText(summary.isEmpty ? "There was not enough to summarize." : summary, size: perch.isTall(.document) ? 13.5 : 13)
                            .textSelection(.enabled)
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    }
                } else {
                    DroppedFileBody(perch: perch, doc: doc)
                }
            } foot: {
                if summarized {
                    PerchAct(perch: perch, title: "Copy", primary: true, action: perch.copyDroppedSummary)
                    if Features.on(.read) {
                        PerchAct(perch: perch, title: "Read aloud", action: perch.readDroppedSummary)
                            .accessibilityLabel("Read the summary aloud")
                    }
                    if doc.saved != nil {
                        PerchAct(perch: perch, title: "Open in Library") {
                            perch.dropped = nil
                            perch.openLibrary()
                        }
                    } else {
                        // Text from the screen is not kept unless asked.
                        PerchAct(perch: perch, title: "Keep in Library", action: perch.keepDroppedInLibrary)
                    }
                    if Features.on(.read) || (Features.shared.set.records && perch.recorder.phase == .recording && doc.url != nil) {
                        PerchIconButton(perch: perch, symbol: "chirp.more", label: "More for this document", size: 12, side: 26, action: perch.showDocumentMenu)
                    }
                } else if doc.summarizing {
                    // Stops the summary (closing the card does the same).
                    PerchAct(perch: perch, title: "Cancel") { perch.dropped = nil }
                } else {
                    // The actions are in the panel itself, each with a few words; the foot says what happens to the file.
                    Text(doc.saved == nil ? "Not saved unless you keep it" : "Kept in Documents").padding(.leading, 6)
                }
            }
        }
    }
}

/// The one line under a summary that is being written: "Summarizing part 7 of 35", or "Writing a summary" for a short one.
struct SummaryProgressLine: View {
    let progress: (part: Int, of: Int)?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progress.map { "Summarizing part \($0.part) of \($0.of)" } ?? "Writing a summary").foregroundStyle(GlassFill.quiet)
        }
    }
}

// MARK: Finished notes

/// A recording's notes, shown when they are ready. They stay until closed.
struct NotesContent: View {
    let perch: PerchController

    var body: some View {
        if let item = perch.finished {
            PerchSection(
                perch: perch, kind: .notes, title: item.title.isEmpty ? "Your notes" : item.title, meta: Self.detail(item),
                close: { perch.finished = nil }
            ) {
                PerchScroll(limit: perch.bodyLimit(for: .notes)) {
                    MarkdownText(item.summary, size: perch.isTall(.notes) ? 13.5 : 13).textSelection(.enabled)
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                }
            } foot: {
                PerchAct(perch: perch, title: "Open in Library", primary: true, action: perch.openFinished)
                PerchAct(perch: perch, title: "Copy", action: perch.copyFinished)
                if Features.on(.read) { PerchAct(perch: perch, title: "Read aloud", action: perch.readFinished) }
            }
            .accessibilityIdentifier("perch.noteCard")
        }
    }

    /// "voice note, 2 min"
    private static func detail(_ item: SavedItem) -> String {
        let kind = item.kind == .voiceNote ? "voice note" : "meeting"
        guard item.duration >= 1 else { return kind }
        return "\(kind), \(max(1, Int((item.duration / 60).rounded()))) min"
    }
}

// MARK: Say it as

/// "Say it as", while the perch reads a page in another app: the words just spoken, the last one picked,
/// a field for how it should sound, Preview, and Save to Dictionary. Reading carries on underneath.
struct SayItAsContent: View {
    let perch: PerchController
    @FocusState private var typing: Bool

    var body: some View {
        let reader = perch.reader
        let offer = reader.sayItAs
        PerchSection(perch: perch, kind: .sayItAs, title: "Say it as", meta: offer.map { "“\($0.picked)”" } ?? "", resizable: false, close: { reader.closeSayItAs() }) {
            // As tall as what is in it.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(offer?.words ?? [], id: \.self) { word in
                        let picked = word == offer?.picked
                        Button { reader.pickSayItAs(word) } label: {
                            Text(word).font(.system(size: 12.5, weight: picked ? .semibold : .regular)).lineLimit(1)
                                .foregroundStyle(picked ? PerchStyle.onAmber : GlassFill.ink)
                                .padding(.horizontal, 10).frame(height: PerchStyle.act)
                                .background(picked ? PerchStyle.amber : GlassFill.row, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PerchPress())
                        .accessibilityLabel(word)
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
                HStack(spacing: 8) {
                    Text("Say it as").font(.system(size: 12.5)).foregroundStyle(GlassFill.quiet).fixedSize()
                    TextField("", text: Binding(get: { reader.sayItAs?.text ?? "" }, set: { reader.typeSayItAs($0) }))
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(GlassFill.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PerchStyle.amber.opacity(typing ? 0.7 : 0), lineWidth: 2))
                        .focused($typing)
                        .onSubmit { reader.saveSayItAs() }
                        .accessibilityLabel("Say \(offer?.picked ?? "it") as")
                        .accessibilityIdentifier("sayItAs.field")
                    PerchAct(perch: perch, title: "Preview", symbol: "chirp.play") { reader.previewSayItAs() }
                        .accessibilityLabel("Hear it")
                }
                if let problem = offer?.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color.caution)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
            .onAppear { typing = true }
        } foot: {
            PerchAct(perch: perch, title: "Save to Dictionary", primary: true, key: "↵") { reader.saveSayItAs() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sayItAs.save")
        }
    }
}

// MARK: Writing suggestions

/// Every suggestion for the text field in front, each applied with a click: a count on the perch, and
/// the list behind it to review them all.
struct FixesContent: View {
    let perch: PerchController

    var body: some View {
        let checks = perch.underlines
        let issues = checks.shown
        let fixable = issues.contains { $0.category != .style && !$0.suggestions.isEmpty }
        let reviewing = perch.fixCursor != nil
        if let off = checks.off {
            // Switched off from here: it says so, and one press brings the suggestions back.
            PerchSection(perch: perch, kind: .fixes, title: off, resizable: false, close: { perch.showFixes = false }) {
                EmptyView()
            } foot: {
                PerchAct(perch: perch, title: "Turn on", primary: true) {
                    checks.turnBackOn()
                    perch.showFixes = false
                }
                PerchAct(perch: perch, title: "Rephrase…", action: perch.rephrase)
            }
        } else {
            PerchSection(
                perch: perch, kind: .fixes, title: "\(issues.count) \(issues.count == 1 ? "suggestion" : "suggestions")",
                meta: checks.appName.isEmpty ? "" : "in \(checks.appName)", close: { perch.showFixes = false }
            ) {
                ScrollViewReader { proxy in
                    PerchScroll(limit: perch.bodyLimit(for: .fixes, chrome: 108)) {
                        // A plain stack, rebuilt whenever the text changes: a lazy one kept showing rows from before
                        // a fix, with the old words' positions read against the new text.
                        VStack(spacing: 0) {
                            ForEach(Array(issues.prefix(PerchController.fixRowLimit).enumerated()), id: \.offset) { index, issue in
                                FixRow(perch: perch, issue: issue, flagged: issue.flagged(in: checks.text), chosen: perch.fixCursor == index).id(index)
                            }
                        }
                        .id(checks.text.count &+ issues.count &* 31)
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                    }
                    // The row the keyboard is on is kept in view.
                    .onChange(of: perch.fixCursor) { _, row in
                        if let row { withAnimation(PerchStyle.quick) { proxy.scrollTo(row, anchor: .center) } }
                    }
                }
            } foot: {
                if fixable {
                    PerchAct(perch: perch, title: "Fix all", primary: true, key: reviewing ? "⌘↵" : nil) { checks.fixAll() }
                        .help("Fixes every spelling and grammar mistake. Style suggestions are left to you.")
                        .accessibilityHint("Fixes every spelling and grammar mistake. Style suggestions are left to you.")
                }
                if reviewing {
                    // With the keyboard in the list, the foot says what the keys do.
                    hint("↑↓", "move")
                    hint("⌫", "dismiss")
                } else {
                    PerchAct(perch: perch, title: "Rephrase…", action: perch.rephrase)
                    PerchAct(perch: perch, title: "Off for an hour") {
                        checks.pause(hours: 1)
                        perch.showFixes = false
                    }
                    if !checks.appName.isEmpty {
                        PerchAct(perch: perch, title: "Off in \(checks.appName)") {
                            checks.turnOffForThisApp()
                            perch.showFixes = false
                        }
                    }
                }
            }
            .animation(PerchStyle.quick, value: issues.count)
        }
    }

    /// A key and the word for what it does.
    private func hint(_ key: String, _ does: String) -> some View {
        HStack(spacing: 4) {
            PerchKey(text: key)
            Text(does).font(.system(size: 11.5)).foregroundStyle(GlassFill.quiet)
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(key) to \(does)")
    }
}

/// One suggestion in the list: the word as written, what it becomes, and a way to dismiss it.
private struct FixRow: View {
    let perch: PerchController
    let issue: WritingIssue
    /// The words the suggestion is about, as they are in the text now.
    let flagged: String
    /// The keyboard is on this row.
    var chosen = false

    var body: some View {
        let checks = perch.underlines
        HStack(spacing: 0) {
            Button {
                if let fix = issue.suggestions.first { checks.apply(fix, to: issue) }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: issue.category.color)).frame(width: 7, height: 7)
                    if let fix = issue.suggestions.first {
                        Text(flagged).strikethrough().foregroundStyle(GlassFill.quiet).lineLimit(1)
                        Text("→").foregroundStyle(GlassFill.quiet).accessibilityLabel("becomes")
                        Text(issue.label(for: fix, in: checks.text)).fontWeight(.semibold).lineLimit(1)
                    } else {
                        Text(flagged).fontWeight(.semibold).lineLimit(1)
                        Text(Proofreading.plain(issue.message)).foregroundStyle(GlassFill.quiet).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if chosen, !issue.suggestions.isEmpty { PerchKey(text: "↵") }
                }
                .padding(.leading, 6).frame(height: 32).contentShape(Rectangle())
            }
            .buttonStyle(PerchPress())
            .disabled(issue.suggestions.isEmpty)
            .help(Proofreading.plain(issue.message))
            .accessibilityHint(Proofreading.plain(issue.message))
            Button {
                checks.dismiss(issue)
            } label: {
                Image("chirp.close").font(.system(size: 9, weight: .semibold)).foregroundStyle(GlassFill.quiet)
                    .frame(width: 30, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(PerchPress())
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GlassFill.row).opacity(chosen ? 1 : 0))
        // The whole row lights up, the dismiss button with it.
        .lit(by: perch)
    }
}
