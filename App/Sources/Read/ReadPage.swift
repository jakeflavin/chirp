import ChirpCore
import ChirpML
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Where the reader's page settings are kept. Each is on unless the user turned it off.
enum ReadingChoices {
    static let marksKey = "readMarks"
    static let followKey = "readFollow"
    /// With nothing selected, the read shortcut starts at the sentence the cursor is in.
    static let cursorKey = "readFromCursor"

    /// Mark the sentence and word being read: in Chirp's reader, and in the app the text came from.
    static var marks: Bool { UserDefaults.standard.object(forKey: marksKey) as? Bool ?? true }
    static var fromCursor: Bool { UserDefaults.standard.object(forKey: cursorKey) as? Bool ?? true }
}

/// Settings › Reading: the voice, what is read, and what shows on the page.
struct ReadOptions: View {
    @Environment(ReadController.self) private var reader
    @AppStorage(ReadingChoices.marksKey) private var marks = true
    @AppStorage(ReadingChoices.followKey) private var follow = true
    @AppStorage(ReadingChoices.cursorKey) private var fromCursor = true

    var body: some View {
        @Bindable var reader = reader
        return Form {
            SettingsSection("Voice") {
                Picker("Voice", selection: $reader.voiceID) {
                    ForEach(Voice.voices) { v in Text("\(v.name) · \(v.accent)").tag(v.id) }
                }
                Picker("Speed", selection: $reader.speed) {
                    ForEach(ReadController.speeds, id: \.self) { s in Text(s.speedLabel).tag(s) }
                }
            }
            SettingsSection("What is read") {
                Toggle(isOn: $reader.skipCitations) {
                    Text("Leave out citation marks")
                    Text("Such as [12], (Smith, 2020) and raised note numbers")
                }
                Toggle(isOn: $reader.skipBrackets) {
                    Text("Leave out all text in brackets")
                    Text("Asides such as (see below) or [see Figure 2]")
                }
                Toggle("Read from the cursor when nothing is selected", isOn: $fromCursor)
            }
            SettingsSection("On the page") {
                Toggle(isOn: $marks) {
                    Text("Mark the sentence and word being read")
                    Text("In Chirp’s reader and in other apps")
                }
                Toggle(isOn: $follow) {
                    Text("Scroll to follow the reading")
                    Text("Stops if you scroll away; starts again when you scroll back")
                }
            }
        }
        .formStyle(.grouped)
    }
}
