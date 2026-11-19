import CoreGraphics
import Foundation
import Testing

@testable import ChirpCore

/// Each kind of underline has its own line, not only its own colour.
@Suite struct UnderlineLookTests {
    @Test func eachKindHasItsOwnLine() {
        #expect(UnderlineLook.of(.spelling).pattern == .wavy)
        #expect(UnderlineLook.of(.grammar).pattern == .solid)
        #expect(UnderlineLook.of(.style).pattern == .dashed)
        #expect(UnderlineLook.of(.snippet).pattern == .dotted)
        let patterns = IssueCategory.allCases.map { UnderlineLook.of($0).pattern }
        #expect(Set(patterns).count == IssueCategory.allCases.count)
    }

    @Test func aLikelyNameIsTheSpellingLineThinnerAndFainter() {
        let name = UnderlineLook.of(.spelling, likelyName: true)
        let spelling = UnderlineLook.of(.spelling)
        #expect(name.pattern == .wavy)
        #expect(name.width < spelling.width && name.opacity < spelling.opacity)
        #expect(UnderlineLook.of(.spelling, likelyName: true, dark: true).opacity > name.opacity)
    }

    @Test func dashesAreForDashedAndDottedOnly() {
        #expect(UnderlineLook.of(.style).dash == [6, 4])
        #expect(UnderlineLook.of(.snippet).dash?.first ?? 1 < 1)
        #expect(UnderlineLook.of(.grammar).dash == nil && UnderlineLook.of(.spelling).dash == nil)
    }

    @Test func aWaveStaysWithinItsReachAndEndsWhereItShould() {
        let look = UnderlineLook.of(.spelling)
        let path = look.path(from: 10, to: 50, y: 100)
        let box = path.boundingBoxOfPath
        #expect(abs(box.minX - 10) < 0.01 && abs(box.maxX - 50) < 0.01)
        #expect(box.minY >= 100 - look.amplitude - 0.01 && box.maxY <= 100 + look.amplitude + 0.01)
        #expect(box.height > look.amplitude)
        #expect(path.currentPoint == CGPoint(x: 50, y: 100))
        // A straight line for the others.
        let solid = UnderlineLook.of(.grammar).path(from: 10, to: 50, y: 100).boundingBoxOfPath
        #expect(solid.height < 0.01)
        // Nothing for an empty span.
        #expect(look.path(from: 50, to: 50, y: 100).isEmpty)
    }
}
