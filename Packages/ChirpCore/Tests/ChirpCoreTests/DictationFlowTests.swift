import Foundation
import Testing
@testable import ChirpCore

@Suite struct DictationFlowTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aPressWhileBusyIsRememberedAsHeld() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, at: t0)
        #expect(press.take() == WaitingPress.Start(pressedAt: t0, handsFree: false, tag: 0))
        #expect(press.take() == nil)
    }

    @Test func tapToStartIsHandsFreeFromThePress() {
        var press = WaitingPress()
        press.keyDown(mode: .toggle, at: t0)
        press.keyUp(mode: .toggle, tapSeconds: 0.3, at: t0.addingTimeInterval(0.1))
        #expect(press.take()?.handsFree == true)
    }

    @Test func twoTapToStartPressesCancelOut() {
        var press = WaitingPress()
        press.keyDown(mode: .toggle, at: t0)
        press.keyDown(mode: .toggle, at: t0.addingTimeInterval(0.5))
        #expect(press.take() == nil)
    }

    @Test func aQuickTapWhileBusyStartsHandsFree() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, at: t0)
        press.keyUp(mode: .holdOrToggle, tapSeconds: 0.3, at: t0.addingTimeInterval(0.12))
        #expect(press.take() == WaitingPress.Start(pressedAt: t0, handsFree: true, tag: 0))
    }

    @Test func aWholeHoldWhileBusyLeavesNothingToStart() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, at: t0)
        press.keyUp(mode: .holdOrToggle, tapSeconds: 0.3, at: t0.addingTimeInterval(0.8))
        #expect(press.take() == nil)
    }

    @Test func holdToTalkLetGoWhileBusyLeavesNothingToStart() {
        var press = WaitingPress()
        press.keyDown(mode: .hold, at: t0)
        press.keyUp(mode: .hold, tapSeconds: 0.3, at: t0.addingTimeInterval(0.05))
        #expect(press.take() == nil)
    }

    @Test func aPressOnARememberedTapTakesItBack() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, at: t0)
        press.keyUp(mode: .holdOrToggle, tapSeconds: 0.3, at: t0.addingTimeInterval(0.1))
        press.keyDown(mode: .holdOrToggle, at: t0.addingTimeInterval(0.6))
        #expect(press.take() == nil)
    }

    @Test func aKeyRepeatWhileHeldChangesNothing() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, at: t0)
        press.keyDown(mode: .holdOrToggle, at: t0.addingTimeInterval(0.03))
        #expect(press.take()?.pressedAt == t0)
    }

    @Test func anotherShortcutDoesNotReplaceTheRememberedOne() {
        var press = WaitingPress()
        press.keyDown(mode: .holdOrToggle, tag: 1, at: t0)
        press.keyDown(mode: .holdOrToggle, tag: 2, at: t0.addingTimeInterval(0.1))
        press.keyUp(mode: .holdOrToggle, tag: 2, tapSeconds: 0.3, at: t0.addingTimeInterval(0.9))
        #expect(press.take()?.tag == 1)
    }

    @Test func cancelForgetsTheRememberedPress() {
        var press = WaitingPress()
        press.keyDown(mode: .toggle, at: t0)
        press.cancel()
        #expect(press.take() == nil)
    }
}
