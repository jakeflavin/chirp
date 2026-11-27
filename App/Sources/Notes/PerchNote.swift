import ChirpCore
import SwiftUI

/// A note in the perch: the perch grown taller around an editor, never a window
/// of its own. A new note opens with the keyboard in it and listening: what is said goes in as it is
/// heard, and the first key typed stops listening and goes in too. Holding right ⌥ puts dictated words
/// at the cursor. × or Escape closes it, saved, once the last words are in; the same note opens full
/// size in Library › Notes.
struct PerchNoteContent: View {
    let perch: PerchController

    var body: some View {
        let notes = perch.notes
        @Bindable var bound = notes
        PerchSection(
            perch: perch, kind: .note, title: "Note", meta: meta(notes),
            close: { notes.close() }
        ) {
            NoteEditor(
                text: $bound.draft, look: .perch, checks: NoteController.checksWriting,
                listening: perch.dictation.phase == .recording, level: perch.dictation.levels.last ?? 0,
                listeningLabel: notes.listening ? "listening" : "hold ⌥",
                focusOnAppear: true, identifier: "perch.note",
                onEdit: { dictated in notes.edited(dictated: dictated) },
                onEscape: { notes.close() },
                onTypingKey: { notes.typedWhileListening() },
                attach: { view in notes.attach(view) }
            )
            .frame(height: perch.bodyLimit(for: .note, chrome: 96))
            .padding(.top, 2)
        } foot: {
            if notes.listening, perch.dictation.phase == .recording {
                PerchAct(perch: perch, title: "Stop listening", symbol: "chirp.mic") { notes.stopListening() }
                    .help("What was heard stays in the note. Typing stops listening too.")
            }
            if notes.listenProblem == "Microphone not allowed" {
                PerchAct(perch: perch, title: "Allow Microphone", symbol: "chirp.mic") {
                    Task { await Permissions.shared.requestMicrophone() }
                }
                .help("Opens System Settings, where Chirp can be allowed to use the microphone")
            }
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

    /// The head row's grey words: listening, finishing, why it is not listening, or saved.
    private func meta(_ notes: NoteController) -> String {
        let hearing = notes.listening && perch.dictation.phase == .recording
        if hearing { return "Listening. Typing stops it." }
        if notes.listening || notes.finishing { return "Writing the last words…" }
        if let problem = notes.listenProblem { return problem }
        return notes.savedAt == nil ? "" : "Saved"
    }
}
