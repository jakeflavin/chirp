import Foundation

/// A calendar event that could be a meeting to record.
public struct CalendarMeeting: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// The other people invited, by name.
    public var attendees: [String]
    /// True when the event has a link to a video call.
    public var hasCallLink: Bool
    /// The event's own description, as written in the calendar.
    public var details: String
    public var location: String
    /// Links found in the event (its URL, and any in the description or location).
    public var links: [String]
    /// An event for the whole day (a birthday, a holiday, a trip), which is never a meeting to record.
    public var allDay: Bool

    public init(
        id: String, title: String, start: Date, end: Date, attendees: [String] = [], hasCallLink: Bool = false,
        details: String = "", location: String = "", links: [String] = [], allDay: Bool = false
    ) {
        self.allDay = allDay
        self.details = details
        self.location = location
        self.links = links
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.hasCallLink = hasCallLink
    }

    /// A meeting with other people, rather than a block of time the user set aside for themselves.
    public var isWithOthers: Bool { !attendees.isEmpty || hasCallLink }

    /// Whether this can be the meeting a recording belongs to: a timed event with other people invited or
    /// a link to a call. A game on a sports calendar, a reminder or a block of focus time has neither, and
    /// must never name a recording, be offered for recording, or be handed to the notes as what was discussed.
    public var isMeeting: Bool { !allDay && isWithOthers }
}

/// Matching recordings to calendar events.
public enum MeetingCalendar {
    /// How near to its start an event must be for a recording begun now to be taken as that meeting:
    /// within 15 minutes of the moment a call is noticed.
    public static let window: TimeInterval = 15 * 60

    /// The meeting a recording that starts at `now` belongs to, if any. Only an event that `isMeeting`
    /// counts, and only when it starts within fifteen minutes either side of now; with `onCall` (a call app
    /// has the microphone) one that is still under way counts too, for a recording begun late. The one
    /// starting nearest to now wins.
    public static func current(_ events: [CalendarMeeting], at now: Date, onCall: Bool = false) -> CalendarMeeting? {
        events.filter { event in
            guard event.isMeeting else { return false }
            if abs(event.start.timeIntervalSince(now)) <= window { return true }
            return onCall && event.start <= now && now <= event.end
        }
        .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// A meeting with other people that is starting right now (from a minute before to two minutes after
    /// its start) and has not been offered yet.
    public static func starting(_ events: [CalendarMeeting], at now: Date, alreadyOffered: Set<String>) -> CalendarMeeting? {
        events.filter {
            $0.isMeeting && !alreadyOffered.contains($0.id)
                && now >= $0.start.addingTimeInterval(-60) && now <= $0.start.addingTimeInterval(120)
        }
        .min { $0.start < $1.start }
    }

    /// The people invited, from what a saved recording keeps as its source. A recording made from a file
    /// or a link keeps the file's place or the link there instead, and has nobody invited.
    public static func people(fromSource source: String?) -> [String] {
        guard let source, !source.hasPrefix("/"), link(fromSource: source) == nil else { return [] }
        return names(from: source)
    }

    /// The link a recording was transcribed from, when it was.
    public static func link(fromSource source: String?) -> URL? {
        guard let source, source.hasPrefix("http://") || source.hasPrefix("https://") else { return nil }
        return MediaLink.url(from: source)
    }

    /// Attendee names as stored with a saved meeting.
    public static func names(from stored: String?) -> [String] {
        (stored ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
