import ChirpCore
import EventKit
import Foundation
import Observation

/// Reads today's meetings from the Mac's calendars, so recordings get their real title and the names
/// of the people invited, and Chirp can offer to record as a meeting starts. Read-only; nothing is changed.
@MainActor
@Observable
final class CalendarReader {
    static let shared = CalendarReader()

    private let store = EKEventStore()
    /// Whether macOS lets Chirp read the calendar.
    private(set) var allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    /// Events from the last read, kept for a minute so the calendar is not asked every few seconds.
    private var cache: [CalendarMeeting] = []
    private var cachedAt = Date.distantPast
    /// Stand-in events for automated runs, which have no calendar access.
    private var fake: [CalendarMeeting]?

    /// Whether the user wants the calendar used at all.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "useCalendar") }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: "useCalendar") as? Bool ?? true
        LinkHandler.commands["calendar-fake"] = { [weak self] q in
            // `link=0` for an event with no call link, `allday=1` for an all-day one, `links` for web links in it,
            // `minutes` for how long it lasts: an event that is not a meeting can be stood in for too.
            let start = Date().addingTimeInterval((Double(q["in"] ?? "0") ?? 0) * 60)
            self?.fake = [
                CalendarMeeting(
                    id: q["id"] ?? "fake", title: q["title"] ?? "Planning", start: start,
                    end: start.addingTimeInterval((Double(q["minutes"] ?? "30") ?? 30) * 60),
                    attendees: MeetingCalendar.names(from: q["attendees"]), hasCallLink: q["link"] != "0", details: q["details"] ?? "",
                    links: MeetingCalendar.names(from: q["links"]), allDay: q["allday"] == "1")
            ]
        }
    }

    /// Checks the Calendar permission again.
    func refresh() { allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks macOS for the calendar, then forgets the cached events.
    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refresh()
        cachedAt = .distantPast
        Log.write("permissions", "calendar: \(allowed ? "allowed" : "not allowed")")
    }

    /// Timed events from the last twelve hours to the next twelve, without ones the user declined.
    func events() -> [CalendarMeeting] {
        if let fake { return fake }
        guard enabled, allowed else { return [] }
        if Date().timeIntervalSince(cachedAt) < 60 { return cache }
        let predicate = store.predicateForEvents(
            withStart: Date().addingTimeInterval(-12 * 3600), end: Date().addingTimeInterval(12 * 3600), calendars: nil)
        cache = store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled, let id = event.eventIdentifier else { return nil }
            let people = event.attendees ?? []
            if people.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
            let names = people.filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
            // Where a call link can be: the event's own link, its place and its notes.
            let places = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
            let text = places.lowercased()
            let link = ["zoom.us", "meet.google", "teams.microsoft", "teams.live", "webex.com", "facetime.apple", "whereby.com"].contains { text.contains($0) }
            return CalendarMeeting(
                id: id + "@\(Int(event.startDate.timeIntervalSince1970))", title: event.title ?? "Meeting", start: event.startDate,
                end: event.endDate, attendees: names, hasCallLink: link, details: event.notes ?? "", location: event.location ?? "",
                links: Self.links(in: places))
        }
        cachedAt = Date()
        return cache
    }

    /// Web links in a piece of text, each once, in order.
    static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { $0.url }.filter { $0.scheme?.hasPrefix("http") == true }.map(\.absoluteString)
            .filter { seen.insert($0).inserted }
    }

    /// The meeting on the calendar that a recording started now would belong to, if any. `onCall` when a
    /// call app has the microphone, which lets a meeting already under way count.
    func current(onCall: Bool = false) -> CalendarMeeting? { MeetingCalendar.current(events(), at: Date(), onCall: onCall) }
}
