import Foundation
import Testing

@testable import ChirpCore

@Suite struct SignInFieldTests {
    @Test func labelsThatNameASignInInput() {
        for label in ["Email", "Email or phone", "Username", "Enter PIN", "Verification code", "Card number", "Sign in", "One-time code"] {
            #expect(SignInField.labelNamesSignIn(label), "\(label)")
        }
    }

    @Test func labelsAboutWritingAreOrdinaryFields() {
        for label in ["Email subject", "Search email", "Message", "Shipping address", "Title", "Phonebook", "Opinion", "Add a comment"] {
            #expect(!SignInField.labelNamesSignIn(label), "\(label)")
        }
    }

    @Test func idsThatNameASignInInput() {
        for id in ["user_email", "loginEmail", "phonenumber", "identifierId", "txtPassword", "email2", "otp-code", "login_field"] {
            #expect(SignInField.idNamesSignIn(id), "\(id)")
        }
    }

    @Test func idsThatDoNot() {
        for id in ["emailSearch", "phonebook-search", "comment", "post-title", "q", "", String(repeating: "email", count: 20)] {
            #expect(!SignInField.idNamesSignIn(id), "\(id)")
        }
    }

    @Test func anAddressBeingTypedIsASignInField() {
        #expect(SignInField.looksLikeAddress("alice@"))
        #expect(SignInField.looksLikeAddress(" alice@example.com "))
        #expect(!SignInField.looksLikeAddress("medium.com/@alice"))
        #expect(!SignInField.looksLikeAddress("write to alice@example.com today"))
        #expect(!SignInField.looksLikeAddress(""))
        #expect(!SignInField.looksLikeAddress(nil))
    }

    @Test func onlySingleLineFieldsAreLeftAlone() {
        // The body of an e-mail is labelled "email" too, and is exactly what to check.
        #expect(!SignInField.matches(singleLine: false, labels: ["Email"], id: "email", text: "alice@example.com"))
        #expect(SignInField.matches(singleLine: true, labels: [nil, "Email or phone"], id: nil, text: ""))
        #expect(SignInField.matches(singleLine: true, labels: [], id: "user_email", text: nil))
        #expect(SignInField.matches(singleLine: true, labels: [], id: nil, text: "alice@"))
        #expect(!SignInField.matches(singleLine: true, labels: ["Subject"], id: "subject", text: "Lunch on Friday"))
    }
}

@Suite struct PollBackoffTests {
    @Test func aShortPauseStaysAtFullSpeed() {
        var b = PollBackoff()
        for _ in 0..<4 { b.record(changed: false) }
        #expect(b.stride == 1)
    }

    @Test func aLongQuietSpellStretchesTheGapInSteps() {
        var b = PollBackoff()
        var seen: [Int] = []
        for _ in 0..<40 {
            b.record(changed: false)
            if seen.last != b.stride { seen.append(b.stride) }
        }
        #expect(seen == [1, 3, 6, 10])
    }

    @Test func anyChangeGoesBackToFullSpeed() {
        var b = PollBackoff()
        for _ in 0..<40 { b.record(changed: false) }
        b.record(changed: true)
        #expect(b.stride == 1)
        for _ in 0..<40 { b.record(changed: false) }
        b.reset()
        #expect(b.stride == 1 && b.quietLooks == 0)
    }

    @Test func theCountStopsGrowing() {
        var b = PollBackoff()
        for _ in 0..<500 { b.record(changed: false) }
        #expect(b.quietLooks == PollBackoff.cap && b.stride == 10)
    }
}

@Suite struct SlowAppGuardTests {
    @Test func aQuickAppIsNeverLeftAlone() {
        var g = SlowAppGuard()
        let now = Date()
        #expect(g.record(7, took: 0.2, now: now) == nil)
        #expect(!g.resting(7, now: now))
    }

    // The first read on a busy Mac can take 1.5 s; that one answer alone must not rest the app for 30 s.
    @Test func oneSlowAnswerIsUsedAndDoesNotBackOff() {
        var g = SlowAppGuard()
        let now = Date()
        #expect(g.record(7, took: 1.5, now: now) == nil)
        #expect(!g.resting(7, now: now))
        #expect(g.record(7, took: 1.2, now: now.addingTimeInterval(1)) == nil)
        #expect(!g.resting(7, now: now.addingTimeInterval(1)))
    }

    @Test func threeSlowInARowRestFiveSecondsFirstThenThirty() {
        var g = SlowAppGuard()
        let now = Date()
        g.record(7, took: 1.2, now: now)
        g.record(7, took: 1.3, now: now)
        #expect(g.record(7, took: 1.4, now: now) == 5)
        #expect(g.resting(7, now: now.addingTimeInterval(4)))
        #expect(!g.resting(7, now: now.addingTimeInterval(6)))
        #expect(!g.resting(8, now: now))
        // Still slow after its first rest: the long rest.
        let later = now.addingTimeInterval(6)
        g.record(7, took: 1.0, now: later)
        g.record(7, took: 1.0, now: later)
        #expect(g.record(7, took: 1.0, now: later) == 30)
        #expect(g.resting(7, now: later.addingTimeInterval(29)))
    }

    @Test func aQuickAnswerInBetweenStartsTheCountAgain() {
        var g = SlowAppGuard()
        let now = Date()
        g.record(7, took: 1.2, now: now)
        g.record(7, took: 1.2, now: now)
        #expect(g.record(7, took: 0.1, now: now) == nil)
        #expect(g.record(7, took: 1.2, now: now) == nil)
        #expect(g.record(7, took: 1.2, now: now) == nil)
        #expect(!g.resting(7, now: now))
        // And after a rest and a quick answer, the next rest is the short one again.
        #expect(g.record(7, took: 1.2, now: now) == 5)
        g.record(7, took: 0.1, now: now.addingTimeInterval(6))
        for _ in 0..<2 { g.record(7, took: 1.2, now: now.addingTimeInterval(7)) }
        #expect(g.record(7, took: 1.2, now: now.addingTimeInterval(7)) == 5)
    }

    @Test func anAppThatHangsIsLeftAloneAtOnce() {
        var g = SlowAppGuard()
        let now = Date()
        #expect(g.record(7, took: 6, now: now) == 30)
        #expect(g.resting(7, now: now.addingTimeInterval(29)))
        #expect(!g.resting(7, now: now.addingTimeInterval(31)))
    }

    @Test func theLimitsCanBeSet() {
        var g = SlowAppGuard(slow: 0.2, strikes: 1, firstRest: 5)
        let now = Date()
        #expect(g.record(7, took: 0.25, now: now) == 5)
        #expect(g.resting(7, now: now.addingTimeInterval(4)))
        #expect(!g.resting(7, now: now.addingTimeInterval(6)))
    }
}

@Suite struct SystemSurfacesTests {
    @Test func signInAndSecurityPromptsAreLeftAlone() {
        for id in [
            "com.apple.loginwindow", "com.apple.LockScreen", "com.apple.systempreferences", "com.apple.AutoFillPanelService",
            "com.apple.tcc.AuthorizationPromptService", "com.apple.Passwords.MenuBarExtra", "2BUA8C4S2C.com.1password.browser-helper",
        ] {
            #expect(PersonalLanguage.staysOut(of: id), "\(id)")
        }
    }

    @Test func theDefaultIsStillOnEverywhereElse() {
        for id in ["com.apple.Notes", "com.apple.mail", "com.example.some-new-app"] {
            #expect(!PersonalLanguage.staysOut(of: id), "\(id)")
        }
    }
}
