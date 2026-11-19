import XCTest

@testable import ChirpCore

final class FeaturesTests: XCTestCase {
    func testEverythingIsOnUntilSwitchedOff() {
        let fresh = FeatureSet(read: { _ in nil })
        XCTAssertEqual(fresh, .all)
        let saved = FeatureSet(read: { $0 == "feature.notes" ? false : nil })
        XCTAssertFalse(saved.isOn(.notes))
        XCTAssertEqual(saved.ordered, [.dictate, .meetings, .read, .write, .summarize])
    }

    func testTheOldRecordSwitchIsReadForMeetingsAndNotes() {
        // Saved off before the split: both stay off.
        let old = FeatureSet(read: { $0 == "feature.record" ? false : nil })
        XCTAssertFalse(old.isOn(.meetings))
        XCTAssertFalse(old.isOn(.notes))
        XCTAssertEqual(old.ordered, [.dictate, .read, .write, .summarize])
        // A switch saved since wins over the old one.
        let since = FeatureSet(read: { $0 == "feature.record" ? false : $0 == "feature.notes" ? true : nil })
        XCTAssertFalse(since.isOn(.meetings))
        XCTAssertTrue(since.isOn(.notes))
        XCTAssertEqual(FeatureSet(read: { $0 == "feature.record" ? true : nil }), .all)
    }

    func testALinkSwitchesNamedFeaturesAndLeavesTheRest() {
        let next = FeatureSet.all.applying(["dictate": "0", "notes": "1", "path": "/tmp/x"])
        XCTAssertFalse(next.isOn(.dictate))
        XCTAssertTrue(next.isOn(.notes))
        // "record" is both, as the old switch was; a named one wins.
        let both = FeatureSet.all.applying(["record": "0", "notes": "1"])
        XCTAssertFalse(both.isOn(.meetings))
        XCTAssertTrue(both.isOn(.notes))
        XCTAssertTrue(next.isOn(.read))
        XCTAssertEqual(FeatureSet.all.applying(["write": "maybe"]), .all)
    }

    func testAllThenOneNamed() {
        let onlyDictate = FeatureSet.all.applying(["all": "0", "dictate": "1"])
        XCTAssertEqual(onlyDictate.on, [.dictate])
        XCTAssertEqual(FeatureSet.none.applying(["all": "1"]), .all)
        XCTAssertEqual(onlyDictate.state, ["dictate": true, "meetings": false, "notes": false, "read": false, "write": false, "summarize": false])
    }

    func testSpeechStaysWhileDictateOrRecordNeedsIt() {
        var set = FeatureSet.all
        set.set(.dictate, false)
        XCTAssertTrue(set.needs(.speech))
        XCTAssertEqual(set.modelsToUnload(after: .all), [])
        let before = set
        set.set(.meetings, false)
        // Notes still listens.
        XCTAssertTrue(set.needs(.speech))
        XCTAssertEqual(set.modelsToUnload(after: before), [.speakers])
        let noNotes = set
        set.set(.notes, false)
        XCTAssertFalse(set.needs(.speech))
        XCTAssertEqual(set.modelsToUnload(after: noNotes), [.speech])
    }

    func testLanguageGoesOnlyWhenNothingOnNeedsIt() {
        let onlyRead = FeatureSet(on: [.read])
        XCTAssertFalse(onlyRead.needs(.language))
        XCTAssertTrue(onlyRead.needs(.voice))
        XCTAssertEqual(onlyRead.modelsToUnload(after: FeatureSet(on: [.read, .summarize])), [.language])
        for feature in [Feature.meetings, .write, .summarize] {
            XCTAssertTrue(FeatureSet(on: [feature]).needs(.language), "\(feature)")
        }
        // Dictation is cleaned up by rule, and Chirp never writes into a note: neither loads the language model.
        XCTAssertFalse(FeatureSet(on: [.dictate]).needs(.language))
        XCTAssertFalse(FeatureSet(on: [.notes]).needs(.language))
        XCTAssertEqual(FeatureSet(on: [.dictate]).modelsToUnload(after: FeatureSet(on: [.dictate, .write])), [.language])
    }

    func testVoiceGoesWithReadAloud() {
        var set = FeatureSet.all
        set.set(.read, false)
        XCTAssertEqual(set.modelsToUnload(after: .all), [.voice])
        XCTAssertEqual(FeatureSet.all.modelsToUnload(after: set), [])
    }

    func testPagesFollowTheirFeatures() {
        let onlyDictate = FeatureSet(on: [.dictate])
        XCTAssertEqual(FeaturePage.allCases.filter(onlyDictate.shows), [.dictations, .dictionary, .snippets, .style])
        // A transcribed file or link is a document, so Meetings or Notes brings the Documents page with it.
        XCTAssertEqual(Set(FeaturePage.allCases.filter(FeatureSet(on: [.meetings]).shows)), [.meetings, .documents, .dictionary])
        XCTAssertEqual(Set(FeaturePage.allCases.filter(FeatureSet(on: [.notes]).shows)), [.voiceNotes, .documents, .dictionary])
        XCTAssertEqual(FeaturePage.allCases.filter(FeatureSet.none.shows), [])
        XCTAssertEqual(FeaturePage.allCases.filter(FeatureSet.all.shows), FeaturePage.allCases)
        XCTAssertTrue(FeatureSet(on: [.summarize]).shows(.documents))
        XCTAssertTrue(FeatureSet(on: [.read]).shows(.documents))
        // Writing checks live in other apps: they bring no page of their own.
        XCTAssertEqual(FeaturePage.allCases.filter(FeatureSet(on: [.write]).shows), [.dictionary, .snippets, .style])
    }

    func testSavedItemsAreListedWhileTheirPageIs() {
        XCTAssertEqual(Set(FeatureSet.all.shownKinds), Set(ItemKind.allCases))
        XCTAssertEqual(FeatureSet(on: [.dictate]).shownKinds, [.dictation])
        XCTAssertEqual(Set(FeatureSet(on: [.meetings]).shownKinds), [.meeting, .document, .note])
        XCTAssertEqual(Set(FeatureSet(on: [.notes]).shownKinds), [.voiceNote, .document, .note])
        XCTAssertEqual(FeatureSet.none.shownKinds, [])
        // A draft saved before "Check a draft" was removed is listed with the documents.
        XCTAssertFalse(FeatureSet(on: [.write]).shows(ItemKind.note))
        XCTAssertTrue(FeatureSet(on: [.read]).shows(ItemKind.note))
    }

    func testADroppedDocumentOffersOnlyWhatIsOn() {
        XCTAssertEqual(FeatureSet.all.dropOffers(isFile: true), [.read, .summarize, .record])
        XCTAssertEqual(FeatureSet.all.dropOffers(isFile: false), [.read, .summarize])
        XCTAssertEqual(FeatureSet(on: [.write]).dropOffers(isFile: true), [])
        XCTAssertEqual(FeatureSet(on: [.notes, .summarize]).dropOffers(isFile: true), [.summarize, .record])
        XCTAssertEqual(FeatureSet.none.dropOffers(isFile: true), [])
    }

    func testWhatADropNeeds() {
        XCTAssertTrue(FeatureSet(on: [.meetings]).takesDrop(audio: true))
        XCTAssertTrue(FeatureSet(on: [.notes]).takesDrop(audio: true))
        XCTAssertFalse(FeatureSet(on: [.read, .write, .summarize, .dictate]).takesDrop(audio: true))
        XCTAssertTrue(FeatureSet(on: [.notes]).takesDrop(audio: false))
        XCTAssertFalse(FeatureSet(on: [.dictate]).takesDrop(audio: false))
    }
}
