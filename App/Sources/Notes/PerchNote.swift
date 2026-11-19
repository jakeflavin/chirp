import ChirpCore
import SwiftUI

/// A note in the perch: the perch grown taller around an editor, never a window
/// of its own. Typing goes in; holding right ⌥ puts dictated words at the cursor. × or Escape closes it,
/// saved; the same note opens full size in Library › Notes.
struct PerchNoteContent: View {
    let perch: PerchController

    var body: some View {
        let notes = perch.notes
        @Bindable var bound = notes
        PerchSection(
            perch: perch, kind: .note, title: "Note", meta: notes.savedAt == nil ? "" : "Saved",
            close: { notes.close() }
        ) {
            NoteEditor(
                text: $bound.draft, look: .perch, checks: NoteController.checksWriting,
                listening: perch.dictation.phase == .recording, level: perch.dictation.levels.last ?? 0,
                focusOnAppear: true, identifier: "perch.note",
                onEdit: { dictated in notes.edited(dictated: dictated) },
                onEscape: { notes.close() }
            )
            .frame(height: perch.bodyLimit(for: .note, chrome: 96))
            .padding(.top, 2)
        } foot: {
            if Features.on(.notes) {
                PerchAct(perch: perch, title: "Record a voice note", symbol: "chirp.voiceNote") { perch.record() }
                    .help("For talking at length: the audio is kept, and its words become a note")
            }
            PerchAct(perch: perch, title: "Copy", symbol: "chirp.copy") {
                NoteController.copy(markdown: notes.draft)
                perch.say("Copied", seconds: 2)
            }
            .disabled(notes.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note")
    }
}
