import AppKit
import ChirpCore
import SwiftUI

// The panel that opens from the perch while a recording runs. One timeline of what
// was said, the notes sent and the pictures kept, then the field a note is typed in. Enter keeps the
// note with its time; the camera keeps a picture of the window in front the same way. It is the same
// panel for a voice note and a meeting, and it is only as tall as what is in it.

/// The corner shape of something the user sent: round, with the corner nearest the field squared off.
private func sentShape(_ radius: CGFloat, tail: CGFloat) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: tail, topTrailingRadius: radius, style: .continuous)
}

struct RecordingPanel: View {
    let perch: PerchController
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var recorder = perch.recorder
        let upright = perch.upright
        let meeting = recorder.kind == .meeting
        let entries = MeetingText.timeline(lines: MeetingText.merged(recorder.shownSegments), notes: recorder.timedNotes)
        // Beside an upright column the panel is as tall as the column: the field takes the free height, so
        // there is no empty gap. With nothing sent yet it has the foot's room too.
        let fills = upright
        let bare = upright && recorder.timedNotes.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            head(recorder, upright: upright)
            if let warning = recorder.warning {
                Text(warning).font(.system(size: 12)).foregroundStyle(Color.caution).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, upright ? 14 : 16).padding(.top, 8)
            }
            RecordingTimeline(entries: entries, meeting: meeting, limit: perch.bodyLimit(for: .meetingNotes, chrome: 150), inset: upright ? 14 : 16)
            send(recorder, upright: upright, fills: fills)
            if !bare { foot(recorder, meeting: meeting, upright: upright) }
        }
        .accessibilityIdentifier("perch.recording")
    }

    /// What it is, how long it has run, Stop, and the arrow that folds the panel away. Beside an upright
    /// column the clock and Stop are in the column, so the head has the kind and a close button.
    private func head(_ recorder: MeetingRecorder, upright: Bool) -> some View {
        HStack(spacing: 8) {
            if !upright {
                Circle().fill(recorder.warning == nil ? PerchStyle.red : Color.caution).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(recorder.kind.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
            if !upright {
                Text(recorder.elapsed.clock).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(GlassFill.quiet)
                    .accessibilityLabel("Recording for \(recorder.elapsed.clock)")
            }
            Spacer(minLength: 8)
            if !upright {
                Button { recorder.stop() } label: {
                    HStack(spacing: 5) {
                        Image("chirp.stop").font(.system(size: 9, weight: .semibold))
                        Text("Stop").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.leading, 8).padding(.trailing, 10).frame(height: 26)
                    .background(PerchStyle.red, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PerchPress())
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("perch.recording.stop")
            }
            PerchIconButton(perch: perch, symbol: upright ? "chirp.close" : "chirp.disclose", label: upright ? "Close" : "Fold the notes away", size: 11, side: 26) {
                perch.showMeetingNotes = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, upright ? 14 : 18).padding(.trailing, 10).padding(.top, 12)
    }

    /// The field a note is typed in, sent with Enter, and the button that keeps a picture.
    private func send(_ recorder: MeetingRecorder, upright: Bool, fills: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(alignment: fills ? .top : .center, spacing: 8) {
                TextField("Type a note", text: $typed, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .focused($typing)
                    .onSubmit(sendNote)
                    .onKeyPress(.return, phases: .down) { press in
                        // Enter sends; with Option or Shift it starts a new line in the note.
                        guard press.modifiers.isDisjoint(with: [.option, .shift]) else { return .ignored }
                        sendNote()
                        return .handled
                    }
                    .accessibilityLabel("A note. Enter keeps it with the time.")
                    .accessibilityIdentifier("perch.recording.note")
                PerchKey(text: "↵").fixedSize()
            }
            .padding(.leading, 13).padding(.trailing, 8).padding(.vertical, 6)
            .frame(minHeight: 34, maxHeight: fills ? .infinity : nil, alignment: fills ? .top : .center)
            .background(GlassFill.row, in: RoundedRectangle(cornerRadius: fills ? 14 : 17, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { typing = true }
            Button {
                Task { await recorder.capture() }
            } label: {
                Image("chirp.camera").font(.system(size: 14, weight: .medium)).foregroundStyle(GlassFill.ink)
                    .frame(width: 34, height: 34).background(GlassFill.row, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(PerchPress())
            .disabled(recorder.capturing)
            .help("Keep a picture of the window in front")
            .accessibilityLabel("Capture the window in front")
            .accessibilityIdentifier("perch.recording.capture")
        }
        .padding(.leading, upright ? 12 : 14).padding(.trailing, upright ? 10 : 12).padding(.top, 8).padding(.bottom, fills ? 8 : 4)
        .frame(maxHeight: fills ? .infinity : nil)
    }

    /// The last row: what happens to a voice note, or the switch for this Mac's sound in a meeting.
    private func foot(_ recorder: MeetingRecorder, meeting: Bool, upright: Bool) -> some View {
        @Bindable var recorder = recorder
        return HStack(spacing: 6) {
            if meeting {
                Toggle("Include this Mac’s sound", isOn: $recorder.includesComputerSound)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                    .help("On by itself during a call. Turn it on to take notes on a video or a recorded meeting.")
                    .accessibilityIdentifier("perch.recording.sound")
            } else {
                Text(upright ? "Saved to Notes when you stop." : "Your words only. Saved to Notes when you stop.").lineLimit(1)
            }
            Spacer(minLength: 6)
            PerchKey(text: "esc").fixedSize()
        }
        .foregroundStyle(GlassFill.quiet).font(.system(size: 12))
        .padding(.leading, 12).padding(.trailing, 10).padding(.top, 8).padding(.bottom, upright ? 8 : 2)
        .overlay(alignment: .top) { Rectangle().fill(GlassFill.line).frame(height: 1) }
        .padding(.top, 6)
    }

    private func sendNote() {
        if perch.recorder.sendNote(typed) { typed = "" }
    }
}

/// What was said and what was kept, newest at the bottom and kept in view. Only as tall as what is in
/// it, up to `limit`; beyond that it scrolls.
private struct RecordingTimeline: View {
    let entries: [MeetingText.TimelineEntry]
    let meeting: Bool
    let limit: CGFloat
    let inset: CGFloat
    @State private var natural: CGFloat = 30

    var body: some View {
        let newestLine = entries.last { if case .line = $0 { true } else { false } }?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    Text("Words appear here a few seconds after they are spoken.").font(.system(size: 12)).foregroundStyle(GlassFill.quiet)
                }
                ForEach(entries) { entry in
                    switch entry {
                    case .line(let line): said(line, newest: entry.id == newestLine)
                    case .note(let note): RecordingSent(note: note)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(1, min(natural, limit)))
        .animation(PerchStyle.quick, value: entries.count)
    }

    /// One line of speech: its time, who (in a meeting), and the words. Earlier lines are quieter than the newest.
    private func said(_ line: TranscriptSegment, newest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.start.clock).font(.system(size: 11)).monospacedDigit().foregroundStyle(GlassFill.quiet).frame(width: 32, alignment: .leading)
            Text("""
                \(Text(meeting ? (line.speaker == "Me" ? "You " : "\(line.speaker) ") : "").fontWeight(.semibold)
                .foregroundStyle(line.speaker == "Me" ? Color.accentColor : Color.grammar))\
                \(Text(line.text).foregroundStyle(newest ? GlassFill.ink : GlassFill.quiet))
                """)
                .font(.system(size: 13)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A note or a picture the user kept, at the right like a message that was sent, with its time under it.
struct RecordingSent: View {
    let note: TimedNote

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if note.isPicture {
                KeptPicture(note: note, width: 132, height: 80)
                    .clipShape(sentShape(9, tail: 3))
                    .overlay(sentShape(9, tail: 3).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                Text("\(note.clock) · picture of the front window").font(.system(size: 11)).monospacedDigit().foregroundStyle(GlassFill.quiet)
            } else {
                Text(note.text).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.085), in: sentShape(13, tail: 4))
                Text(note.clock).font(.system(size: 11)).monospacedDigit().foregroundStyle(GlassFill.quiet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.isPicture ? note.line : "Note: " + note.text), at \(note.clock)")
    }
}

/// A kept picture drawn small. Pictures already read from disk are remembered, so drawing again does
/// not read and decode each one again.
struct KeptPicture: View {
    let note: TimedNote
    let width: CGFloat
    let height: CGFloat

    private static let pictures = NSCache<NSURL, NSImage>()

    static func image(for note: TimedNote) -> NSImage? {
        guard let url = MeetingRecorder.pictureURL(note) else { return nil }
        if let known = pictures.object(forKey: url as NSURL) { return known }
        guard let image = NSImage(contentsOf: url) else { return nil }
        pictures.setObject(image, forKey: url as NSURL)
        return image
    }

    var body: some View {
        Group {
            if let image = Self.image(for: note) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06).overlay(Image("chirp.picture").foregroundStyle(Color.quiet))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityLabel(note.line)
    }
}
