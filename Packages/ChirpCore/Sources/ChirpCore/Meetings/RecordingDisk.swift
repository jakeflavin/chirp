import Foundation

/// Whether there is room on the disk to go on recording. A recording writes about 460 MB an hour while
/// it is being made.
public enum RecordingDisk {
    /// Below this much free space a recording says the disk is nearly full: an hour of recording, and
    /// the room macOS itself needs.
    public static let lowBytes: Int64 = 2 * 1_073_741_824
    /// Below this, sound can no longer be relied on to reach the disk.
    public static let fullBytes: Int64 = 256 * 1_048_576

    public enum Room: Sendable, Equatable { case ample, low, full }

    public static func room(freeBytes: Int64) -> Room {
        freeBytes < fullBytes ? .full : freeBytes < lowBytes ? .low : .ample
    }

    /// Free space on the volume that holds `url`, or nil when it cannot be read.
    public static func freeBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            .flatMap { $0 > 0 ? $0 : nil }
            ?? ((try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
