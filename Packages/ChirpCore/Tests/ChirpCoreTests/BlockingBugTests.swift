import Foundation
import Testing
@testable import ChirpCore

/// Faults that stopped Chirp from being used: a wait with no limit, the wrong text taken from Apple Mail,
/// and calls on the Mac.
@Suite struct BlockingBugTests {
    // MARK: Waits have limits

    @Test func workThatNeverEndsIsLeftBehindAtItsLimit() async {
        let began = Date()
        // Ignores being cancelled, as a wait on a hung helper does.
        let value = await Deadline.run(seconds: 0.2) { () -> Int in
            await Self.deaf(seconds: 20)
            return 1
        }
        #expect(value == nil)
        // Well short of the work's 20 seconds, with room for a busy test machine.
        #expect(Date().timeIntervalSince(began) < 10)
    }

    @Test func workThatEndsInTimeGivesItsValue() async throws {
        #expect(await Deadline.run(seconds: 5) { 7 } == 7)
        let began = Date()
        #expect(try await Deadline.attempt(seconds: 5) { "done" } == "done")
        // The limit is not waited out when the work is done.
        #expect(Date().timeIntervalSince(began) < 1)
    }

    @Test func aFailureComesThroughAndTheLimitIsItsOwnError() async {
        struct Broke: Error {}
        await #expect(throws: Broke.self) { try await Deadline.attempt(seconds: 5) { throw Broke() } }
        await #expect(throws: Deadline.Passed(seconds: 0.1)) {
            try await Deadline.attempt(seconds: 0.1) { try await Task.sleep(for: .seconds(30)) }
        }
    }

    @Test func theWorkIsToldToStopAtTheLimit() async {
        let flag = Flag()
        _ = await Deadline.run(seconds: 0.1) {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { flag.set() }
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(flag.isSet)
    }

    @Test func aCancelledCallerIsLetGoAtOnce() async {
        let began = Date()
        let waiting = Task { await Deadline.run(seconds: 30) { await Self.deaf(seconds: 20) } }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        _ = await waiting.value
        #expect(Date().timeIntervalSince(began) < 10)
    }

    /// Work that takes no notice of being cancelled.
    static func deaf(seconds: Double) async {
        await Task.detached { try? await Task.sleep(for: .seconds(seconds)) }.value
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    // MARK: The page in a window

    struct Node: ScreenNode {
        var role: String
        var children: [Node] = []
    }

    /// Apple Mail's main window as it was seen in use: a message list of 689 rows (each a cell of
    /// seven elements) ahead of the message that is open.
    static func mailWindow(rows: Int = 689, message: Bool = true) -> Node {
        let row = Node(role: "AXRow", children: [Node(role: "AXCell", children: [Node(role: "AXUnknown", children: (0..<7).map { _ in Node(role: "AXStaticText") })])])
        let list = Node(role: "AXScrollArea", children: [Node(role: "AXTable", children: Array(repeating: row, count: rows))])
        let body = Node(role: "AXScrollArea", children: [Node(role: "AXGroup", children: [Node(role: "AXGroup", children: [Node(role: "AXWebArea", children: [Node(role: "AXStaticText")])])])])
        return Node(role: "AXWindow", children: [Node(role: "AXSplitGroup", children: [list] + (message ? [body] : [])), Node(role: "AXToolbar")])
    }

    /// The search as it was built: the first web area met, giving up after 1,500 elements.
    static func oldSearch(_ root: Node) -> Bool {
        var visited = 0
        var found = false
        func look(_ node: Node, _ depth: Int) {
            visited += 1
            guard !found, visited < 1500, depth < 14 else { return }
            if node.role == "AXWebArea" { return found = true }
            for child in node.children { look(child, depth + 1) }
        }
        look(root, 0)
        return found
    }

    @Test func theOpenMessageIsFoundPastALongMessageList() {
        // Before: the search ran out inside the list, and the list itself was read.
        #expect(!Self.oldSearch(Self.mailWindow()))
        let found = PageFinder.pages(under: Self.mailWindow(), all: true)
        #expect(found.pages.count == 1)
        #expect(found.skippedLists == 1)
        #expect(found.visited < 20)
    }

    @Test func aShortListIsStillLookedInto() {
        // A page shown inside a small list (a thread of a few messages) is found.
        let thread = Node(role: "AXWindow", children: [Node(role: "AXList", children: (0..<5).map { _ in Node(role: "AXGroup", children: [Node(role: "AXWebArea")]) })])
        #expect(PageFinder.pages(under: thread, all: true).pages.count == 5)
        #expect(PageFinder.pages(under: thread, all: false).pages.count == 1)
    }

    @Test func aWindowWithNoMessageOpenHasNoPage() {
        #expect(PageFinder.pages(under: Self.mailWindow(message: false), all: true).pages.isEmpty)
    }

    // MARK: No limit on text taken off the screen

    @Test func textFromTheScreenIsSummarizedToItsEnd() {
        let paragraph = String(repeating: "This is a sentence of plain reading matter that goes on for a while. ", count: 4)
        // A mailbox's worth: about 200,000 characters. All of it is planned (no cap); Mail gives only the message.
        let text = Array(repeating: paragraph, count: 720).joined(separator: "\n\n")
        let whole = SummaryPlan.make(for: text)
        #expect(whole.parts.count >= 55)
        #expect(whole.parts.reduce(0) { $0 + $1.text.count } >= whole.characters - 2 * whole.parts.count)
        // One enormous paragraph still gives something.
        #expect(!SummaryPlan.make(for: String(repeating: "word ", count: 30_000)).parts.isEmpty)
    }

    // MARK: Calls on the Mac

    @Test func aFaceTimeOrPhoneCallIsACall() {
        // What holds the microphone during a FaceTime or phone call on the Mac: Apple's call services.
        for service in ["com.apple.avconferenced", "/usr/libexec/avconferenced", "com.apple.TelephonyUtilities", "com.apple.TelephonyUtilities.callservicesd"] {
            #expect(CallDetection.parent(of: service) == CallDetection.appleCall)
            let call = CallDetection.call(using: [service], own: "com.jakeflavin.chirp")
            #expect(call.on && call.parent == CallDetection.appleCall)
        }
        // The apps that were already known still are, with their helpers.
        #expect(CallDetection.parent(of: "com.apple.FaceTime") == "com.apple.FaceTime")
        #expect(CallDetection.parent(of: "us.zoom.caphost") == "us.zoom.xos")
        #expect(CallDetection.parent(of: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(CallDetection.parent(of: "com.microsoft.teams2.helper") == "com.microsoft.teams2")
        // Other things that open the microphone are not calls to offer.
        for other in ["com.apple.CoreSpeech", "com.apple.Siri", "com.anthropic.claudefordesktop", "com.apple.assistantd"] {
            #expect(CallDetection.parent(of: other) == nil)
        }
        // Chirp's own use of the microphone (and its helpers') is nobody else on the line.
        #expect(!CallDetection.call(using: ["com.jakeflavin.chirp", "com.jakeflavin.chirp.helper"], own: "com.jakeflavin.chirp").on)
        // Something unknown has the microphone: somebody may be on the line, but there is no call to name.
        let unknown = CallDetection.call(using: ["com.apple.Siri"], own: "com.jakeflavin.chirp")
        #expect(unknown.on && unknown.parent == nil)
    }

    @Test func anAppleCallIsNamedAfterTheAppInUse() {
        #expect(CallDetection.appleCallName(faceTimeOpen: true, faceTimeInFront: true, phoneOpen: true, phoneInFront: false) == "FaceTime")
        #expect(CallDetection.appleCallName(faceTimeOpen: true, faceTimeInFront: false, phoneOpen: true, phoneInFront: true) == "Phone")
        #expect(CallDetection.appleCallName(faceTimeOpen: true, faceTimeInFront: false, phoneOpen: false, phoneInFront: false) == "FaceTime")
        #expect(CallDetection.appleCallName(faceTimeOpen: false, faceTimeInFront: false, phoneOpen: true, phoneInFront: false) == "Phone")
        #expect(CallDetection.appleCallName(faceTimeOpen: false, faceTimeInFront: false, phoneOpen: false, phoneInFront: false) == "FaceTime or phone")
        #expect(CallDetection.name(of: CallDetection.appleCall, appleCall: "Phone") == "Phone")
        #expect(CallDetection.name(of: "us.zoom.xos", appleCall: "Phone") == "Zoom")
    }

    @Test func thePermissionNoticeShowsOnlyWhenThePermissionIsMissing() {
        // The 12:01 notice: the other side quiet, the permission allowed. Nothing is said.
        #expect(CaptureNotice.text(micSilent: false, otherSideSilent: true, access: .allowed) == nil)
        #expect(CaptureNotice.text(micSilent: false, otherSideSilent: true, access: .unknown) == nil)
        // Really missing: it is said.
        #expect(CaptureNotice.text(micSilent: false, otherSideSilent: true, access: .denied) == CaptureNotice.noCallAudio)
        #expect(CaptureNotice.text(micSilent: false, otherSideSilent: true, access: .notAsked) == CaptureNotice.noCallAudio)
        #expect(CaptureNotice.text(micSilent: true, otherSideSilent: true, access: .denied) == CaptureNotice.noSound)
        // A silent microphone is about the microphone, whatever the other side is doing.
        #expect(CaptureNotice.text(micSilent: true, otherSideSilent: true, access: .allowed) == CaptureNotice.micSilent)
        #expect(CaptureNotice.text(micSilent: true, otherSideSilent: false, access: .denied) == CaptureNotice.micSilent)
        #expect(CaptureNotice.text(micSilent: false, otherSideSilent: false, access: .denied) == nil)
        // Capture is set up again only while the permission may yet be given.
        #expect(!CaptureNotice.shouldRetryCapture(otherSideSilent: true, access: .allowed))
        #expect(CaptureNotice.shouldRetryCapture(otherSideSilent: true, access: .denied))
        #expect(CaptureNotice.shouldRetryCapture(otherSideSilent: true, access: .unknown))
        #expect(!CaptureNotice.shouldRetryCapture(otherSideSilent: false, access: .denied))
        #expect(CaptureNotice.isOne(CaptureNotice.micSilent) && !CaptureNotice.isOne("Only your microphone is being recorded.") && !CaptureNotice.isOne(nil))
    }

    @Test func aThreeChannelMicrophoneIsMixedDownAndNotSilent() {
        let voice: [Float] = (0..<4800).map { 0.1 * sin(Float($0) * 2 * .pi * 440 / 48_000) }
        // Three capsules, as the built-in microphone opens during a call.
        let mono = MicDownmix.mono([voice, voice, voice.map { -$0 }])
        #expect(mono.count == 4800)
        #expect(mono.map(abs).max()! > 0.09)
        // The first two go in; a third that carries the sound upside down does not cancel it.
        #expect(mono == voice)
        #expect(MicDownmix.mono([voice]) == voice)
        #expect(MicDownmix.mono([voice, [Float](repeating: 0, count: 4800)]).map(abs).max()! > 0.04)
        #expect(MicDownmix.mono([[Float]]()).isEmpty)
        #expect(MicDownmix.channelsUsed(of: 3) == 2 && MicDownmix.channelsUsed(of: 1) == 1)
    }

    static func speech(level: Float, seconds: Double) -> [Float] {
        // Bursts of tone with gaps, as words with pauses.
        (0..<Int(seconds * 16_000)).map { i in (i / 8000) % 3 == 2 ? 0 : level * 1.414 * sin(Float(i) * 2 * .pi * 220 / 16_000) }
    }
    static func rms(_ samples: [Float]) -> Float { (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot() }

    @Test func aMicrophoneAtAThirtiethOfItsLevelIsBroughtUp() {
        // The level measured while FaceTime held the microphone: 0.0007 where 0.02 is usual.
        var leveler = MicLeveler()
        let quiet = Self.speech(level: 0.0007, seconds: 6)
        var out: [Float] = []
        for start in stride(from: 0, to: quiet.count, by: 1600) { out += leveler.process(Array(quiet[start..<min(start + 1600, quiet.count)])) }
        #expect(out.count == quiet.count)
        #expect(leveler.gain > 20 && leveler.gain <= MicLeveler.mostGain)
        // Past the first second it is at a level the "is this silence?" check (0.002) lets through.
        #expect(Self.rms(Array(out[32_000...])) > 0.01)
        #expect(out.map(abs).max()! <= 0.89)
    }

    @Test func aMicrophoneAtItsUsualLevelIsLeftExactlyAsItIs() {
        var leveler = MicLeveler()
        let usual = Self.speech(level: 0.05, seconds: 6)
        var out: [Float] = []
        for start in stride(from: 0, to: usual.count, by: 1600) { out += leveler.process(Array(usual[start..<min(start + 1600, usual.count)])) }
        #expect(out == usual)
        #expect(leveler.gain == 1)
        // Silence is not turned up into noise.
        var silent = MicLeveler()
        let nothing = [Float](repeating: 0.000_05, count: 32_000)
        #expect(silent.process(nothing) == nothing)
    }
}
