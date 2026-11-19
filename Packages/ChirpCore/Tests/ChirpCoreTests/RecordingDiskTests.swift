import Foundation
import Testing

@testable import ChirpCore

@Suite struct RecordingDiskTests {
    @Test func diskRoom() {
        #expect(RecordingDisk.room(freeBytes: 10 << 30) == .ample)
        #expect(RecordingDisk.room(freeBytes: 1 << 30) == .low)
        #expect(RecordingDisk.room(freeBytes: 100 << 20) == .full)
        #expect((RecordingDisk.freeBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
}
