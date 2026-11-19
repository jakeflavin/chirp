import XCTest

@testable import ChirpCore

final class HomeLinesTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour, minute: minute))!
    }

    // MARK: The welcome line

    func testGreetingFollowsTheTimeOfDay() {
        XCTAssertEqual(WelcomeLine.greeting(hour: 5), "Good morning")
        XCTAssertEqual(WelcomeLine.greeting(hour: 11), "Good morning")
        XCTAssertEqual(WelcomeLine.greeting(hour: 12), "Good afternoon")
        XCTAssertEqual(WelcomeLine.greeting(hour: 17), "Good afternoon")
        XCTAssertEqual(WelcomeLine.greeting(hour: 18), "Good evening")
        XCTAssertEqual(WelcomeLine.greeting(hour: 2), "Good evening")
    }

    func testTheLineSaysWhatWasCapturedToday() {
        let now = at(14)
        XCTAssertEqual(WelcomeLine.line(.init(), now: now, calendar: calendar), "Nothing captured yet today.")
        XCTAssertEqual(WelcomeLine.line(.init(recordings: 2, documents: 1), now: now, calendar: calendar), "Two meetings and a document today.")
        XCTAssertEqual(WelcomeLine.line(.init(recordings: 1), now: now, calendar: calendar), "A meeting today.")
        XCTAssertEqual(WelcomeLine.line(.init(recordings: 1, notes: 1, documents: 1), now: now, calendar: calendar), "A note, a meeting and a document today.")
        XCTAssertEqual(WelcomeLine.line(.init(documents: 3), now: now, calendar: calendar), "Three documents today.")
        XCTAssertEqual(WelcomeLine.line(.init(recordings: 14, documents: 2), now: now, calendar: calendar), "14 meetings and two documents today.")
    }

    func testAMeetingAboutToStartComesFirst() {
        let now = at(13, 50)
        XCTAssertEqual(
            WelcomeLine.line(.init(recordings: 2, documents: 1, nextMeeting: at(14)), now: now, calendar: calendar),
            "Your 2 pm meeting starts in ten minutes.")
        XCTAssertEqual(WelcomeLine.line(.init(nextMeeting: at(13, 51)), now: now, calendar: calendar), "Your 1:51 pm meeting starts in a minute.")
        XCTAssertEqual(WelcomeLine.line(.init(nextMeeting: at(13, 50)), now: now, calendar: calendar), "Your 1:50 pm meeting starts now.")
        // More than an hour away, or already begun: the day's captures are said instead.
        XCTAssertEqual(WelcomeLine.line(.init(recordings: 1, nextMeeting: at(16)), now: now, calendar: calendar), "A meeting today.")
        XCTAssertEqual(WelcomeLine.line(.init(nextMeeting: at(13)), now: now, calendar: calendar), "Nothing captured yet today.")
    }

    func testClockTimes() {
        XCTAssertEqual(WelcomeLine.clock(at(0), calendar: calendar), "12 am")
        XCTAssertEqual(WelcomeLine.clock(at(9, 5), calendar: calendar), "9:05 am")
        XCTAssertEqual(WelcomeLine.clock(at(12), calendar: calendar), "12 pm")
        XCTAssertEqual(WelcomeLine.clock(at(23, 30), calendar: calendar), "11:30 pm")
    }

    // MARK: This week

    func testWeekCountsOnlyWhatHappenedThisWeek() {
        let start = at(0)
        let old = start.addingTimeInterval(-3600)
        let items = [
            SavedItem(kind: .meeting, duration: 3600, createdAt: at(10)),
            SavedItem(kind: .voiceNote, duration: 3120, createdAt: at(11)),
            SavedItem(kind: .meeting, duration: 9999, createdAt: old),
            SavedItem(kind: .dictation, body: "one two three", createdAt: at(9)),
            SavedItem(kind: .dictation, body: "four five", createdAt: old),
            SavedItem(kind: .document, body: "text", position: 2, createdAt: old, updatedAt: at(12)),
            SavedItem(kind: .document, body: "text", position: 0, createdAt: at(12), updatedAt: at(12)),
        ]
        let week = WeekCounts(items: items, since: start, fixesAccepted: 41)
        XCTAssertEqual(week.recordedSeconds, 6720)
        XCTAssertEqual(week.wordsDictated, 3)
        XCTAssertEqual(week.documentsRead, 1)
        XCTAssertEqual(week.tiles.map(\.value), ["1 h 52 min", "3", "1", "41"])
        XCTAssertEqual(week.tiles.map(\.label), ["recorded", "words dictated", "document read", "fixes accepted"])
    }

    func testACountOfNothingIsLeftOut() {
        XCTAssertTrue(WeekCounts().tiles.isEmpty)
        XCTAssertEqual(WeekCounts(wordsDictated: 3410).tiles, [.init(value: "3,410", label: "words dictated")])
        XCTAssertEqual(WeekCounts(recordedSeconds: 30, fixesAccepted: 1).tiles.map(\.label), ["fix accepted"])
    }

    // MARK: One tip

    func testASentenceDictatedSeveralTimesIsOfferedAsASnippet() {
        let said = ["Thanks, talk soon.", "see you at ten", "thanks, talk soon", "Thanks, talk soon!", "A much longer dictation that goes on and on for well over twelve words in total, so it never counts."]
        let found = HomeTip.repeated(in: said, notIn: [])
        XCTAssertEqual(found?.sentence, "Thanks, talk soon.")
        XCTAssertEqual(found?.times, 3)
        // Already a snippet, or said only twice: nothing.
        XCTAssertNil(HomeTip.repeated(in: said, notIn: ["Thanks, talk soon"]))
        XCTAssertNil(HomeTip.repeated(in: Array(said.prefix(3)), notIn: []))
        XCTAssertNil(HomeTip.repeated(in: ["yes", "yes", "yes", "yes"], notIn: []))
    }

    func testOneTipAtATimeAndQuietAfterADismissal() {
        let now = at(14)
        let facts = HomeTip.Facts(dictations: Array(repeating: "Thanks, talk soon.", count: 6), recordings: 0, dictationCount: 6)
        let tip = HomeTip.pick(facts, dismissed: [], lastDismissal: nil, now: now)
        XCTAssertEqual(tip?.title, "You have dictated “Thanks, talk soon.” six times")
        XCTAssertEqual(tip?.action, .saveSnippet("Thanks, talk soon."))
        // Dismissed a moment ago: nothing at all, so the section stays rare.
        XCTAssertNil(HomeTip.pick(facts, dismissed: [tip!.id], lastDismissal: now.addingTimeInterval(-3600), now: now))
        // Days later the next one is shown, never the dismissed one again.
        let later = HomeTip.pick(facts, dismissed: [tip!.id], lastDismissal: now.addingTimeInterval(-4 * 24 * 3600), now: now)
        XCTAssertEqual(later?.id, "try:note")
    }

    func testAFeatureIsSuggestedOnlyWhenOnAndNeverUsedAndChirpHasBeenUsed() {
        XCTAssertTrue(HomeTip.candidates(.init(dictationCount: 2)).isEmpty)
        XCTAssertEqual(HomeTip.candidates(.init(dictationCount: 9)).map(\.id), ["try:note", "try:read", "try:summarize"])
        XCTAssertEqual(HomeTip.candidates(.init(recordings: 5, notes: 1, documentsHeard: 1, summaries: 0)).map(\.id), ["try:summarize"])
        var off = FeatureSet.all
        off.set(.summarize, false)
        XCTAssertTrue(HomeTip.candidates(.init(features: off, recordings: 5, notes: 1, documentsHeard: 1)).isEmpty)
    }

    // MARK: The menu bar's settings

    func testTheSettingsAreaFollowsWhatIsBeingDone() {
        XCTAssertEqual(MenuSituation.pick(.init(), features: .all), .idle)
        XCTAssertEqual(MenuSituation.pick(.init(checkingWriting: true), features: .all), .writing)
        XCTAssertEqual(MenuSituation.pick(.init(dictating: true, checkingWriting: true), features: .all), .dictating)
        XCTAssertEqual(MenuSituation.pick(.init(recording: true, reading: true), features: .all), .recording)
        XCTAssertEqual(MenuSituation.pick(.init(reading: true), features: .all), .reading)
        var noWrite = FeatureSet.all
        noWrite.set(.write, false)
        XCTAssertEqual(MenuSituation.pick(.init(checkingWriting: true), features: noWrite), .idle)
    }

    func testAtMostFourRowsAndAllSettingsIsLast() {
        for situation in MenuSituation.allCases {
            XCTAssertEqual(situation.rows.last, .allSettings)
            XCTAssertLessThanOrEqual(situation.rows.count - 1, 4)
        }
        XCTAssertEqual(MenuSituation.reading.rows, [.voice, .speed, .citations, .allSettings])
        XCTAssertEqual(MenuSituation.idle.rows, [.features, .perch, .allSettings])
        XCTAssertEqual(MenuSituation.writing.heading(app: "Mail"), "Settings for Mail")
        XCTAssertEqual(MenuSituation.idle.heading(app: "Mail"), "Features")
    }

    // MARK: A dropped file

    func testWhatADroppedFileIs() {
        XCTAssertEqual(DroppedFile.facts(format: "EPUB", pages: 288, listenSeconds: 5 * 3600 + 400), "EPUB book · 288 pages · about 5 h to listen")
        XCTAssertEqual(DroppedFile.facts(format: "PDF", pages: 14, listenSeconds: 25 * 60), "PDF · 14 pages · about 25 min to listen")
        XCTAssertEqual(DroppedFile.facts(format: "", pages: 0, listenSeconds: 20), "Document · about 1 min to listen")
        XCTAssertEqual(DroppedFile.listen(90 * 60), "1 h 30 min")
        XCTAssertEqual(DroppedFile.firstLines("1. Term.\nThis agreement   runs for twenty-four months", limit: 30), "“1. Term. This agreement runs…”")
        XCTAssertEqual(DroppedFile.firstLines("Short one."), "“Short one.”")
        XCTAssertEqual(DroppedFile.firstLines("  \n "), "")
    }

    func testWhatADroppedFileOffers() {
        XCTAssertEqual(DroppedFile.offers(features: .all, recording: false, isFile: true, kept: false), [.read, .summarize, .keep])
        XCTAssertEqual(DroppedFile.offers(features: .all, recording: true, isFile: true, kept: false), [.attach, .read, .summarize, .keep])
        // Text from the screen is no file, so it cannot go with a recording; once kept, Keep goes.
        XCTAssertEqual(DroppedFile.offers(features: .all, recording: true, isFile: false, kept: true), [.read, .summarize])
        var onlyRecord = FeatureSet.none
        onlyRecord.set(.meetings, true)
        XCTAssertEqual(DroppedFile.offers(features: onlyRecord, recording: true, isFile: true, kept: false), [.attach, .keep])
    }

    // MARK: Onboarding

    func testOnboardingLeavesOutStepsForFeaturesThatAreOff() {
        XCTAssertEqual(OnboardingStep.shown(for: .all), OnboardingStep.allCases)
        XCTAssertEqual(OnboardingStep.shown(for: .all).count, 10)
        var set = FeatureSet.all
        set.set(.meetings, false)
        XCTAssertFalse(OnboardingStep.shown(for: set).contains(.recording))
        XCTAssertTrue(OnboardingStep.shown(for: set).contains(.notes))
        set.set(.notes, false)
        XCTAssertFalse(OnboardingStep.shown(for: set).contains(.notes))
        XCTAssertEqual(OnboardingStep.shown(for: .none), [.features, .shortcuts, .permissions, .models])
        var onlyRead = FeatureSet.none
        onlyRead.set(.read, true)
        XCTAssertEqual(OnboardingStep.shown(for: onlyRead), [.features, .shortcuts, .permissions, .models, .reading])
    }

    func testAStepThatGoesAwayFallsBackToTheOneBefore() {
        let shown = OnboardingStep.shown(for: .none)
        XCTAssertEqual(OnboardingStep.keep(.writing, in: shown), .models)
        XCTAssertEqual(OnboardingStep.keep(.dictation, in: shown), .features)
        XCTAssertEqual(OnboardingStep.keep(.models, in: shown), .models)
    }
}
