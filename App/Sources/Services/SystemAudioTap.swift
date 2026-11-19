import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (the other side of a call) as 16 kHz mono samples,
/// using a Core Audio process tap. No virtual audio driver and no screen recording.
/// macOS asks for "System Audio Recording" permission the first time; if it is denied the tap
/// still starts but delivers silence, which `MeetingRecorder` watches for.
final class SystemAudioTap: @unchecked Sendable {
    /// A Core Audio call that failed while setting up capture, with its error code.
    enum TapError: LocalizedError {
        case failed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .failed(let what, let status): "Could not capture system audio (\(what), error \(status))."
            }
        }
    }

    /// Called on the capture queue with each new chunk of 16 kHz samples.
    var onSamples: (@Sendable ([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "chirp.system-audio")

    /// Creates the tap and a private device that carries it, and starts capturing. Cleans up after itself
    /// if any step fails. Starting again while already capturing replaces the old tap; it is never left behind.
    func start() throws {
        stop()
        // Tap every process except Chirp itself, so Chirp reading aloud is not recorded.
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(for: getpid()) { excluded.append(own) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Chirp meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.failed("creating the tap", status) }

        guard let outputUID = Self.defaultOutputUID() else {
            stop()
            throw TapError.failed("finding the output device", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Chirp meeting audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw TapError.failed("creating the capture device", status)
        }

        // The format the tap delivers.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw TapError.failed("reading the audio format", status)
        }
        tapFormat = format
        converter = AVAudioConverter(from: format, to: target)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr else {
            stop()
            throw TapError.failed("starting capture", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw TapError.failed("starting capture", status)
        }
    }

    /// Stops capturing and removes the tap and its device. Safe to call when nothing is running.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on the capture queue for each buffer: converts it to 16 kHz mono and hands it on.
    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let converter,
            let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
            buffer.frameLength > 0
        else { return }
        let ratio = target.sampleRate / tapFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
        else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        onSamples?(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }

    // MARK: Core Audio helpers

    /// Core Audio's object for a running process, used to leave Chirp's own sound out.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The identifier of the device sound is playing through.
    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    /// Reads a text property (a name or an identifier) of an audio object.
    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Where the program behind an audio process lives on disk.
    private static func programPath(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Bundle identifiers of the apps currently capturing from a microphone.
    static func appsUsingMicrophone() -> [String] { audioApps().filter(\.input).map(\.id) }

    /// Apps that have audio running right now, and in which direction.
    static func audioApps() -> [(id: String, input: Bool, output: Bool)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        func isRunning(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
        }
        var result: [(id: String, input: Bool, output: Bool)] = []
        for object in objects {
            let input = isRunning(object, kAudioProcessPropertyIsRunningInput)
            let output = isRunning(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }
            // A background service can have no bundle identifier; it is then known by its program's path,
            // so a call service is not passed over.
            guard let id = stringProperty(object, kAudioProcessPropertyBundleID).flatMap({ $0.isEmpty ? nil : $0 }) ?? programPath(of: object)
            else { continue }
            result.append((id, input, output))
        }
        return result
    }
}
