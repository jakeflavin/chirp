import ChirpCore
import SwiftUI

/// The rows at the top of a Library list for what is not finished yet, under "Now": the recording being made, from the moment it starts ("Recording · 1:02"),
/// and it opens; a saved meeting whose notes are being written ("Writing notes…") or wait their turn
/// ("Waiting for the link to finish…", with Cancel); a file or link being transcribed, and those
/// waiting to be. All three kinds look and behave alike.
struct NowRows: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(DictationController.self) private var dictation
    let section: LibrarySection
    /// This page's saved items: those whose notes are not written yet are listed here.
    let items: [SavedItem]
    @Binding var selectedID: Int64?

    /// Whether the recording being made belongs on this page.
    static func showsRecording(_ recorder: MeetingRecorder, in section: LibrarySection) -> Bool {
        guard recorder.phase != .idle else { return false }
        switch section {
        case .everything: return true
        case .meetings: return recorder.kind == .meeting
        case .notes: return recorder.kind == .voiceNote
        default: return false
        }
    }

    /// A file or a link becomes a document: its rows are on the Documents page (and Everything).
    static func showsImports(in section: LibrarySection) -> Bool { section == .documents || section == .everything }

    /// Whether this page has anything under "Now", so an otherwise empty page is not called empty.
    static func hasRows(_ recorder: MeetingRecorder, _ dictation: DictationController, section: LibrarySection, items: [SavedItem]) -> Bool {
        showsRecording(recorder, in: section)
            || (showsImports(in: section) && (dictation.importStatus != nil || !Jobs.shared.waitingImports.isEmpty))
            || items.contains { $0.id.flatMap { recorder.notesLine(for: $0) } != nil }
    }

    var body: some View {
        let unfinished = items.filter { $0.id.flatMap { recorder.notesLine(for: $0) } != nil }
        let imports = Self.showsImports(in: section)
        let waiting = imports ? Jobs.shared.waitingImports : []
        let running = imports ? dictation.importStatus : nil
        let live = Self.showsRecording(recorder, in: section) ? recorder.progressRow : nil
        if live != nil || !unfinished.isEmpty || running != nil || !waiting.isEmpty {
            Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.quiet)
                .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if let live {
                row(title: live.title, line: live.line, light: live.live, picked: recorder.liveOpen, id: "library.now.recording") {
                    selectedID = nil
                    recorder.openLive()
                }
            }
            ForEach(unfinished, id: \.id) { item in
                let line = item.id.flatMap { recorder.notesLine(for: $0) } ?? ""
                let state = item.id.flatMap { recorder.notesState(for: $0) }
                let waits = state == .waiting
                row(
                    title: LibraryRows.title(item), line: line, detail: waits ? nil : LibraryRows.length(item.duration),
                    picked: item.id == selectedID && !recorder.liveOpen, id: "library.now.notes",
                    cancel: state == .stopping || state == nil ? nil : { if let id = item.id { recorder.stopNotes(for: id) } },
                    cancelTitle: waits ? "Cancel" : "Stop"
                ) {
                    selectedID = item.id
                }
            }
            if let running {
                row(title: running.name, line: running.line, picked: false, id: "library.importing", cancel: { dictation.cancelImport() }, cancelID: "library.importing.cancel") {}
            }
            ForEach(waiting, id: \.id) { job in
                row(title: job.title, line: job.line, picked: false, id: "library.now.waiting", cancel: { Jobs.shared.cancel(job.id) }) {}
            }
        }
    }

    /// One row: its name, then what is happening to it. The right edge holds Cancel (or Stop) when it can be.
    private func row(
        title: String, line: String, detail: String? = nil, light: Bool = false, picked: Bool, id: String,
        cancel: (() -> Void)? = nil, cancelTitle: String = "Cancel", cancelID: String = "library.now.cancel", open: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                HStack(spacing: 6) {
                    if light { Circle().fill(Color.spelling).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(line).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Color.ink).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Color.quiet).lineLimit(1) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
            Spacer(minLength: 0)
            if let cancel {
                Button(action: cancel) {
                    Text(cancelTitle).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.85))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Color.ink.opacity(0.07), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(cancelID)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(picked ? PageLayout.selected : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, open)
    }
}
