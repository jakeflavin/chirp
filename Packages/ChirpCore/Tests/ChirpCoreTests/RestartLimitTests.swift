import Foundation
import Testing

@testable import ChirpCore

@Suite struct RestartLimitTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func aFewDeathsAreAllowed() {
        var limit = RestartLimit()
        limit.died(at: start)
        limit.died(at: start)
        #expect(limit.mayStart(at: start))
    }

    @Test func threeInARowRestForAMinute() {
        var limit = RestartLimit()
        for _ in 0..<3 { limit.died(at: start) }
        #expect(!limit.mayStart(at: start))
        #expect(!limit.mayStart(at: start.addingTimeInterval(59)))
        #expect(limit.mayStart(at: start.addingTimeInterval(60)))
    }

    @Test func aFinishedRequestStartsTheCountAgain() {
        var limit = RestartLimit()
        limit.died(at: start)
        limit.died(at: start)
        limit.succeeded()
        limit.died(at: start)
        limit.died(at: start)
        #expect(limit.mayStart(at: start))
        #expect(limit.deaths == 2)
    }

    @Test func afterTheRestItTakesThreeMoreToRestAgain() {
        var limit = RestartLimit()
        for _ in 0..<3 { limit.died(at: start) }
        let later = start.addingTimeInterval(61)
        #expect(limit.mayStart(at: later))
        limit.died(at: later)
        #expect(limit.mayStart(at: later))
        limit.died(at: later)
        limit.died(at: later)
        #expect(!limit.mayStart(at: later))
    }

    @Test func aFinishedRequestEndsTheRest() {
        var limit = RestartLimit()
        for _ in 0..<3 { limit.died(at: start) }
        limit.succeeded()
        #expect(limit.mayStart(at: start))
    }
}
