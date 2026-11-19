import Foundation
import Testing

@testable import ChirpCore

@Suite struct PerchArrangementTests {
    @Test func theDefaultSetIsFiveOnThePerchAndTwoInTheExtendedArea() {
        let standard = PerchArrangement.standard
        #expect(standard.bar == [.dictate, .note, .read, .fix, .summarize])
        #expect(standard.extended == [.meeting, .rephrase])
        #expect(standard.unplaced == [.snippet, .typeAgain, .library])
    }

    @Test func draggingToTheFrontMovesItAndASixthPushesTheLastOne() {
        var a = PerchArrangement.standard
        a.put(.read, in: .bar, at: 0)
        #expect(a.bar == [.read, .dictate, .note, .fix, .summarize])
        a.put(.library, in: .bar, at: 2)
        #expect(a.bar == [.read, .dictate, .library, .note, .fix])
        #expect(a.extended == [.summarize, .meeting, .rephrase])
        // Each action sits in one place.
        a.put(.meeting, in: .bar, at: 0)
        #expect(a.bar.first == .meeting && !a.extended.contains(.meeting))
        #expect(a.bar.count == 5)
    }

    @Test func fewerThanFiveIsFineAndRemovedOnesGoToTheMenu() {
        var a = PerchArrangement.standard
        a.remove(.summarize)
        a.remove(.rephrase)
        #expect(a.bar == [.dictate, .note, .read, .fix])
        #expect(a.unplaced.contains(.summarize) && a.unplaced.contains(.rephrase))
        a.put(.rephrase, in: .extended, at: 9)
        #expect(a.extended == [.meeting, .rephrase])
    }

    @Test func switchedOffActionsLeaveAndTheOthersCloseUp() {
        var off = FeatureSet.all
        off.set(.notes, false)
        off.set(.meetings, false)
        let shown = PerchArrangement.standard.shown(off)
        #expect(shown.bar == [.dictate, .read, .fix, .summarize])
        #expect(shown.extended == [.rephrase])
        var noWriting = FeatureSet.all
        noWriting.set(.write, false)
        #expect(PerchArrangement.standard.shown(noWriting).extended == [.meeting])
    }

    @Test func itIsSavedAndReadBack() {
        var a = PerchArrangement.standard
        a.put(.library, in: .extended, at: 0)
        #expect(PerchArrangement(json: a.json) == a)
        #expect(PerchArrangement(json: nil) == .standard)
        #expect(PerchArrangement(json: "{not json") == .standard)
        // A name from a later version is left out.
        #expect(PerchArrangement(json: #"{"bar":["dictate","teleport"],"extended":[]}"#).bar == [.dictate])
    }

    // After Customize Perch (a drag into the extended area, Default Set, Done) the saved order came out
    // Summarize before Fix. The sheet read a drop's position as an index into the row as drawn, and a drop
    // is delivered only once its data has loaded, so on a busy Mac one let go before Default Set could land
    // after it, at a position taken from the old row.
    @Test func aDropFromBeforeDefaultSetDoesNotReorderTheDefaultSet() {
        // The case as it happened: Fix dragged toward the end of the perch, Default Set, then the drop.
        var a = PerchArrangement.standard
        let drag = PerchDrag(action: .fix, version: 0)
        a.put(.snippet, in: .extended, at: 2) // version 1: Snippet dragged into the extended area
        a = .standard // version 2: Default Set
        let current = 2
        // What the old code did with the late drop: Fix last on the perch, after Summarize.
        var old = a
        old.put(.fix, in: .bar, at: old.bar.count - 1)
        #expect(old.bar == [.dictate, .note, .read, .summarize, .fix])
        // Now: the drop began in an older version, so it is ignored and the Default Set stands.
        if drag.applies(in: current) { a.drop(drag.action, in: .bar, before: nil) }
        #expect(a == .standard)
        #expect(a.bar.firstIndex(of: .fix)! < a.bar.firstIndex(of: .summarize)!)
    }

    @Test func aDropLandsBeforeTheTileItWasLetGoOver() {
        var a = PerchArrangement.standard
        a.drop(.summarize, in: .bar, before: .fix)
        #expect(a.bar == [.dictate, .note, .read, .summarize, .fix])
        a.drop(.fix, in: .bar, before: .summarize)
        #expect(a.bar == PerchArrangement.standard.bar)
        // Dropped on itself or just after itself: nothing moves.
        a.drop(.fix, in: .bar, before: .fix)
        a.drop(.read, in: .bar, before: .fix)
        #expect(a == .standard)
        // The end of a row puts it last; from All actions into the extended area.
        a.drop(.snippet, in: .extended, before: nil)
        #expect(a.extended == [.meeting, .rephrase, .snippet])
        a.drop(.dictate, in: .bar, before: nil)
        #expect(a.bar == [.note, .read, .fix, .summarize, .dictate])
    }

    @Test func aDropAmongShownActionsKeepsSwitchedOffOnesInPlace() {
        // Notes switched off: Note is not drawn, but keeps its place.
        var a = PerchArrangement.standard
        a.drop(.summarize, in: .bar, before: .read)
        #expect(a.bar == [.dictate, .note, .summarize, .read, .fix])
    }

    @Test func aDragCarriesItsVersion() {
        let drag = PerchDrag(action: .rephrase, version: 7)
        #expect(PerchDrag(payload: drag.payload) == drag)
        #expect(drag.applies(in: 7) && !drag.applies(in: 8))
        // A bare name (no version) never applies; nonsense is not a drag.
        #expect(PerchDrag(payload: "fix")?.applies(in: 0) == false)
        #expect(PerchDrag(payload: "teleport@1") == nil)
        #expect(PerchDrag(payload: "default") == nil)
    }
}
